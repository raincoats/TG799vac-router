<%
-- Enable localization
gettext.textdomain('webui-core')

local content_helper = require("web.content_helper")
local ui_helper = require("web.ui_helper")
local message_helper = require("web.uimessage_helper")

-- Process POST query
local post_helper = require("web.post_helper")

%>

<fieldset>
<%
ngx.print(ui_helper.createMessages(message_helper.popMessages()))
%>
<legend><%= T"Bridged connection" %></legend>

<%
    local html = {}
    local bridge_info = {
        alert = {
            class = "alert-info"
        }
    }

    html[#html + 1] = ui_helper.createAlertBlock(T"No configuration available for internet connectivity when in bridge mode.", bridge_info)

    ngx.print(html)
%>

</fieldset>