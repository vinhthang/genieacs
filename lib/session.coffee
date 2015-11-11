###
# Copyright 2013-2015  Zaid Abdulla
#
# GenieACS is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# GenieACS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with GenieACS.  If not, see <http://www.gnu.org/licenses/>.
###

crypto = require 'crypto'
config = require './config'
common = require './common'
db = require './db'
Device = require './device'
provisions = require './provisions'


class Session

  constructor: (deviceId, cwmpVersion, timeout) ->
    @timestamp = Date.now()
    @device = new Device(deviceId)
    @cwmpVersion = cwmpVersion
    @timeout = timeout
    @presets = {}
    @queue = {}
    @index = 0


  inform: (methodRequest, callback) ->
    @device.dataModel.set(1, "DeviceID.Manufacturer", {value: methodRequest.deviceId.Manufacturer}, true, {object:true})
    @device.dataModel.set(1, "DeviceID.OUI", {value: methodRequest.deviceId.OUI}, true, {object:true})
    @device.dataModel.set(1, "DeviceID.ProductClass", {value: methodRequest.deviceId.ProductClass}, true, {object:true})
    @device.dataModel.set(1, "DeviceID.SerialNumber", {value: methodRequest.deviceId.SerialNumber}, true, {object:true})
    @device.setParameterValues(@timestamp, methodRequest.parameterList)
    events = [['Events.Inform', @timestamp, 'xsd:dateTime']]
    for e in methodRequest.event
      events.push(['Events.' + e.replace(' ', '_'), @timestamp, 'xsd:dateTime'])
    @device.setParameterValues(@timestamp, events)
    return callback(null, {type : 'InformResponse'})


  addPreset: (name, weight, provisions) ->
    @presets[name] = {weight: weight, provisions: provisions}


  stageGpv: (parameter) ->
    @staging['gpv'] ?= {}
    @staging['gpv'][parameter] = 1


  stageGpn: (parameter, depth) ->
    @staging['gpn'] ?= {}
    @staging['gpn'][parameter] = Math.max(depth, @staging['gpn'][parameter] || 0)


  buildQueue: () ->
    @queue = {}
    index = @index

    if @staging['gpn']?
      # TODO optimize by using nextLevel=false
      keys = Object.keys(@staging['gpn']).sort()
      for k in keys
        @queue[index++] = {
          type: 'GetParameterNames',
          parameterPath: k,
          nextLevel: true
        }

    if @staging['gpv']?
      PARAMETERS_BATCH_SIZE = config.get('TASK_PARAMETERS_BATCH_SIZE', @device.id)
      parameterNames = Object.keys(@staging['gpv'])
      while (batch = parameterNames.splice(0, PARAMETERS_BATCH_SIZE)).length > 0
        @queue[index++] = {
          type: 'GetParameterValues',
          parameterNames: batch
        }

    return @queue


  get: (pattern, discoverTimestamp, valueTimestamp, writabeTimestamp, callback) ->
    discoverTimestamp ?= 0
    if discoverTimestamp < 0
      discoverTimestamp = Math.max(0, @timestamp + discoverTimestamp)
    else if discoverTimestamp > 0
      discoverTimestamp = Math.min(@timestamp, discoverTimestamp)

    if valueTimestamp < 0
      valueTimestamp = Math.max(0, @timestamp + valueTimestamp)
    else if valueTimestamp > 0
      valueTimestamp = Math.min(@timestamp, valueTimestamp)

    if writabeTimestamp < 0
      writabeTimestamp = Math.max(0, @timestamp + writabeTimestamp)
    else if writabeTimestamp > 0
      writabeTimestamp = Math.min(@timestamp, writabeTimestamp)

    counter = 1
    res = {}
    satisfied = true
    parentTimestamps = null

    parent = common.parentParameter(pattern)
    ancestor = parent
    while ancestor
      ++ counter
      do (ancestor) =>
        @device.get(ancestor, (err, parameters) =>
          if err
            callback(err) if -- counter >= 0
            counter = 0
            return

          parentTimestamps = {} if ancestor == parent
          for parameter, values of parameters
            continue if not values['object']

            parentTimestamps[parameter] = values['timestamp'] if ancestor == parent

            if not values['timestamp']? or
                (pattern[ancestor.length + 1] == '*' and values['timestamp'] < discoverTimestamp)
              @stageGpn(parameter, common.descendantOf(pattern, ancestor))
              satisfied = false

          return callback(null, if satisfied then res else null) if -- counter == 0
        )
      ancestor = common.parentParameter(ancestor)

    ++ counter
    @device.get(pattern, repeat = (err, parameters) =>
      if err
        callback(err) if -- counter >= 0
        counter = 0
        return

      # Wait for parentTimestamps to be collected
      if not parentTimestamps?
        return process.nextTick(() -> repeat(parameters))

      for parameter, values of parameters
        res[parameter] = {}

        if valueTimestamp? and not values['object']
          if values['timestamp'] >= valueTimestamp
            res[parameter]['value'] = values['value']
          else
            @stageGpv(parameter)
            satisfied = false

        if writableTimestamp?
          if parentTimestamps(parent) >= writableTimestamp
            res[parameter]['writable'] = values['writable']
          else
            @stageGpn(parent, 1)
            satisfied = false

      return callback(null, if satisfied then res else null) if -- counter == 0
    )

    return callback(null, if satisfied then res else null) if -- counter == 0


  assertGet: (assertions, callback) ->
    res = {}
    counter = 1
    satisfied = true

    for pattern, options of assertions
      ++ counter
      res[pattern] = {}
      do (pattern, options) =>
        @get(pattern, options['discover'], options['value'], options['writable'], (err, r) =>
          if err
            callback(err) if -- counter == 0
            return

          if r?
            res[pattern] = r
          else
            satisfied = false

          if -- counter == 0
            return callback(null, if satisfied then res else null)
        )

    if -- counter == 0
      return callback(null, if satisfied then res else null)


  rpcResponse: (id, rpcResponse, callback) ->
    return callback(new Error('Request ID not recognized')) if id != "#{@index}"

    rpc = @queue[@index]
    delete @queue[@index]
    ++ @index

    switch rpcResponse.type
      when 'GetParameterValuesResponse'
        return callback(new Error('Response type does not match request type')) if rpc.type isnt 'GetParameterValues'
        @device.setParameterValues(@timestamp, rpcResponse.parameterList)
      when 'GetParameterNamesResponse'
        return callback(new Error('Response type does not match request type')) if rpc.type isnt 'GetParameterNames'
        @device.setParameterInfo(@timestamp, rpc.parameterPath, rpc.nextLevel, rpcResponse.parameterList)
      else
        return callback(new Error('Response type not recognized'))

    return callback()


  rpcFault: (id, faultResponse, callback) ->
    throw new Error('Not implemented')


  nextRpc: (callback) ->
    if @index of @queue
      return callback(null, @index, @queue[@index])

    counter = 1
    @staging = {}

    for presetName, preset of @presets
      for provision in preset.provisions
        ++ counter
        provisions.processProvision(provision[0], provision[1..], (err, getAssertions, setAssertions) =>
          if err
            callback(err) if -- counter >= 0
            counter = 0
            return

          # TODO process setAssertions too
          @assertGet(getAssertions, (err, res) =>
            if err
              callback(err) if -- counter >= 0
              counter = 0
              return

            if -- counter == 0
              return callback(null, @index, @buildQueue()[@index])
          )
        )

    if -- counter == 0
      return callback(null, @index, @buildQueue()[@index])


  end: (callback) ->
    @device.commit((err) =>
      return callback(err) if err
      db.redisClient.del("session_#{@id}", (err) =>
        callback(err)
      )
    )


  save: (callback) ->
    @id ?= crypto.randomBytes(8).toString('hex')
    data = {
      presets: @presets,
      cwmpVersion: @cwmpVersion,
      timestamp: @timestamp,
      timeout: @timeout,
      queue: @queue,
      index: @index,
      device: @device.serialize()
    }

    db.redisClient.setex("session_#{@id}", @timeout, JSON.stringify(data), (err) =>
       return callback(err, @id)
    )


  @load: (id, callback) ->
    db.redisClient.get("session_#{id}", (err, data) ->
      return callback(err, null) if err or not data?

      data = JSON.parse(data)
      device = Device.deserialize(data.device)
      session = new Session(device.id, data.cwmpVersion, data.timeout)
      session.id = id
      session.cwmpVersion = data.cwmpVersion
      session.timeout = data.timeout
      session.presets = data.presets
      session.timestamp = data.timestamp
      session.queue = data.queue
      session.index = data.index
      session.device = device

      return callback(null, session)
    )


module.exports = Session
