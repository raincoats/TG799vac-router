local dm = require("datamodel")
require("web.web") -- Enables tainting
local ngx = ngx
local ipairs, pairs, type =
      ipairs, pairs, type
local format = string.format
local match, untaint = string.match, string.untaint
local SessionMgr = require("web.sessionmgr")

---------------------------------------------------------------
-- Module web.sessioncontrol
---------------------------------------------------------------
local s_mgrs = {} -- all session managers
local s_users = {} -- all possible users
local s_rulesets = {} -- all possible rulesets
local s_rules = {} -- all possible rules
local s_config_loaded = false -- Have the session managers been loaded.
local s_mgr_map = {} -- Mapping of managers to ports.

--- Handler function for the ngx timer.
local function handler(premature, mgr)
  if premature then
    return
  end
  local remaining = mgr:cleanup()
  if remaining > 0 then
    -- Sessions remaining, create a new timer
    local ok, err = ngx.timer.at(mgr["timeout"], handler, mgr)
    if not ok then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
      return
    end
  else
    --All sessions deleted, no timer needed
    mgr.timerset = false
  end
end

--- Convert the data table returned by the 'datamodel' module into a more structured
-- and workable representation we can use for our configuration. Possible tainted values
-- are also untainted.
local function convert_data_to_config(data)
  local config = {}
  for _, v in ipairs(data) do
    local section, name, listparam = match(v.path, "uci%.web%.([^%.]+)%.@([^%.]+)%.([^%.]*)")
    if section then
      local value = untaint(v.value)
      local t = config[section]
      if not t then
        t = {}
        config[section] = t
      end
      t = t[name]
      if not t then
        t = {}
        config[section][name] = t
      end
      if #listparam == 0 then
        t[v.param] = value
      else
        local listvalues = t[listparam]
        if not listvalues then
          listvalues = {}
          t[listparam] = listvalues
        end
        listvalues[value] = value
      end
    end
  end
  return config
end

--- Helper function to retrieve configuration from our 'datamodel' module.
-- @param path #string A path we wish to retrieve the config from. Only paths starting with
--                     'uci.web.' will return a non empty configuration.
local function get_datamodel_config(path)
  local data, errmsg = dm.get(path)
  if not data then
    ngx.log(ngx.ERR, "failed to retrieve config: ", errmsg)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  return convert_data_to_config(data)
end

--- Helper function to overwrite an existing table.
-- This method will keep the reference to the original table intact,
-- but will replace its content with the content from the new table.
-- @param #table original_table The original table, for which the reference needs to be preserved.
-- @param #table new_table The new table which contains the new content for the original table.
local function overwrite_table(original_table, new_table)
  -- Clear the original table.
  for k in pairs(original_table) do
    original_table[k] = nil
  end
  -- Copy the key-value pairs from the new table into the original table.
  for k,v in pairs(new_table) do
    original_table[k] = v
  end
end

--- Expand the rulesets
local function expand_rulesets()
  -- Iterate over all rulesets and load the actual rules into the rulesets.
  for rulesetname, ruleset in pairs(s_rulesets) do
    -- Clear any previously loaded rules. We avoid creating a new table since
    -- a reference to the old table may still exist in a session manager.
    for k in pairs(ruleset) do
      if k ~= "rules" then
        ruleset[k] = nil
      end
    end
    if type(ruleset.rules) == "table" then
      for _, rulename in pairs(ruleset.rules) do
        local rule = s_rules[rulename]
        -- A corresponding rule is found, expand it.
        if rule then
          if not ruleset[rule.target] then
            ruleset[rule.target] = {}
          end
          for _, role in pairs(rule.roles) do
            ruleset[rule.target][role] = true
          end
        end
      end
    end
  end
end

local M = {}

--- Parse the given config and load it to the session controller.
-- @param #table config A table representation of the config to load. This does not have to be a full config.
local function parse_config(config)
  -- Parse rules
  if config.rule and type(config.rule) == "table" then
    local oldrules = {} -- This table tracks which old rules have been renewed.
                        -- If one of the rules is not renewed, it means it has been deleted.
    for oldrulename in pairs(s_rules) do
      oldrules[oldrulename] = true
    end
    for rulename, ruleconfig in pairs(config.rule) do
      if s_rules[rulename] then
        -- We already know a rule by this name, overwrite it,
        -- but make sure old references remain valid.
        overwrite_table(s_rules[rulename], ruleconfig)
        oldrules[rulename] = nil
      else
        s_rules[rulename] = ruleconfig
      end
    end
    for deletedrulename in pairs(oldrules) do
      s_rules[deletedrulename] = nil
    end
  end
  -- Parse rulesets
  if config.ruleset and type(config.ruleset) == "table" then
    -- First clear the old rulesets. Don't delete them, since session managers
    -- may have links to them.
    -- If a ruleset is ever deleted before a reload, an empty table will still exist
    -- until reboot.
    for oldrulesetname, old_ruleset in pairs(s_rulesets) do
      overwrite_table(old_ruleset, {})
    end
    for rulesetname, rulesetconfig in pairs(config.ruleset) do
      if s_rulesets[rulesetname] then
        -- Overwrite the old rules.
        s_rulesets[rulesetname].rules = rulesetconfig.rules
      else
        s_rulesets[rulesetname] = {rules = rulesetconfig.rules}
      end
    end
  end
  expand_rulesets()
  -- Parse users
  if config.user and type(config.user) == "table" then
    local oldusers = {} -- This table tracks which old users have been renewed.
                        -- If one of the users is not renewed, it means it has been deleted.
    for oldusername in pairs(s_users) do
      oldusers[oldusername] = true
    end
    for username, userconfig in pairs(config.user) do
      -- TODO: we could memoize the 'roles' tables...
      if s_users[username] then
        -- We already know a user by this name, overwrite it,
        -- but make sure old references remain valid.
        overwrite_table(s_users[username], userconfig)
        oldusers[username] = nil
      else
        s_users[username] = userconfig
      end
      s_users[username].sectionname = username
    end
    for deletedusername in pairs(oldusers) do
      s_users[deletedusername] = nil
    end
  end
  -- Parse session managers
  if config.sessionmgr and type(config.sessionmgr) == "table" then
    local oldmgrs = {}  -- This table tracks which old session managers have been renewed.
                        -- If one of the managers is not renewed, it means it has been deleted.
    for oldmgrname in pairs(s_mgrs) do
      oldmgrs[oldmgrname] = true
    end
    for sessionmgrname, sessionmgrconfig in pairs(config.sessionmgr) do
      if s_mgrs[sessionmgrname] then
        -- We already know a session manager by this name, reload it
        -- with the new session manager config.
        s_mgrs[sessionmgrname]:reloadConfig(sessionmgrconfig)
        oldmgrs[sessionmgrname] = nil
      else
        -- Create a new session manager.
        s_mgrs[sessionmgrname] = SessionMgr.new(sessionmgrname, sessionmgrconfig, M)
      end
    end
    for deletedmgrname in pairs(oldmgrs) do
      s_mgrs[deletedmgrname] = nil
    end
  end
end

local function load_config()
  if s_config_loaded then
    return
  end
  -- get complete config from UCI; measurements show this is faster
  -- than retrieving bits and pieces in separate requests (especially
  -- on firstboot when Transformer needs to populate its DB)
  local config = get_datamodel_config("uci.web.")
  parse_config(config)
  s_config_loaded = true
end

local function loadmgr(name)
  -- is the mgr with the given name already loaded?
  local mgr = s_mgrs[name]
  if not mgr then
    load_config()
    mgr = s_mgrs[name]
    if not mgr then
      ngx.log(ngx.ERR, "no config found for sessionmgr ", name)
      ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
  end
  return mgr
end

function M.loadmgr(name)
  return loadmgr(name)
end

function M.reloadUsers()
  parse_config(get_datamodel_config("uci.web.user."))
  for _, mgr in pairs(s_mgrs) do
    mgr:reloadUsers()
  end
end

function M.setManagerForPort(mgrname, port)
  s_mgr_map[port] = mgrname
end

-- return a port the manager is registered on
-- \param mgrname (string) the name of the session manager
-- \returns the port or nil if not found
-- For session manager where the port number matters (eg remote assistance)
-- it must be running on a single port.
function M.mgrport(mgrname)
  for port, name in pairs(s_mgr_map) do
    if name == mgrname then
      return port
    end
  end
end

--- Get the session manager according to the given request.
-- If it doesn't exist it will try to load it from the datamodel.
-- This function may only be called in the access phase.
-- The name of the manager to load is either explicitly given or
-- will be derived from the server_port the request was received on.
function M.getmgr(name)
  local port = ngx.var.server_port
  local mgrname = name or s_mgr_map[port]

  -- we must have a session manager name to continue
  if not mgrname then
    ngx.log(ngx.ERR, "no manager for this server")
    ngx.exit(ngx.HTTP_NOT_FOUND)
  end

  -- must only be called in access phase
  if ngx.get_phase() ~= "access" then
    ngx.log(ngx.ERR, "web.session.getmgr() called outside access phase")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  local mgr = loadmgr(mgrname)
  if not mgr.timerset then
    local ok, err = ngx.timer.at(mgr["timeout"], handler, mgr)
    if not ok then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
      return
    end
    mgr.timerset = true
  end
  return mgr
end

function M.getruleset(name)
  return s_rulesets[name]
end

function M.getuser(name)
  return s_users[name]
end

function M.changePassword(user, salt, verifier)
  local rc, errors = dm.set({
    ["uci.web.user.@" .. user.sectionname .. ".srp_salt"] = salt,
    ["uci.web.user.@" .. user.sectionname .. ".srp_verifier"] = verifier
  })
  if not rc then
    return nil, errors[1].errmsg
  end
  user.srp_salt = untaint(salt)
  user.srp_verifier = untaint(verifier)
  return true
end

--- override the ngx.redirect function to handle the case were the publicly used
-- ip and/or port are different from the ones actually used.
-- This happens for remote assistance and in cases traffic is redirected.
local ngx_redirect = ngx.redirect
ngx.redirect = function(url, status)
  local mgr
  local abs_url_pattern = "^[^/]*://"

  if not url:match(abs_url_pattern) then
    -- it is not an absolute URL (we won't touch those)
    -- retrieve the SessionMgr for the the current session, do not use getmgr as
    -- we are not in the access phase.
    local port = ngx.var.server_port
    local mgrname = s_mgr_map[port]
    if mgrname then
      mgr = loadmgr(mgrname)
    end
  end

  if mgr then
    local scheme = ngx.var.scheme
    local ext_ip, ext_port = mgr:getExternalAddress()
    ext_ip = ext_ip or ngx.var.server_addr
    ext_port = ext_port or ngx.var.server_port
    url = format('%s://%s:%s%s', scheme, ext_ip, ext_port, url)
  end
  -- note that we cannot pass status as nil. the ngx.redirect is a C function
  -- that checks the number of parameters. If we pass nil as status it will
  -- complain that it expects a number. So we have to make sure we pass some
  -- default value.
  return ngx_redirect(url, status or ngx.HTTP_MOVED_TEMPORARILY)
end


return M
