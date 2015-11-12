###
# Copyright 2013, 2014  Zaid Abdulla
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
#
# This file incorporates work covered by the following copyright and
# permission notice:
#
# Copyright 2013 Fanoos Telecom
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
###

config = require './config'
common = require './common'
util = require 'util'
soap = require './soap'
tasks = require './tasks'
db = require './db'
presets = require './presets'
mongodb = require 'mongodb'
apiFunctions = require './api-functions'
customCommands = require './custom-commands'
zlib = require 'zlib'
Session = require './session'


writeResponse = (currentRequest, res) ->
  if config.get('DEBUG', currentRequest.session.device.id)
    dump = "# RESPONSE #{new Date(Date.now())}\n" + JSON.stringify(res.headers) + "\n#{res.data}\n\n"
    require('fs').appendFile("./debug/#{currentRequest.session.device.id}.dump", dump, (err) ->
      throw err if err
    )

  # respond using the same content-encoding as the request
  if currentRequest.httpRequest.headers['content-encoding']? and res.data.length > 0
    switch currentRequest.httpRequest.headers['content-encoding']
      when 'gzip'
        res.headers['Content-Encoding'] = 'gzip'
        compress = zlib.gzip
      when 'deflate'
        res.headers['Content-Encoding'] = 'deflate'
        compress = zlib.deflate

  if compress?
    compress(res.data, (err, data) ->
      res.headers['Content-Length'] = data.length
      currentRequest.httpResponse.writeHead(res.code, res.headers)
      currentRequest.httpResponse.end(data)
    )
  else
    res.headers['Content-Length'] = res.data.length
    currentRequest.httpResponse.writeHead(res.code, res.headers)
    currentRequest.httpResponse.end(res.data)


inform = (currentRequest, cwmpRequest) ->
  if config.get('LOG_INFORMS', currentRequest.session.device.id)
    util.log("#{currentRequest.session.device.id}: Inform (#{cwmpRequest.methodRequest.event}); retry count #{cwmpRequest.methodRequest.retryCount}")

  currentRequest.session.inform(cwmpRequest.methodRequest, (err, methodResponse) ->
    throw err if err
    res = soap.response({
      id : cwmpRequest.id,
      methodResponse : methodResponse,
      cwmpVersion : currentRequest.session.cwmpVersion
    })

    currentRequest.session.save((err, sessionId) ->
      throw err if err
      if !!cookiesPath = config.get('COOKIES_PATH', currentRequest.session.device.id)
        res.headers['Set-Cookie'] = "session=#{sessionId}; Path=#{cookiesPath}"
      else
        res.headers['Set-Cookie'] = "session=#{sessionId}"

      writeResponse(currentRequest, res)
    )
  )


applyPresets = (session, callback) ->
  presets.getActivePresets(session.device, (err, prsts) ->
    return callback(err) if err
    counter = 1
    for k, v of prsts
      session.addPreset(k, v.weight, v.provisions)
      if -- counter == 0
        return callback()

    if -- counter == 0
      return callback()
  )


nextRpc = (currentRequest) ->
  currentRequest.session.nextRpc((err, id, methodRequest) ->
    throw err if err
    if not methodRequest?
      applyPresets(currentRequest.session, (err) ->
        throw err if err
        currentRequest.session.nextRpc((err, id, methodRequest) ->
          throw err if err
          if not methodRequest?
            currentRequest.session.end((err) ->
              throw err if err
              if currentRequest.session.device.new
                util.log("#{currentRequest.session.device.id}: New device registered")
              res = soap.response(null)
              writeResponse(currentRequest, res)
            )
          else
            util.log("#{currentRequest.session.device.id}: #{methodRequest.type} (#{id})")
            res = soap.response({
              id : id,
              methodRequest : methodRequest,
              cwmpVersion : currentRequest.session.cwmpVersion
            })
            currentRequest.session.save((err) ->
              throw err if err
              writeResponse(currentRequest, res)
            )
        )
      )
      return

    util.log("#{currentRequest.session.device.id}: #{methodRequest.type} (#{id})")

    res = soap.response({
      id : id,
      methodRequest : methodRequest,
      cwmpVersion : currentRequest.session.cwmpVersion
    })

    currentRequest.session.save((err) ->
      throw err if err
      writeResponse(currentRequest, res)
    )
  )


getSession = (httpRequest, callback) ->
  # Separation by comma is important as some devices don't comform to standard
  COOKIE_REGEX = /\s*([a-zA-Z0-9\-_]+?)\s*=\s*"?([a-zA-Z0-9\-_]*?)"?\s*(,|;|$)/g
  while match = COOKIE_REGEX.exec(httpRequest.headers.cookie)
    sessionId = match[2] if match[1] == 'session'

  return callback() if not sessionId?

  return Session.load(sessionId, (err, session) ->
    throw err if err
    return callback(sessionId, session)
  )


listener = (httpRequest, httpResponse) ->
  if httpRequest.method != 'POST'
    httpResponse.writeHead 405, {'Allow': 'POST'}
    httpResponse.end('405 Method Not Allowed')
    return

  if httpRequest.headers['content-encoding']?
    switch httpRequest.headers['content-encoding']
      when 'gzip'
        stream = httpRequest.pipe(zlib.createGunzip())
      when 'deflate'
        stream = httpRequest.pipe(zlib.createInflate())
      else
        httpResponse.writeHead(415)
        httpResponse.end('415 Unsupported Media Type')
        return
  else
    stream = httpRequest

  chunks = []
  bytes = 0

  stream.on('data', (chunk) ->
    chunks.push(chunk)
    bytes += chunk.length
  )

  httpRequest.getBody = () ->
    # Write all chunks into a Buffer
    body = new Buffer(bytes)
    offset = 0
    chunks.forEach((chunk) ->
      chunk.copy(body, offset, 0, chunk.length)
      offset += chunk.length
    )
    return body

  stream.on('end', () ->
    getSession(httpRequest, (sessionId, session) ->
      cwmpRequest = soap.request(httpRequest, session?.cwmpVersion)
      if not session?
        if cwmpRequest.methodRequest?.type isnt 'Inform'
          httpResponse.writeHead(400)
          httpResponse.end('Session is expired')
          return

        deviceId = common.generateDeviceId(cwmpRequest.methodRequest.deviceId)
        session = new Session(deviceId, cwmpRequest.cwmpVersion, cwmpRequest.sessionTimeout ? config.get('SESSION_TIMEOUT', deviceId))
        httpRequest.connection.setTimeout(session.timeout * 1000)

      currentRequest = {
        httpRequest : httpRequest,
        httpResponse : httpResponse,
        session : session
      }

      if config.get('DEBUG', currentRequest.session.device.id)
        dump = "# REQUEST #{new Date(Date.now())}\n" + JSON.stringify(httpRequest.headers) + "\n#{httpRequest.getBody()}\n\n"
        require('fs').appendFile("./debug/#{currentRequest.session.device.id}.dump", dump, (err) ->
          throw err if err
        )

      if cwmpRequest.methodRequest?
        if cwmpRequest.methodRequest.type is 'Inform'
          inform(currentRequest, cwmpRequest)
        else if cwmpRequest.methodRequest.type is 'GetRPCMethods'
          util.log("#{currentRequest.session.device.id}: GetRPCMethods")
          res = soap.response({
            id : cwmpRequest.id,
            methodResponse : {type : 'GetRPCMethodsResponse', methodList : ['Inform', 'GetRPCMethods', 'TransferComplete', 'RequestDownload']},
            cwmpVersion : currentRequest.session.cwmpVersion
          })
          currentRequest.session.save((err) ->
            throw err if err
            writeResponse(currentRequest, res)
          )
        else if cwmpRequest.methodRequest.type is 'TransferComplete'
          throw new Error('ACS method not supported')
      else if cwmpRequest.methodResponse?
        currentRequest.session.rpcResponse(cwmpRequest.id, cwmpRequest.methodResponse, (err) ->
          throw err if err
          nextRpc(currentRequest)
        )
      else if cwmpRequest.fault?
        currentRequest.session.rpcFault(cwmpRequest.id, cwmpRequest.fault, (err) ->
          nextRpc(currentRequest)
        )
      else
        # cpe sent empty response. add presets
        nextRpc(currentRequest)
    )
  )


exports.listener = listener
