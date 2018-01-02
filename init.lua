-- Copyright 2015 Boundary, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local framework = require('framework')
local url = require('url')
local Plugin = framework.Plugin
local WebRequestDataSource = framework.WebRequestDataSource
local Accumulator = framework.Accumulator
local gsplit = framework.string.gsplit
local split = framework.string.split
local auth = framework.util.auth
local isHttpSuccess = framework.util.isHttpSuccess
local ratio = framework.util.ratio

local json = require('json')
local env = require('env')

local params = env.get("TSP_PLUGIN_PARAMS")
if(params == nil or  params == '') then
   params = framework.params
else
   params = json.parse(params)
end

local options = url.parse(params.url)
options.path = options.path .. '?auto' -- server-status?auto for text/plain output
options.auth = auth(params.username, params.password) 
options.wait_for_end = true

local mapping = { 
  ['BusyWorkers'] = 'APACHE_BUSY_WORKERS',
  ['IdleWorkers'] = 'APACHE_IDLE_WORKERS',
  ['Total Accesses'] = 'APACHE_REQUESTS',
  ['CPULoad'] = 'APACHE_CPU',
  ['Total kBytes'] = 'APACHE_BYTES'
}
  
local data_source = WebRequestDataSource:new(options)
local acc = Accumulator:new()

local plugin = Plugin:new(params, data_source)
function plugin:onParseValues(data, extra)
  if not isHttpSuccess(extra.status_code) then
    self:emitEvent('error', ('Http Request returned %s instead of OK. Please check the Apache Webserver status page configuration.'):format(extra.status_code))
    return
  end

  -- Capture metrics
  local result = {}
  for v in gsplit(data, "\n") do
    local m = split(v, ":")
    local key, val = unpack(m)
    if (key and val) then
      local metric = mapping[key] 
      if metric then
        result[metric] = tonumber(val) or -1
      end
    end
  end

  -- CPU Load calculations
  local cpu_load = result['APACHE_CPU'] or 0
  if (cpu_load > 1) then
    cpu_load = cpu_load / 100
  end
  result['APACHE_CPU'] = cpu_load

  -- Requests calculation
  local requests = acc('APACHE_REQUESTS', result['APACHE_REQUESTS']) 
  result['APACHE_REQUESTS'] = requests

  -- Total Bytes calculation
  -- Because of the interval cut off lines, on a really slow site you will get 0's
  -- the, use the previous value if that happens
  local last_total_bytes = acc:get('APACHE_BYTES')
  local total_bytes = acc('APACHE_BYTES', result['APACHE_BYTES'] * 1024)
  if requests > 0 and total_bytes == 0 then
      total_bytes = last_total_bytes
  end
  result['APACHE_BYTES'] = total_bytes

  -- Total Bytes Per Request calculation
  local bytes_per_req = ratio(total_bytes, requests)
  result['APACHE_BYTES_PER_REQUEST'] = bytes_per_req

  -- Busy Ratio calculation
  local total_workers =  (result['APACHE_BUSY_WORKERS'] or 0) + (result['APACHE_IDLE_WORKERS'] or 0)
  local busy_ratio = ratio(result['APACHE_BUSY_WORKERS'], total_workers)
  result['APACHE_BUSY_RATIO'] = busy_ratio

  return result
end
plugin:run()

