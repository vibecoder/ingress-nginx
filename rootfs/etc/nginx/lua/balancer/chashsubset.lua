-- Consistent hashing to a subset of nodes. Instead of returning the same node
-- always, we return the same subset always.

local resty_chash = require("resty.chash")
local util = require("util")
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local setmetatable = setmetatable
local tostring = tostring
local math = math
local table = table
local pairs = pairs
local ck = require("resty.cookie")
local tonumber = tonumber

local _M = { name = "chashsubset" }

local function build_subset_map(backend)
  local endpoints = {}
  local subset_map = {}
  local subsets = {}
  local subset_size = backend["upstreamHashByConfig"]["upstream-hash-by-subset-size"]

  for _, endpoint in pairs(backend.endpoints) do
    table.insert(endpoints, endpoint)
  end

  local set_count = math.ceil(#endpoints/subset_size)
  local node_count = set_count * subset_size
  -- if we don't have enough endpoints, we reuse endpoints in the last set to
  -- keep the same number on all of them.
  local j = 1
  for _ = #endpoints+1, node_count do
    table.insert(endpoints, endpoints[j])
    j = j+1
  end

  local k = 1
  for i = 1, set_count do
    local subset = {}
    local subset_id = "set" .. tostring(i)
    for _ = 1, subset_size do
      table.insert(subset, endpoints[k])
      k = k+1
    end
    subsets[subset_id] = subset
    subset_map[subset_id] = 1
  end

  return subset_map, subsets
end

function _M.new(self, backend)
  local subset_map, subsets = build_subset_map(backend)
  local complex_val, err =
    util.parse_complex_value(backend["upstreamHashByConfig"]["upstream-hash-by"])
  if err ~= nil then
    ngx_log(ngx_ERR, "could not parse the value of the upstream-hash-by: ", err)
  end

  local complex_val_extra, err =
    util.parse_complex_value(backend["upstreamHashByConfig"]["upstream-hash-by-subset-extra-header"])
  if err ~= nil then
    ngx_log(ngx_ERR, "could not parse the value of the upstream-hash-by-subset-extra-header: ", err)
  end

  local cookie_name = backend["upstreamHashByConfig"]["upstream-hash-by-subset-cookie-name"]
  if cookie_name == nil then
    cookie_name = "subsetRouteCookie"
  end

  local cookie_value, err =
    util.parse_complex_value("$cookie_" .. cookie_name)
  if err ~= nil then
    ngx_log(ngx_ERR, "could not parse the value of the upstream-hash-by-subset-cookie-name: ", err)
  end

  local o = {
    instance = resty_chash:new(subset_map),
    hash_by = complex_val,
    hash_by_extra = complex_val_extra,
    subsets = subsets,
    current_endpoints = backend.endpoints,
    cookie_name = cookie_name,
    cookie_value = cookie_value,
    traffic_shaping_policy = backend.trafficShapingPolicy,
    alternative_backends = backend.alternativeBackends,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function _M.is_affinitized()
  return false
end

function _M.balance(self)
  local key = util.generate_var_value(self.hash_by)
  if key == "" then
    key = util.generate_var_value(self.hash_by_extra)
  end
  local subset_id = self.instance:find(key)
  local endpoints = self.subsets[subset_id]
  local cookie_value = util.generate_var_value(self.cookie_value)

  local cookie_value_num = tonumber(cookie_value)
  if cookie_value_num ~= nil  then
    local endpoint = endpoints[cookie_value_num]
    return endpoint.address .. ":" .. endpoint.port
  end


  local randomEndpoint = math.random(#endpoints)
  local endpoint = endpoints[randomEndpoint]
  local cookie = ck:new()
  local cookie_data = {
    key = tostring(self.cookie_name),
    value = randomEndpoint,
  }
  cookie:set(cookie_data)
  return endpoint.address .. ":" .. endpoint.port
end

function _M.sync(self, backend)
  local subset_map

  local changed = not util.deep_compare(self.current_endpoints, backend.endpoints)
  if not changed then
    return
  end

  self.current_endpoints = backend.endpoints

  subset_map, self.subsets = build_subset_map(backend)

  self.instance:reinit(subset_map)

  return
end

return _M
