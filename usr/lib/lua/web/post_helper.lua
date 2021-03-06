local ngx, require = ngx, require
local proxy = require("datamodel")
local bit = require("bit")
local content_helper = require("web.content_helper")
local message_helper = require("web.uimessage_helper")
local pairs, ipairs, tonumber, type, setmetatable = pairs, ipairs, tonumber, type, setmetatable
local floor = math.floor
local random, huge = math.random, math.huge
local istainted, format, match, find, sub = string.istainted, string.format, string.match, string.find, string.sub
local concat, remove = table.concat, table.remove
local untaint_mt = require("web.taint").untaint_mt

-- Translation initialization. Every function relying on translation MUST call setlanguage to ensure the current
-- language is correctly set (it will fetch the language set by web.web and use it)
-- We create a dedicated context for the web framework (since we cannot easily access the context of the current page)
local intl = require("web.intl")
local function log_gettext_error(msg)
    ngx.log(ngx.NOTICE, msg)
end
local gettext = intl.load_gettext(log_gettext_error)
local T = gettext.gettext
local N = gettext.ngettext

local function setlanguage()
    gettext.language(ngx.header['Content-Language'])
end

gettext.textdomain('web-framework-tch')

--- post_helper module
--  @module post_helper
--  @usage local post_helper = require('web.post_helper')
--  @usage require('web.post_helper')
local M = {}

--- Method to store the POST parameters sent by the UI in UCI (SAVE action)
-- @function [parent=#post_helper] handleQuery
-- @param #table mapParams key/string dictionary containing for each form control's name, the associated path
--                      this should be an exact path since we're going to write
--                      if you need to READ partial paths, please do so after this function has run
-- @param #table mapValidation key/function dictionary containing for each form control's name, the associated
--                      validation function. The validation function should return (err, msg). If err
--                      is nil, then msg should contain an error message, otherwise err should be true
-- @return #table,#table it returns a dictionary containing for each input name, the retrieved value from UCI
--          and another dictionary containing for each failed validation the help message
function M.handleQuery(mapParams, mapValidation)
    setlanguage()
    -- if GET, we'll need to retrieve everything. Code path in POST can change that based on input
    local content = {}
    local helpmsg = {}

    for k,v in pairs(mapParams) do
        content[k] = v
    end
    local success, errmsg = content_helper.getExactContent(content)
    if not success then
        message_helper.pushMessage(errmsg, "error")
        return content, helpmsg
    end

    -- Check if we're in a POST query or in a GET query, if POST only process on form encoded data
    if ngx.var.request_method == "POST" and ngx.var.content_type and match(ngx.var.content_type, "application/x%-www%-form%-urlencoded") then
        local post_data = ngx.req.get_post_args()

        if (post_data["action"] == "SAVE") then
            -- Save original data in case validation does remove some parameters
            local original_data = {}
            for k,v in pairs(content) do
                original_data[k] = v
            end

            -- now overwrite the data
            for k,v in pairs(post_data) do
                content[k] = v
            end

            -- Start by applying the corresponding validation function to each parameter
            -- we receive.
            local validated
            validated, helpmsg = content_helper.validateObject(content, mapValidation)

            -- Now assuming that everything was validated, we can prepare to store the data
            if validated then
                local ok, msg = content_helper.setObject(content, mapParams)
                if ok then
                    ok, msg = proxy.apply()
                    -- now in case some validation function removed some data, we bring it back from the original load
                    -- for instance, password validation will just remove the password data when getting the dummy value
                    for k,_ in pairs(mapParams) do
                        if not content[k] then
                            content[k] = original_data[k]
                        end
                    end

                    if not ok then
                        ngx.log(ngx.ERR, "apply failed: " .. msg)
                        message_helper.pushMessage(T"Error while applying changes", "error")
                    else
                        message_helper.pushMessage(T"Changes saved successfully", "success")
                    end
                else
                    ngx.log(ngx.ERR, "setObject failed: " .. msg)
                    message_helper.pushMessage(T"Error while saving changes", "error")
                    -- we cannot assume every transaction is atomic (not every mapping will implement it) so to be safe
                    -- we reload the data
                    for k,v in pairs(mapParams) do
                        content[k] = v
                    end
                    content_helper.getExactContent(content)
                end
            else
                message_helper.pushMessage(T"Some parameters failed validation", "error")
            end
        end
    end

    return content, helpmsg
end

--- Merge two tables. Take the content of toadd and put it in content overwriting any existing element
-- @function [parent=#post_helper] mergeTables
-- @param #table content the main table
-- @param #table toadd the table to add to the main table
-- @return nothing but content is updated
function M.mergeTables(content, toadd)
    if content == nil then
        content = {}
    end
    if toadd == nil then
        return
    end
    for _,v in ipairs(toadd) do
        content[v.param] = v.value
    end
end

---
-- Converts a columns table to a input name => transformer name table
-- @param #table columns structure
-- @param #bool withro [optional] also include parameters set as readonly
-- @return #table map
local function columnsToParamMap(columns, withro)
    local map = {}
    for _,v in ipairs(columns) do
        if v.type == "aggregate" then
            for _, sv in ipairs(v.subcolumns) do
                if withro or not sv.readonly then
                    map[sv.name] = sv.param
                end
            end
        else
            if withro or not v.readonly then
                map[v.name] = v.param
            end
        end
    end
    return map
end

-- Ensuring the integrity of the changes made to a table
-- modify -> might overwrite previous changes, or line could have been deleted - check when starting the change and when applying the change
-- delete -> might try to delete something that was already deleted
-- add -> fine nothing to fear (still need proper validation)
--
-- when trying to apply the change, check if changes were made in between
-- to know if a change is allowed, one thing needs to be considered: did we load the page before or after the last change
--
-- every time there is a change to a table, I generate a new stateId
-- when I load a table, I include the current stateId in the data sent to the browser
-- when I submit something, I include the transactionId
-- the server compares the transactionId in the query and the one in the session store
-- - if they're the same, we make the change
-- - if they're different, we cancel the query and show a warning message telling the user changes took place and he should start again
--
-- NOTE: this mechanism should actually be implemented at a "global" level rather than session level. We need to take into account changes that
--       could be made by another user or another browser session
local function generateStateId()
    -- TODO: use something more robust
    return "stateid." .. random()
end

--- Checks if the state sent by the client corresponds to the one stored in the session
--  If not, then changes happened between the time we displayed the page and now, so the
--  user must start again
-- @param #string server
-- @param #string client
local function checkStateId(server, client)
    if server == nil and client == "" then
        return true
    end
    if server == client then
        return true
    end
    return false
end

local changesNotAllowed = T"Changes not allowed."
local changesconflictMsg = T"Changes were made to this table which require you to start again."
local invalidIndexMsg = T"You tried to access an invalid line."
local errorWhileSaving = T"An error occured while saving your changes."
local errorWhileApplying = T"An error occured while applying your changes."

--- apply changes if successful, other set error message in the options object
-- @param #bool success result from the proxy call
-- @param #bool canApply
-- @param #table options
local function applyOnSuccess(success, canApply, options)
    if success then
        if canApply == true then
            proxy.apply()
        end
    else
        options.errmsg = errorWhileSaving
    end
end

--- this function retrieves any missing data vs the data provided in the post
-- this is used to validate the full dataset instead of just one parameter
-- otherwise it could be possible to
-- @param #string indexpath
-- @param #string index
-- @param #table postdata data sent by the user in the post query
-- @param #table mapparam complete list of parameters for the columns
-- @param #table mapvalid validation functions
local function getObjectAndValidate(indexpath, index, postdata, mapparam, mapvalid)
    local toretrieve = {}
    for k,v in pairs(mapparam) do
        if not postdata[k] then
            toretrieve[k] = indexpath .. index .. "." .. v
        end
    end
    local success = content_helper.getExactContent(toretrieve)
    if success then
        for k,v in pairs(toretrieve) do
           postdata[k] = v
        end
    end
    return content_helper.validateObject(postdata, mapvalid)
end

local function complementObjectAndValidate(postdata, mapparam, mapvalid)
    for k,v in pairs(mapparam) do
       if not postdata[k] then
          postdata[k] = "" -- put a default value to get it through validation, it should have been sent in the post data
       end
    end
    return content_helper.validateObject(postdata, mapvalid)
end

local function checkUniqueParams(basepath, fullpath, columns, content)
  local success = true
  local helpmsg = {}

  for _,v in ipairs(columns) do
    if v.unique then
      local value = string.untaint(content[v.name])
      local cmatch = content_helper.getMatchedContent(basepath, { [v.param] = value })
      if fullpath then
        for i,v in ipairs(cmatch) do
          if v.path == fullpath then
            table.remove(cmatch, i)
            break
          end
        end
      end
      if #cmatch > 0 then
        success = nil
        helpmsg[v.name] = T"duplicate value"
      end
    end
  end
  return success, helpmsg
end

local function convertPostToArray(columns, data)
    local line = {}
    for _,v in ipairs(columns) do
        if v.type == "aggregate" then
            line[#line+1] = convertPostToArray(v.subcolumns, data)
        else
            line[#line+1] = data[v.name]
        end
    end
    return line
end

local function applyGlobalValidation(basepath, columns, filter, paramindex, content, valid, sorted)
    if valid then
        local data, allowedIndexes = content_helper.loadTableData(basepath, columns, filter, sorted)
        local idx

        if paramindex then
            -- Modify or Delete
            for i,v in ipairs(allowedIndexes) do
                -- We're looking at the actual instance index because the order in which elements are returned is not
                -- always stable. So just to be sure, we find the correct index based on the paramindex of the element
                if paramindex == v.paramindex then
                    idx = i
                end
            end

            -- If idx was not found, then something is completely wrong
            if not idx then
               return nil
            end
        else
            idx = #data + 1
        end

        if content == nil then
            -- Delete case
            table.remove(data, idx)
        else
            -- Add / Modify case
            data[idx] = convertPostToArray(columns, content)
        end
        return valid(data)
    else
        return true
    end
end

--- Method to handle queries generated by standard UI tables
-- @function [parent=#post_helper] handleTableQuery
-- @param #table columns array describing each column of the table
-- @param #table options table containing options for the table
--               canEdit - bool indicating if we should allow editing a line
--               canAddDelete - bool indicating if we should allow adding / removing lines
--               canApply - bool indicating if we should allow restart related module after uci changes
--               editing - int - index of the currently edited element (-1 if new element, 0 if not editing)
--               minEntries - int - minimum number of entries in the table (will prevent delete under this number)
--               maxEntries - int - maximum number of entries in the table (will prevent adding above this number)
--               tableid - string - id of the table
--               basepath - string - base path for parameters in transformer
--               stateid - string - token used to detect if changes happened since the page was displayed
--               errmsg - string - global error message (for the table) to display
--               sorted - string or function - sorted method for table data
-- @param filter function that accepts a line data as the input and returns true if it should be included
--               or false otherwise
-- @param #table defaultObject table or nil (transformer param name => value)
--               1) table that is merged with the data gathered from the form before being written
--               2) nil just use the data gathered from the form without change
-- @param #table mapValidation for each input name maps to a function that returns true if the value is "valid"
--               or returns false if the value is invalid
-- @return #table, #table
function M.handleTableQuery(columns, options, filter, defaultObject, mapValidation)
    setlanguage()
    local data, allowedIndexes
    local helpmsg = {}
    local content = {}
    local paramMap = columnsToParamMap(columns)
    local basepath = options.basepath or ""
    local addpath, indexpath, instanceprefix = content_helper.getPaths(basepath)
    local session = ngx.ctx.session

    if options == nil then
        options = {}
    end
    -- options and their default value
    -- do we allow to edit a table entry?
    local canEdit = options and not (options.canEdit == false) or true
    -- do we allow to add and delete entries
    local canAdd = options and not (options.canAdd == false) or true
    local canDelete = options and not (options.canDelete == false) or true
    -- do we add a named object
    local addNamedObject = options and (options.addNamedObject == true)
    -- do we allow to restart related module after uci is changed
    local canApply = options and not (options.canApply == false)
    -- are we editing an entry and which line (-1 means new entry)
    local editing = options and tonumber(options.editing) or 0
    -- do we disallow delete if under a certain number of entries
    local minEntries = options and tonumber(options.minEntries) or 0
    -- do we disallow adding if above a certain number of entries
    local maxEntries = options and options.maxEntries or huge
    local newList = options and options.newList
    local sorted = options and options.sorted
    local tablesessionkey = options.tableid .. ".stateid"
    local tablesessionindexes = options.tableid .. ".allowedindexes"
    local globalValidation = options.valid
    local sendBackUserData = false
    local success
    local validated

    -- Check if we're in a POST query or in a GET query
    if ngx.var.request_method == "POST" and ngx.var.content_type and match(ngx.var.content_type, "application/x%-www%-form%-urlencoded") then
        content = ngx.req.get_post_args()
        local action = content.action
        local index = tonumber(content.index) or -1
        local sid = options.tableid
        local cid = content.tableid
        local sstateid = session:retrieve(tablesessionkey)
        local cstateid = content.stateid
        allowedIndexes = session:retrieve(tablesessionindexes) or {}

        -- Kept because Voice pages depend on it but this was really not a well though modification...
        if allowedIndexes[index] then
            options.changesessionindex = allowedIndexes[index].paramindex
        end
        -- Check if the POST is for this table or another one in the page
        -- for this compare the id parameter in options and in the POST query
        if(sid ~= nil and sid == cid) then
            -- Check the action POST parameter to know what to do
            -- User wants to delete a line
            if action == "TABLE-DELETE" and canDelete then
                -- Check if changes happened in between
                if checkStateId(sstateid, cstateid) == true then
                    -- User clicked on the DELETE button of a line
                    if index and allowedIndexes[index] then
                        if allowedIndexes[index].canDelete then
                            validated, helpmsg = applyGlobalValidation(basepath, columns, filter, allowedIndexes[index].paramindex, nil, globalValidation, sorted)
                            if validated == true then
                                success = proxy.del(indexpath .. allowedIndexes[index].paramindex .. ".")
                                if type(options.onDelete) == "function" and success then
                                    options.onDelete(allowedIndexes[index].paramindex)
                                end
                                applyOnSuccess(success, canApply, options)
                                session:store(tablesessionkey, generateStateId())
                            end
                        else
                            options.errmsg = changesNotAllowed
                        end
                    else
                        options.errmsg = invalidIndexMsg;
                    end
                else
                    options.errmsg = changesconflictMsg
                end
                -- User wants to edit a line
            elseif action == "TABLE-EDIT" and canEdit then
                -- Check if changes happened in between
                if checkStateId(sstateid, cstateid) == true then
                    -- User clicked on the EDIT button
                    if index and allowedIndexes[index] then
                        if allowedIndexes[index].canEdit then
                            options.editing = index
                        else
                            options.errmsg = changesNotAllowed
                        end
                    else
                        options.errmsg = invalidIndexMsg;
                    end
                else
                    options.errmsg = changesconflictMsg
                end
                -- User wants to apply the changes to a line
            elseif action == "TABLE-MODIFY" and canEdit then
                -- Check if changes happened in between
                if checkStateId(sstateid, cstateid) == true then
                    -- User clicked on the SAVE button after starting a modify "session"
                    if index and allowedIndexes[index] then
                        if allowedIndexes[index].canEdit then
                            validated, helpmsg = getObjectAndValidate(indexpath, allowedIndexes[index].paramindex, content, paramMap, mapValidation)
                            if validated == true then
                                validated, helpmsg = checkUniqueParams(basepath, indexpath .. allowedIndexes[index].paramindex .. ".", columns, content)
                            end
                            if validated == true then
                                validated, helpmsg = applyGlobalValidation(basepath, columns, filter, allowedIndexes[index].paramindex, content, globalValidation, sorted)
                            end
                            if validated == true then
                                success = content_helper.setObject(content, paramMap, indexpath .. allowedIndexes[index].paramindex .. ".", defaultObject)
                                if type(options.onModify) == "function" and success then
                                    options.onModify(allowedIndexes[index].paramindex, content)
                                end
                                applyOnSuccess(success, canApply, options)
                                session:store(tablesessionkey, generateStateId())
                            else
                                -- Stay in editing mode
                                options.editing = index
                                sendBackUserData = true
                            end
                        else
                            options.errmsg = changesNotAllowed
                        end
                    else
                        options.errmsg = invalidIndexMsg;
                    end
                else
                    options.errmsg = changesconflictMsg
                end
                -- User wants to cancel the edition of the line without saving
            elseif action == "TABLE-CANCEL" then
                -- User clicked on the CANCEL button after starting a modify "session"
                options.editing = 0
            elseif action == "TABLE-ADD" and canAdd then
                -- User clicked on the ADD button
                validated, helpmsg = complementObjectAndValidate(content, paramMap, mapValidation)
                if validated == true then
                    validated, helpmsg = checkUniqueParams(basepath, nil, columns, content)
                end
                if validated == true then
                    validated, helpmsg = applyGlobalValidation(basepath, columns, filter, nil, content, globalValidation, sorted)
                end
                if validated == true then
                    if addNamedObject == true then
                        local firstColumnValue = format("%s", content[columns[1].name])
                        --options.objectName given name is the 1st choice
                        --If no such given name, the value of the 1st column should be set as object name
                        local objectName = options.objectName or firstColumnValue
                        success = content_helper.addNewObject(basepath, content, paramMap, defaultObject, objectName)
                    else
                        success = content_helper.addNewObject(basepath, content, paramMap, defaultObject)
                    end
                    if type(options.onAdd) == "function" and success then
                        options.onAdd(success, content)
                    end
                    applyOnSuccess(success, canApply, options)
                    options.editing = 0
                else
                    sendBackUserData = true
                    options.editing = -1
                end
            elseif action == "TABLE-NEW" and canAdd then
                -- User clicked on the Create New button
                options.editing = -1
            elseif action == "TABLE-NEW-LIST" and canAdd then
                -- User clicked on one of the predefined elements in the predefined list
                local listid = tonumber(content.listid)
                options.editing = -1
                -- Set the defaults defined in the newList variable
                if newList ~= nil and listid ~= nil and listid then
                    if newList[listid] ~= nil then
                        local values = newList[listid].values
                        for _,v in ipairs(columns) do
                            v.default = values[v.name] or v.default or ""
                        end
                    end
                end
            end
        end
    end

    -- retrieve the current state id so that it can be included in the table
    options.stateid = session:retrieve(tablesessionkey) or ""
    -- retrieve the data to load in the table
    data, allowedIndexes = content_helper.loadTableData(basepath, columns, filter, sorted)
    -- store the allowed indexes in the session datastore and verify that changes are allowed
    session:store(tablesessionindexes, allowedIndexes)

    -- if the user entered invalid values, we must send them back in the form so that he can modify
    -- them but at the same time does not lose the other changes he made
    if sendBackUserData == true then
        if options.editing == -1 then
            -- we need to put the input in the add line at the bottom, we'll use the default values for that
            for _,v in ipairs(columns) do
                v.default = content[v.name] or v.default or ""
            end
        else
            -- we need to modify the loaded data and replace the loaded elements with the ones that were sent by the user
            local userData = {}
            for _,v in ipairs(columns) do
                -- for r/o fields, we need to take the actual data
                userData[#userData + 1] = content[v.name] or data[options.editing][#userData + 1] or ""
            end
            data[options.editing] = userData
        end
    end

    return data, helpmsg
end

local function alwaysTrue()
    return true
end

local function alwaysFalse()
    return false, "" -- this is used in the context of a validation function and false means there is an help message
end

---
-- @function [parent=#post_helper] validateNonEmptyString
-- @param value
-- @return #boolean, #string
function M.validateNonEmptyString(value)
    if type(value) ~= "string" and not istainted(value) then
        return nil, T"Received a non string value"
    end
    if #value == 0 then
        return nil, T"String cannot be empty"
    end
    return true
end

--- Returns the type of IP address the string is
-- Based on http://stackoverflow.com/a/16643628
-- TODO: Ideally we use a binding to inet_pton(3)...
-- @param #string ip the string representing the ip address
-- @return #number 0 = error
--                 4 = ipv4
--                 6 = ipv6
local ipv6_pattern = ("([a-fA-F0-9]*):"):rep(8):gsub(":$","")
local function GetIPType(ip)
    -- must pass in a string value
    if type(ip) ~= "string" and not istainted(ip) then
        return 0
    end

    -- check for format 1.11.111.111 for ipv4
    local chunks = { ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    if #chunks == 4 then
        for _,v in pairs(chunks) do
            local octet = tonumber(v)
            if octet < 0 or octet > 255 then
                return 0
            end
        end
        return 4
    end

    -- check for ipv6 format, should be 8 'chunks' of numbers/letters
    local chunks = { ip:match(ipv6_pattern) }
    if #chunks == 8 then
        for _,v in pairs(chunks) do
            local chunk = tonumber(v, 16)
            if #v > 0 and (chunk < 0 or chunk > 65535) then
                return 0
            end
        end
        return 6
    end

    return 0
end

---
-- @function [parent=#post_helper] validateStringIsIP
-- @param value
-- @return #boolean, #string
function M.validateStringIsIP(value)
    local iptype = GetIPType(value)
    if iptype == 4 or iptype == 6 then
        return true
    end
    return nil, T"Invalid IP address"
end


---
-- @function [parent=#post_helper] validateStringIsMAC
-- @param value
-- @return #boolean, #string
local mac_pattern = "^" .. ("([a-fA-F0-9][a-fA-F0-9]):"):rep(6):gsub(":$","")
function M.validateStringIsMAC(value)
    if not value then
        return nil, T"Invalid input"
    end
    local chunks = { value:match(mac_pattern) }
    if #chunks == 6 then
        return true
    else
        return nil, T"Invalid MAC address, it must be of the form 00:11:22:33:44:55"
    end
end

---
-- Check whether the received 'value' has the syntax of a domain name [RFC 1034]
-- @function [parent=#post_helper] validateStringIsDomainName
-- @param value
-- @return #boolean, #string
function M.validateStringIsDomainName(value)

    if type(value) ~= "string" and not istainted(value) then
        return nil, T"Received a non string value"
    end
    if string.len(value) == 0 then
        return nil, T"Domain name cannot be empty"
    end

    if string.len(value) > 255 then
        return nil, T"Received domain name is too long"
    end

    local i=0
    local j=0

    repeat
        i = i+1
        j = string.find(value, ".", i, true)
        local label = string.sub(value, i, j)
        local strippedLabel = string.match(label, "[^%.]*")
        if strippedLabel ~= nil then
            if string.len(strippedLabel) == 0 then
                return nil, T"Empty label not allowed"
            end
            if string.len(strippedLabel) > 63 then
                return nil, T"Domain name contains a label that is longer than 63 characters"
            end
            -- For debugging check /var/log/nginx/error.log on the target
            -- io.stderr:write(string.format("strippedLabel = %s\n", strippedLabel))
            local correctLabel = string.match(strippedLabel, "[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9]")

            if string.len(strippedLabel) == 1 then
                if not string.match(strippedLabel, "[a-zA-Z]") then
                    return nil, T"Label within domain name has invalid syntax"

                end
            elseif strippedLabel ~= correctLabel then
                -- For debugging check /var/log/nginx/error.log on the target
                -- io.stderr:write(string.format("correctLabel = %s\n", correctLabel))
                return nil, T"Label within domain name has invalid syntax"
            end
        end

        i = j
    until not j

    return true

end

---
-- @function [parent=#post_helper] validateBoolean
-- @param value
-- @return #boolean, #string
function M.validateBoolean(value)
    value = tonumber(value)
    if value == 1 or value == 0 then
        return true
    end
    return nil, T"0 or 1 expected"
end

---
-- @function [parent=#post_helper] validateStringIsPort
-- @param value
-- @return #boolean, #string
function M.validateStringIsPort(value)
    local port = tonumber(value)
    if port and port >= 0 and port < 65536 then
        return true
    end
    return nil, T"Port is invalid. It should be between 0 and 65535"
end

---
-- @function [parent=#post_helper] validateStringIsPortRange
-- @param value
-- @return #boolean, #string
local portrange_pattern = "^(%d+)%-(%d+)$"
function M.validateStringIsPortRange(value)
    if not value then
        return nil, T"Invalid port range"
    end
    local chunks = { value:match(portrange_pattern) }
    if #chunks == 2 then
        local p1 = tonumber(chunks[1])
        local p2 = tonumber(chunks[2])
        if M.validateStringIsPort(chunks[1]) and M.validateStringIsPort(chunks[2]) and p1 <= p2 then
            return true
        else
            return nil, T"Port range is invalid, it must be of format port1-port2 with port1 <= port2"
        end
    else
        return M.validateStringIsPort(value)
    end
end

---
-- @function [parent=#post_helper] validatePositiveNum
-- @param value
-- -- @return #boolean, #string
function M.validatePositiveNum(value)
    local num = tonumber(value)
    if (num and num >= 0) then
        return true
    end
    return nil, T"Positive number expected"
end

---
-- Return a function that can be used to validate if the input is a number between min and max (inclusive)
-- If min is nil or max is nil, it won't check for it
-- @function [parent=#post_helper] getValidateNumberInRange
-- @param #number min
-- @param #number max
-- @return #boolean, #string
function M.getValidateNumberInRange(min, max)
    local helptext = T"Input must be a number"
    if min and max then
        helptext = string.format(T"Input must be a number between %d and %d included", min, max)
    elseif not min and not max then
        helptext = T"Input must be a number"
    elseif not min then
        helptext = string.format(T"Input must be a number smaller than %d included", max)
    elseif not max then
        helptext = string.format(T"Input must be a number greater than %d included", min)
    end

    return function(value)
        local num = tonumber(value)
        if not num then
            return nil, helptext
        end
        if min and num < min then
            return nil, helptext
        end
        if max and num > max then
            return nil, helptext
        end
        return true
    end
end

---
-- @function [parent=#post_helper] validateRegExpire
-- @param value
-- @param min
-- @param max
-- --@return #boolean, #string
function M.validateRegExpire (value)
    local num = tonumber (value)
    if (num >= 60 and num <= 86400) then
        return true
    end
    return nil, T"Expire Time is invalid. It should be between 60 and 86400"
end

---
-- Return a function that can be used to validate if the given value/array is part of the choices
-- It also does some processing on the data to normalize it for use.
-- If only one checkbox is selected, then we don't get an array -> make an array of one element
-- @function [parent=#post_helper] getValidateInCheckboxgroup
-- @param #table enum array of entries of a select input
-- @return #boolean, #string
function M.getValidateInCheckboxgroup(enum)
    local choices = setmetatable({}, untaint_mt)

    -- store that as a dictionnary, will make it simpler
    for _,v in ipairs(enum) do
        choices[v[1]] = true
    end

    return function(value, object, key)
        local uv
        local canary
        local canaryvalue = ""

        if not value then
            return nil, T"Invalid input"
        end

        if type(value) == "table" then
            uv = value
        else
            uv = { value }
        end
        object[key] = uv
        for i,v in ipairs(uv) do
            if v == canaryvalue then
                canary = i
            elseif not choices[v] then
               return nil, T"Invalid value"
            end
        end
        if canary then
            remove(uv, canary)
        end
        return true
    end
end

---
-- Return a function that can be used to validate if the checkbox for switch is checked or not,
-- If the checkbox is checked, then the corresponding value in the post array is set "1", otherwise "0"
-- @function [parent=#post_helper] getValidateInCheckboxgroup
-- @return #boolean, #string
function M.getValidateCheckboxSwitch()
    --return true or nil
    return function(value, object, key)
        if not value then
            return nil, T"Invalid input"
        end

        if type(value) == "table" then
          for k,v in pairs(value) do
            if (v ~= "_DUMMY_" and  v ~= "_TRUE_") then
              return nil, T"Invalid value"
            end
          end
          object[key] = "1"
          return true
        else
          if (value == "_DUMMY_") then
            object[key] = "0"
            return true
          else
            return nil, T"Invalid value"
          end
        end
    end
end

---
-- Return a function that can be used to validate if the given value is part of the choices
-- @function [parent=#post_helper] getValidateInEnumSelect
-- @param #table enum array of entries of a select input
-- @return #boolean, #string
function M.getValidateInEnumSelect(enum)
    local choices = setmetatable({}, untaint_mt)

    -- store that as a dictionnary, will make it simpler
    for _,v in ipairs(enum) do
        choices[v[1]] = true
    end

    return function(value)
        return choices[value], T"Invalid value"
    end
end

---
-- Return a function that can be used to validate if a string's length is greater or equal to length
-- @function [parent=#post_helper] getValidateStringLength
-- @param #number length minimum length of the string
-- @return #boolean, #string
function M.getValidateStringLength(length)
    return function(value)
        if type(value) ~= "string" and not istainted(value) then
            return nil, T"Received a non string value"
        end
        if #value < length then
            return nil, format(T"String must be at least %d characters long", length)
        end
        return true
    end
end

---
-- Return a function that can be used to validate if the string length is between l1 and l2 (included)
-- @function [parent=#post_helper] getValidateStringLengthInRange
-- @param #number minl minimum length of the string
-- @param #number maxl maximum length of the string
-- @return #boolean, #string
function M.getValidateStringLengthInRange(minl, maxl)
    return function(value)
        if type(value) ~= "string" and not istainted(value) then
            return nil, T"Received a non string value"
        end
        if #value < minl or #value > maxl then
            return nil, format(T"String must be between %d and %d characters long", minl, maxl)
        end
        return true
    end
end

---
-- Return a validation function that will be enabled only if a given property is present and otherwise return true
-- @function [parent=#post_helper] getValidationIfPropInList
-- @param validation function (prototype is of type (value, object)
-- @param #string prop name of the property used as a trigger
-- @param #table values array of values that should trigger the behavior
-- @return validation function
function M.getValidationIfPropInList(func, prop, values)
    local options = setmetatable({}, untaint_mt)

    -- store that as a dictionnary, will make it simpler
    for _,v in ipairs(values) do
        options[v] = true
    end

    -- This function should apply the given validation function if the property is in the allowed values and return true otherwise
    return function(value, object, key)
        if object and object[prop] and options[object[prop]] then
            return func(value, object, key)
        end
        return true
    end
end

---
-- Return a validation function that will be enabled only if a given checkboxswitch property is present and otherwise return true
-- @function [parent=#post_helper] getValidationIfPropInList
-- @param validation function (prototype is of type (value, object)
-- @param #string prop name of the property used as a trigger
-- @param #table values array of values that should trigger the behavior
-- @return validation function
function M.getValidationIfCheckboxSwitchPropInList(func, prop, values)
    local options = setmetatable({}, untaint_mt)

    -- store that as a dictionnary, will make it simpler
    for _,v in ipairs(values) do
        options[v] = true
    end

    -- This function should apply the given validation function if the property is in the allowed values and return true otherwise
    return function(value, object, key)
        if object and object[prop] then
            -- Before M.getValidateCheckboxSwitch is called,
            -- the post value of a switchcheck box is still {"_DUMMY_", "_TRUE_"} or "_DUMMY_"
            -- these values need to be converted to "1" or "0"
            local property = object[prop]
            if type(property) == "table" then
                for k,v in pairs(property) do
                    if (v ~= "_DUMMY_" and  v ~= "_TRUE_")  then
                        return nil, T"Invalid value"
                    end
                end
                property = "1"
            elseif (property == "_DUMMY_") then
                property = "0"
            end
            if options[property] then
                return func(value, object, key)
            end
        end
        return true
    end
end

---
-- @function [parent=#post_helper] validateStringIsLeaseTime
-- @param value
-- @return #boolean, #string
function M.validateStringIsLeaseTime(value)
    if not value then
        return nil, T"Invalid value"
    end
    local str_units = value:sub(#value)
    local number = tonumber(value:sub(0 , #value-1))
    if number and number > 0 and number <= 60 then
        if str_units == "h" or str_units == "m" then
            return true
        end
        return nil, T"Invalid time units, use m for minutes or h for hours."
    end
    return nil, T"Lease time is invalid. It must be between 0 and 60."
end

---
-- The object of this function is to not modify the password when we receive the predefined
-- dummy value ********. If we do, we remove it from the post data so that this parameter
-- won't be written to transformer. You can pass an additional validation function that will
-- be called on a "modified" value to add for instance password strength check
-- @function [parent=#post_helper] getValidationPassword
-- @param #function additionalvalid
-- @return #function
function M.getValidationPassword(additionalvalid)
    return function(value, object, key)
        -- Check if this is the "dummy" value. If it is, we must remove it,
        -- we don't want to store it
        -- TODO: find a better dummy value
        -- TODO: define better
        -- TODO: make a version that checks the password strength as well
        if value == "********" then
            object[key] = nil
            return true
        end
        if type(additionalvalid) == "function" then
            return additionalvalid(value, object, key)
        end
        return true
    end
end

---
-- This function will allow to only apply validation if the value is non empty / nil
-- This is useful in the case of an optional parameter that has to nonetheless follow
-- a certain format
-- @function [parent=#post_helper] getOptionalValidation
-- @param #function additionalvalid
-- @return #function
function M.getOptionalValidation(additionalvalid)
    local av = additionalvalid
    if type(av) ~= "function" then
        av = alwaysTrue
    end

    return function(value, object, key)
        if not value or value == "" then
            return true
        end
        return av(value, object, key)
    end
end

---
-- This function will apply different validation function based on the outcome of the condition function
-- Helpful when needing to apply different validations / operations based on other elements
-- @function [parent=#post_helper] getConditionalValidation
-- @param #function condition the test function to decide which validation function to apply (uses the same prototype as validation function)
-- @param #function istrue validation function to apply if condition returns true (uses always true if not a function)
-- @param #function isfalse validation function to apply if condition returns false (uses always true if not a function)
-- @return #function
function M.getConditionalValidation(condition, istrue, isfalse)
    local t, f = istrue, isfalse
    if type(t) ~= "function" then
        t = alwaysTrue
    end
    if type(f) ~= "function" then
        f = alwaysTrue
    end

    return function(value, object, key)
        if type(condition) == "function" then
            if condition(value, object, key) then
                return t(value, object, key)
            else
                return f(value, object, key)
            end
        end
        return true
    end
end

---
-- This function uses 2 validation functions and will only return true
-- if both return true.
-- @function [parent=#post_helper] getAndValidation
-- @param #function valid1
-- @param #function valid2
-- @return #boolean, #string
function M.getAndValidation(valid1, valid2)
    local v1,v2 = valid1,valid2
    if type(v1) ~= "function" then
        v1 = alwaysTrue
    end
    if type(v2) ~= "function" then
        v2 = alwaysTrue
    end

    return function(value, object, key)
        local r1,h1 = v1(value, object, key)
        local r2,h2 = v2(value, object, key)
        local help = {}
        if not r1 then
            help[#help+1] = h1 or ""
        end
        if not r2 then
            help[#help+1] = h2 or ""
        end

        return r1 and r2, concat(help, " ")
    end
end

---
-- This function uses 2 validation functions and will only return true
-- if one of them returns true.
-- @function [parent=#post_helper] getAndValidation
-- @param #function valid1
-- @param #function valid2
-- @return #boolean, #string
function M.getOrValidation(valid1, valid2)
    local v1,v2 = valid1,valid2
    if type(v1) ~= "function" then
        v1 = alwaysTrue
    end
    if type(v2) ~= "function" then
        v2 = alwaysTrue
    end

    return function(value, object, key)
        local r1,h1 = v1(value, object, key)
        local r2,h2 = v2(value, object, key)
        local help = {}
        if not r1 and not r2 then
            help[#help+1] = h1 or ""
            help[#help+1] = h2 or ""
        end
        return r1 or r2, concat(help, " ")
    end
end


local psklength = M.getValidateStringLengthInRange(8,63)
local pskmatch = "^[ -~]+$"
--- This function validates a WPA/WPA2 PSK key
-- It must be between 8 and 63 characters long and those characters must be ASCII printable (32-126)
-- @param #string psk the PSK key to validate
-- @return #boolean, #string
function M.validatePSK(psk)
    local err, msg = psklength(psk)
    if not err then
        return err, msg
    end

    if not string.match(psk, pskmatch) then
        return nil, T"The wireless key contains invalid characters, only space, letters, numbers and the following characters !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ are allowed"
    end

    return true
end

--- Following the Wifi certificationw we need to check if the pin with 8 digits the last digit is the
-- the checksum of the others
-- @param #number the PIN code value
local function validatePin8(pin)
    if pin then
        local accum = 0
        accum = accum + 3*(floor(pin/10000000)%10)
        accum = accum + (floor(pin/1000000)%10)
        accum = accum + 3*(floor(pin/100000)%10)
        accum = accum + (floor(pin/10000)%10)
        accum = accum + 3*(floor(pin/1000)%10)
        accum = accum + (floor(pin/100)%10)
        accum = accum + 3*(floor(pin/10)%10)
        accum = accum + (pin%10)
        if 0 == (accum % 10) then
            return true
        end
    end
    return nil, T"Invalid Pin"
end

--- valide WPS pin code. Must be 4-8 digits (can have a space or - in the middle)
-- @param #string value the PIN code that was entered
function M.validateWPSPIN(value)
    local errmsg = T"PIN code must composed of 4 or 8 digits with potentially a dash or space in the middle"
    if value == nil or #value == 0 then
        -- empty pin code just means that we don't want to set one
        return true
    end

    local pin4 = value:match("^(%d%d%d%d)$")
    local pin8_1, pin8_2 = value:match("^(%d%d%d%d)[%-%s]?(%d%d%d%d)$")

    if pin4 then
        return true
    end
    if pin8_1 and pin8_2 then
        local pin8 = tonumber(pin8_1..pin8_2)
        return validatePin8(pin8)
    end
    return nil, errmsg
end

-- end of code related to WPS pin validation

--- check for WEP keys
-- @param #string value the WEP key
-- @return #boolean, #string
function M.validateWEP(value)
    if value == nil or (#value ~= 10 and #value ~=26) then
        return nil, T"Invalid length, a WEP key must be 10 or 26 characters long"
    end

    if not value:match("^[A-F%d]+$") then
        return nil, T"A WEP key can only contain the letters A to F or digits"
    end
    return true
end

-- Return number representing the IP address / netmask (first byte is first part ...)
local ipmatch = "(%d+)%.(%d+)%.(%d+)%.(%d+)"
local function ipv42num(ipstr)
    local result = 0
    local ipblocks = { string.match(ipstr, ipmatch) }
    if #ipblocks < 4 then
        return nil
    end

    for _,v in ipairs(ipblocks) do
        result = bit.lshift(result, 8) + v
    end
    return result
end

--- This function returns a validator that will check that the provided value is an IPv4 in the same network
-- as the network based on the GW IP + Netmask
-- @param #string gw the gateway IP@ on the considered network
-- @param #string nm the netmask to use
-- @return true or nil+error message
function M.getValidateStringIsIPv4InNetwork(gw, nm)
    local gwip = ipv42num(gw)
    local netmask = ipv42num(nm)
    local network = bit.band(gwip, netmask)
    local broadcast = bit.bor(network, bit.bnot(netmask))

    return function(value)
        if(GetIPType(value) ~= 4) then
            return nil, T"String is not an IPv4 address"
        end
        local ip = ipv42num(value)

        if network ~= bit.band(ip, netmask) then
            return nil, string.format(T"IP is not in the same network as the gateway %s", gw)
        end
        return true
    end
end

--- This function returns a validator that will check that the provided value is an IPv4 in the same network
-- as the network based on the GW IP + Netmask except the GW and forbidden IPs (broadcast & network identifier)
-- @param #string gw the gateway IP@ on the considered network
-- @param #string nm the netmask to use
-- @return true or nil+error message
function M.getValidateStringIsDeviceIPv4(gw, nm)
    local gwip = ipv42num(gw)
    local netmask = ipv42num(nm)
    local network = bit.band(gwip, netmask)
    local broadcast = bit.bor(network, bit.bnot(netmask))
    local mainValid = M.getValidateStringIsIPv4InNetwork(gw, nm)

    return function(value)
        local err, msg = mainValid(value)
        if err == nil then
            return err, msg
        end
        local ip = ipv42num(value)
        if gwip == ip then
            return nil, T"Cannot use the GW IP"
        end
        if broadcast == ip then
            return nil, T"Cannot use the broadcast address"
        end
        if network == ip then
            return nil, T"Cannot use the network address"
        end
        return true
    end
end

local function checkBlockValue(str)
    local val = tonumber(str, 16)
    if val and val <= 0xFFFF then
        return true
    else
        return false
    end
end

--- This function returns a validator that will check that the provided value is an IPv6 address
--
-- @param #string value the IPv6 Address
-- @return true or nil+error message
function M.validateStringIsIPv6(value)
    local compressed=false
    local counter, borderl, borderh= 0,1
    local len = #value

    if not value or value == "" then
        return nil, T"Null string."
    end
    --The address start with "::"
    if sub(value,1,2) == "::" then
        borderl = 3
        compressed = true
    end

    --check all the address group, and save the address group numbers
    while true do 
        --find "::", we assume it's compressed address 
        if sub(value,borderl, borderl) == ":" then
            if compressed == true then
                return nil, T"Invalid IPv6 Address, two or more '::'."
            end
            compressed = true
            borderl = borderl + 1
            if borderl > len then
                return nil, T"Invalid IPv6 Address, end with '::'."
            end
        end

        borderh = find(value, ":", borderl, true)
        if borderh == borderl then
            return nil, T"Invalid IPv6 Address, ':::' was found."
        end

        --last address group 
        if not borderh then 
            if checkBlockValue(sub(value, borderl, len))==false then
                return nil, T"Invalid IPv6 Address, group value is too large."
            end
            counter = counter+1
        break end

        if checkBlockValue(sub(value, borderl, borderh-1))==false then
            return nil, T"Invalid IPv6 Address, group value is too large"
        end
        counter = counter+1

        if borderh+1 > len then
            return nil, T"Invalid IPv6 Address, end with ':'."
        else
           borderl = borderh + 1
        end
    end

    if counter == 8 and compressed == false then
        return true
    elseif counter < 8 and compressed == true then
        return true
    else
        return nil, T"Invalid IPv6 Address, address group is invalid."
    end
end

return M
