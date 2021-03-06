local M = {}
local Script = {}
local prefix = '/etc/wansensing/'

Script.__index = Script

local function set (list)
    local set = { timeout = true } -- timeout events by default
    if list then
        for _, l in ipairs(list) do set[l] = true end
    end
    return set
end

function Script:name()
    return self.scriptname
end

function Script:entry( requester, runtime, ... )
    runtime.logger:notice("("  .. requester .. ") runs " .. self.scriptname .. ".entry(" .. M.parameters( ... ) .. ")" )
    status, return1 = pcall(self.scripthandle.entry, runtime, ...)
    if not status or not return1 then
       runtime.logger:error(self.scriptname .. ".entry(" .. M.parameters( ... ) .. ") throws error :" .. tostring(return1) )
       runtime.logger:error("stopped due error in script" .. self.scriptname)
       assert(false)
    end
    return return1
end

function Script:poll( requester, runtime, ... )
    runtime.logger:notice("("  .. requester .. ") runs " .. self.scriptname .. ".check(" .. M.parameters( ... ) .. ")" )
    status, return1, return2 = pcall(self.scripthandle.check, runtime, ...)
    if not status then
       runtime.logger:error(self.scriptname .. ".check(" .. M.parameters( ... ) .. ") throws error :" .. tostring(return1) )
       runtime.logger:error("stopped due error in script" .. self.scriptname)
       assert(false)
    end
    return return1, return2
end

function Script:exit( requester, runtime, ... )
    runtime.logger:notice("("  .. requester .. ") runs " .. self.scriptname .. ".exit(" .. M.parameters( ... ) .. ")" )
    status,return1 = pcall(self.scripthandle.exit, runtime, ...)
    if not status or not return1 then
       runtime.logger:error(self.scriptname .. ".exit(" .. M.parameters( ... ) .. ") throws error :" .. tostring(return1) )
       runtime.logger:error("stopped due error in script" .. self.scriptname)
       assert(false)
    end
    return return1
end

function M.parameters( ... )
    local parameters = ""
    if ( arg.n )  then
        for i,v in ipairs(arg) do
            if ( i > 1 ) then
                parameters = parameters .. ","
            end
            parameters = parameters .. tostring(v)
        end
    end
    return parameters
end

function M.load(script, runtime)
    local self = {}
    local f = loadfile(prefix .. script .. ".lua")
    if not f then
       runtime.logger:error("error in loading script(" .. prefix .. script .. ")")
       assert(false)
    end

    self.scriptname=script
    self.scripthandle = f()
    setmetatable(self, Script)
    return self, set(self.scripthandle.SenseEventSet)
end

function M.initmode_save(x, mode)
    local config = "wansensing"
    x:load(config)
    x:set(config, "global", "initmode", mode)
    x:commit(config)
end

function M.l2type_save(x, l2type)
    local config = "wansensing"
    x:load(config)
    x:set(config, "global", "l2type", l2type)
    x:commit(config)
end

function M.l2type_get(x)
    local config = "wansensing"
    x:load(config)
    return x:get(config, "global", "l2type")
end

function M.l3type_save(x, l3type)
    local config = "wansensing"
    x:load(config)
    x:set(config, "global", "l3type", l3type)
    x:commit(config)
end

function M.l3type_get(x)
    local config = "wansensing"
    x:load(config)
    return x:get(config, "global", "l3type")
end

return M