local ipairs, next = ipairs, next
local format = string.format

---
-- @module transformer.mapper.uci_1to1
local M = {}

local function set_objecttype_parameters(options, objectType)
  for _, v in ipairs(options) do
    objectType.parameters[v] = {
      access = "readWrite",
      type = "string"
    }
  end
end

local function set_binding_parameters(mapinfo, binding)
  for _, v in ipairs(mapinfo.options) do
    binding[v] = {
      config = mapinfo.config,
      sectionname = mapinfo.section,
      sectiontype = mapinfo.type, -- if available
      option = v,
      default = ""
    }
  end
end

local function set_binding_parameters_multimap(options, binding)
  for _, v in ipairs(options) do
    binding[v] = v
  end
end

local function complete_simplemap(mapinfo, mapping, binding)
  mapping.objectType = {
    name = format("uci.%s.%s.", mapinfo.config, mapinfo.section),
    access = "readOnly",
    minEntries = 1,
    maxEntries = 1,
    parameters = {},
  }

  if mapinfo.options and next(mapinfo.options) then
    set_objecttype_parameters(mapinfo.options, mapping.objectType)
    set_binding_parameters(mapinfo, binding)
  end
end

local function complete_multimap(mapinfo, mapping, binding)
  mapping.objectType = {
    name = format("uci.%s.%s.%s.", mapinfo.config, mapinfo.type, mapping.index_spec),
    access = "readWrite",
    numEntriesParameter = mapinfo.type .. "NumberOfEntries",
    minEntries = 0,
    maxEntries = math.huge,
    parameters = {},
  }

  binding.global_config = mapinfo.config
  binding.global_type = mapinfo.type

  if mapinfo.options and next(mapinfo.options) then
    set_objecttype_parameters(mapinfo.options, mapping.objectType)
    set_binding_parameters_multimap(mapinfo.options, binding)
  end
end

local function create_submappings_lists(mapinfo, mapping, ucilist)
  local submappings = {}
  for _, v in ipairs(mapinfo.lists) do
    submappings[#submappings + 1] = ucilist.createListMap(mapping,
      mapinfo.config, mapinfo.section, mapinfo.type, v)
  end
  return submappings
end

---
-- @function [parent=#transformer.mapper.uci_1to1] createConfigMap
-- @param #table config
-- @return #table
function M.createConfigMap(config)
  return {
    objectType = {
      name = format("uci.%s.", config),
      access = "readOnly",
      minEntries = 1,
      maxEntries = 1,
      parameters = {},
    }
  }
end

---
-- @function [parent=#transformer.mapper.uci_1to1] createSimpleMap
-- @param #table mapinfo
-- @return #table
function M.createSimpleMap(mapinfo)
  local mapping = {}
  local binding = {}
  complete_simplemap(mapinfo, mapping, binding)
  if next(binding) then
    mapper("simpleuci").connect(mapping, binding)
  end
  if mapinfo.lists then
    local ucilist = mapper("ucilist")
    mapping.submappings = create_submappings_lists(mapinfo, mapping, ucilist)
  end
  return mapping
end


---
-- @function [parent=#transformer.mapper.uci_1to1] createMultiMap
-- @param #table mapinfo
-- @return #table
function M.createMultiMap(mapinfo)
  local mapping = {}
  local binding = {}
  mapping.index_spec = "{i}"
  complete_multimap(mapinfo, mapping, binding)
  mapper("multiuci").connect(mapping, binding)
  if mapinfo.lists then
    local ucilist = mapper("ucilist")
    mapping.submappings = create_submappings_lists(mapinfo, mapping, ucilist)
  end
  return mapping
end

---
-- @function [parent=#transformer.mapper.uci_1to1] createNamedMultiMap
-- @param #table mapinfo
-- @return #table
function M.createNamedMultiMap(mapinfo)
  local mapping = {}
  local binding = {}
  mapping.index_spec = "@"
  complete_multimap(mapinfo, mapping, binding)
  mapper("multiuci").connect(mapping, binding)
  if mapinfo.lists then
    local ucilist = mapper("ucilist")
    mapping.submappings = create_submappings_lists(mapinfo, mapping, ucilist)
  end
  return mapping
end

---
-- @function [parent=#transformer.mapper.uci_1to1] registerSubmaps
-- @param #table maps
-- @return #table
function M.registerSubmaps(maps)
  if maps then
    for _,v in ipairs(maps) do
      register(v)
    end
  end
end

---
-- @function [parent=#transformer.mapper.uci_1to1] registerConfigMap
-- @param #table config
function M.registerConfigMap(config)
  register(M.createConfigMap(config))
end

---
-- @function [parent=#transformer.mapper.uci_1to1] registerSimpleMap
-- @param #table mapinfo
function M.registerSimpleMap(mapinfo)
  local map = M.createSimpleMap(mapinfo)
  register(map)
  M.registerSubmaps(map.submappings)
end

---
-- @function [parent=#transformer.mapper.uci_1to1] registerMultiMap
-- @param #table mapinfo
function M.registerMultiMap(mapinfo)
  local map = M.createMultiMap(mapinfo)
  register(map)
  M.registerSubmaps(map.submappings)
end

---
-- @function [parent=#transformer.mapper.uci_1to1] registerNamedMultiMap
-- @param #table mapinfo
function M.registerNamedMultiMap(mapinfo)
  local map = M.createNamedMultiMap(mapinfo)
  register(map)
  M.registerSubmaps(map.submappings)
end

return M
