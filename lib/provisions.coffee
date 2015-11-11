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

# Adapted from http://stackoverflow.com/a/5450113
repeat = (pattern, count) ->
  result = ''
  return result if count < 1

  while count > 1
    if count & 1
      result += pattern
    count >>= 1
    pattern += pattern;
  return result + pattern;


processProvision = (type, args, callback) ->
  switch type
    when 'refresh'
      getAssertions = {}
      r = 15 - (args[0].split('.').length)
      for i in [0...r]
        getAssertions["#{args[0]}#{repeat('.*', i)}"] = {"value" : args[1], "discover" : args[1]}
      return callback(null, getAssertions)
    else
      return callback(new Error("Unknown provision type '#{type}'"))


exports.processProvision = processProvision
