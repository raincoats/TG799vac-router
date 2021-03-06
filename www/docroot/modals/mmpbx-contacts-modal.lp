<%
-- Localization
gettext.textdomain('webui-voice')

local content_helper = require("web.content_helper")
local ui_helper = require("web.ui_helper")
local message_helper = require("web.uimessage_helper")
local post_helper = require("web.post_helper")
local table, ipairs = table, ipairs

-- Shortcuts to validation helpers to make lines shorter
local vNES = post_helper.validateNonEmptyString

-- In Transformer
-- rpc.mmbpx.phonebook_entry.@.FirstName
-- rpc.mmbpx.phonebook_entry.@.LastName
-- rpc.mmbpx.phonebook_entry.@.HomeNumber
-- rpc.mmbpx.phonebook_entry.@.WorkNumber
-- rpc.mmbpx.phonebook_entry.@.MobileNumber

-- Phonebook contacts
local contact_columns = {
  {
    header = T"First Name",
    name = "FirstName",
    param = "FirstName",
    type = "text",
    attr = { input = { class="span2" } },
  },
  {
    header = T"Last Name",
    name = "LastName",
    param = "LastName",
    type = "text",
    attr = { input = { class="span2" } },
  },
  {
    header = T"Home Number",
    name = "HomeNumber",
    param = "HomeNumber",
    type = "text",
    attr = { input = { class="span2" } },
  },
  {
    header = T"Mobile Number",
    name = "MobileNumber",
    param = "MobileNumber",
    type = "text",
    attr = { input = { class="span2" } },
  },
  {
    header = T"Office Number",
    name = "WorkNumber",
    param = "WorkNumber",
    type = "text",
    attr = { input = { class="span2" } },
  },
}

local maxnamelength = 40   -- the max length of FirstName, LastName
local function validate_phonenumber(value)
  if value == "" or value:match("^([%+%d]?[%d%s%-]+)$") then
    return true
  end
  return nil, "Invalid phone number"
end

local function validate_phonename(value)
  if vNES(value) and string.len(value) <= maxnamelength then
      return true
  end
  return nil, "FirstName and LastName can not be empty,  and must be less than " .. maxnamelength .. " characters"
end

local contact_valid = {
  -- To do: currently, mmpbxphone can't set the fields to empty
  -- so we have to make sure the fields are not empty otherwise it will be a bug
  FirstName = validate_phonename,
  LastName = validate_phonename,
  HomeNumber = validate_phonenumber,
  WorkNumber = validate_phonenumber,
  MobileNumber = validate_phonenumber,
}

local contact_options = {
  tableid = "phonebook_entry",
  basepath = "rpc.mmpbx.phonebook_entry.@.",
  createMsg = T"Add new contact",
  maxEntries = 1000,
  sorted = "FirstName",
}

local contact_data, contact_helpmsg = post_helper.handleTableQuery(contact_columns, contact_options, nil, nil, contact_valid)

local uri = ngx.var.uri
if ngx.var.args and string.len(ngx.var.args) > 0 then
  uri = uri .. "?" .. ngx.var.args
end
%>

<%= ui_helper.createHeader(T"Telephony", false, true) %>

<div class="modal-body update">
  <%
  local lp = require("web.lp")
  lp.setpath("/www/snippets/")
  lp.include("tabs-voice.lp")
  %>
  <form class="form-horizontal" method="post" action="<%= uri %>">
    <%=ui_helper.createMessages(message_helper.popMessages())%>
    <fieldset>
      <legend><%= T"Contacts" %></legend>
      <%=ui_helper.createTable(contact_columns, contact_data, contact_options, nil, contact_helpmsg)%>
    </fieldset>
  </form>
</div>

<%= ui_helper.createFooter() %>
