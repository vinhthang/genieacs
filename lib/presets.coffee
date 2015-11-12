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

config = require './config'
common = require './common'
db = require './db'
query = require './query'


getActivePresets = (device, callback) ->
  db.getPresetsObjectsAliases((presets, objects, aliases) ->
    res = {}
    counter = 1
    for p in presets
      ++ counter
      if common.typeOf(p.precondition) is common.STRING_TYPE
        p.precondition = query.expand(JSON.parse(p.precondition), aliases)
      else
        # Accept an object for backward compatiblity
        p.precondition = query.expand(p.precondition ? {}, aliases)

      device.get(Object.keys(query.projection(p.precondition)), (err, params) ->
        if err
          callback(err) if -- counter >= 0
          counter = 0
          return

        if query.test(params, p.precondition)
          preset = {weight: p.weight, provisions: []}
          for c in p.configurations
            switch c.type
              when 'age'
                preset.provisions.push(['refresh', c.name, c.age * -1000])
              else
                throw new Error("Unknown configuration type #{c.type}")
          res[p._id] = preset

        if -- counter == 0
          return callback(null, res)
      )

    if -- counter == 0
      return callback(null, res)
  )


exports.getActivePresets = getActivePresets
