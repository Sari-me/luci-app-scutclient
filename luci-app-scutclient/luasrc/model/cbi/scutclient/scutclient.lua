-- LuCI configuration page for scutclient (multi-instance)

local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local ntm = require "luci.model.network".init()

local function split_time(value)
	-- H:MM / HH:MM
	local hour, minute = value:match("^(%d%d?):(%d%d)$")

	if not hour or not minute then
		return nil, nil
	end

	return tonumber(hour), tonumber(minute)
end


local scut = Map(
	"scutclient",
	translate("SCUT Client Settings"),
	translate(
		"Manage multiple authentication instances. Every instance binds one WAN "
		.. "and runs its own process and log. Save the settings before "
		.. "restarting the service."
	)
)


-- Real-time WAN lock (front-end UX only; the init script re-checks
-- logical + netdev exclusivity on start)

local lock = scut:section(SimpleSection)
lock.template = "scutclient/interface_lock"


-- General settings

local options = scut:section(
	TypedSection,
	"option",
	translate("General Settings")
)

options.anonymous = true
options.addremove = false


local enable = options:option(
	Flag,
	"enable",
	translate("Enable")
)

enable.rmempty = false
enable.default = "0"
enable.description = translate(
	"Master switch of the scutclient service. Disabled instances never start."
)


-- Authentication instances

local instances = scut:section(
	TypedSection,
	"scutclient",
	translate("Authentication Instances"),
	translate(
		"The section name is the instance id used by the service, the status "
		.. "page and the log file. One WAN can only be bound by one instance."
	)
)

instances.anonymous = false
instances.addremove = true


instances:tab("basic", translate("Basic Settings"))
instances:tab("drcom", translate("802.1X / Dr.COM"))
instances:tab("portal", translate("Web Portal"))
instances:tab("advanced", translate("Advanced Settings"))
instances:tab("logging", translate("Logging"))


-- Basic

local inst_enabled = instances:taboption(
	"basic",
	Flag,
	"enabled",
	translate("Enabled")
)

inst_enabled.rmempty = false
inst_enabled.default = "1"


local inst_name = instances:taboption(
	"basic",
	Value,
	"name",
	translate("Display name")
)

inst_name.rmempty = true
inst_name.placeholder = "Wired WAN"


local auth_method = instances:taboption(
	"basic",
	ListValue,
	"auth_method",
	translate("Authentication method")
)

auth_method.rmempty = false
auth_method.default = "dot1x"

auth_method:value(
	"dot1x",
	translate("802.1X + Dr.COM")
)

auth_method:value(
	"portal",
	translate("Web Portal / Wireless authentication")
)

auth_method.description = translate(
	"802.1X uses EAPOL and the Dr.COM UDP protocol. Web Portal detects "
	.. "the captive portal Location on the selected WAN and logs in "
	.. "through it."
)


local username = instances:taboption(
	"basic",
	Value,
	"username",
	translate("Username")
)

username.rmempty = false
username.description = translate(
	"Usually your student number or the username issued by the university."
)


local password = instances:taboption(
	"basic",
	Value,
	"password",
	translate("Password")
)

password.password = true
password.rmempty = false


-- OpenWrt logical network interface

local interface = instances:taboption(
	"basic",
	ListValue,
	"interface",
	translate("Authentication interface")
)

interface.rmempty = false

-- 新实例必须显式选择 WAN，不再默认占用 wan
interface:value("", translate("-- Select WAN interface --"))

local found_wan = false

uci:foreach("network", "interface", function(section)
	local name = section[".name"]

	if name and name ~= "" and name ~= "loopback" then
		local title = name
		local net = ntm:get_network(name)

		if net then
			local dev = net:get_interface()
			local device = dev and dev:name()
			local ipaddr = net:ipaddr()

			if device and ipaddr then
				title = name .. " (" .. device .. ", " .. ipaddr .. ")"
			elseif device then
				title = name .. " (" .. device .. ")"
			end
		end

		interface:value(name, title)

		if name == "wan" then
			found_wan = true
		end
	end
end)

if not found_wan then
	interface:value("wan", "wan")
end

interface.description = translate(
	"Logical OpenWrt network interface used for authentication. "
	.. "The service resolves it to the actual network device automatically. "
	.. "Each interface can only be bound by one instance."
)

-- WAN 独占校验必须比较"本次表单准备提交的值"，而不是已 commit 的旧 UCI，
-- 否则同一页面上另一实例刚改完的接口会被旧值误判为冲突。
interface.validate = function(self, value, section)
	if value == nil or value == "" then
		return nil, translate("Please select an interface.")
	end

	for _, sid in ipairs(instances:cfgsections()) do
		if sid ~= section then
			local other = self:formvalue(sid)

			if other == nil then
				other = self:cfgvalue(sid)
			end

			if other ~= nil and other ~= "" and other == value then
				return nil, translatef(
					"Interface '%s' is already selected by instance '%s'. "
					.. "One WAN can only be bound by one instance.",
					value,
					sid
				)
			end
		end
	end

	return value
end


-- Web Portal Location（仅 portal 模式显示）

local portal_location = instances:taboption(
	"basic",
	Value,
	"portal_location",
	translate("Location")
)

portal_location.rmempty = true
portal_location:depends("auth_method", "portal")

portal_location.description = translate(
	"Captive portal redirect URL. Select an authentication interface "
	.. "and use the test button to detect it automatically, or enter it "
	.. "manually. Re-test after the WAN or MAC configuration changes."
)

portal_location.validate = function(self, value)
	if value == nil or value == "" then
		return value
	end

	if #value > 4096 then
		return nil, translate("Location is too long.")
	end

	if not value:match("^https?://") then
		return nil, translate(
			"Location must start with http:// or https://."
		)
	end

	return value
end


local portal_probe = instances:taboption(
	"basic",
	DummyValue,
	"_portal_probe"
)

portal_probe.rmempty = true
portal_probe:depends("auth_method", "portal")
portal_probe.template = "scutclient/portal_location_probe"


-- MAC management

local mac_mode = instances:taboption(
	"basic",
	ListValue,
	"mac_mode",
	translate("MAC mode")
)

mac_mode.rmempty = false
mac_mode.default = "keep"

mac_mode:value("keep", translate("Keep the current interface MAC"))
mac_mode:value("random", translate("Random MAC"))
mac_mode:value("custom", translate("Custom MAC"))

mac_mode.description = translate(
	"Random MACs are generated once and stored with the instance."
)


local macaddr = instances:taboption(
	"basic",
	Value,
	"macaddr",
	translate("MAC address")
)

macaddr.rmempty = true
macaddr.datatype = "macaddr"
macaddr.description = translate(
	"Target MAC for random/custom mode. Leave empty in random mode to "
	.. "generate one automatically on the first start."
)


local macgen = instances:taboption(
	"basic",
	DummyValue,
	"_macgen"
)

macgen.rmempty = true
macgen.template = "scutclient/mac_generator"


-- Dr.COM

local server = instances:taboption(
	"drcom",
	Value,
	"server_auth_ip",
	translate("Authentication server")
)

server.rmempty = true

server:depends("auth_method", "dot1x")
server.datatype = "ip4addr"
server.default = "202.38.210.131"


local dns = instances:taboption(
	"drcom",
	Value,
	"dns",
	translate("DNS server")
)

dns.rmempty = true

dns:depends("auth_method", "dot1x")
dns.datatype = "ip4addr"
dns.default = "222.201.130.30"


local version = instances:taboption(
	"drcom",
	ListValue,
	"version",
	translate("Dr.com version")
)

version.rmempty = true

version:depends("auth_method", "dot1x")

version:value(
	"4472434f4d0096022a",
	"4472434f4d0096022a"
)

version:value(
	"4472434f4d0096022a00636b2031",
	"4472434f4d0096022a00636b2031"
)

version:value(
	"4472434f4d00cf072a00332e31332e302d32342d67656e65726963",
	"4472434f4d00cf072a00332e31332e302d32342d67656e65726963"
)

version.default = "4472434f4d0096022a"


local hash = instances:taboption(
	"drcom",
	ListValue,
	"hash",
	translate("DrAuthSvr.dll hash")
)

hash.rmempty = true

hash:depends("auth_method", "dot1x")

hash:value(
	"2ec15ad258aee9604b18f2f8114da38db16efd00",
	"2ec15ad258aee9604b18f2f8114da38db16efd00"
)

hash:value(
	"d985f3d51656a15837e00fab41d3013ecfb6313f",
	"d985f3d51656a15837e00fab41d3013ecfb6313f"
)

hash:value(
	"915e3d0281c3a0bdec36d7f9c15e7a16b59c12b8",
	"915e3d0281c3a0bdec36d7f9c15e7a16b59c12b8"
)

hash.default = "2ec15ad258aee9604b18f2f8114da38db16efd00"


-- Allowed online time

local nettime = instances:taboption(
	"drcom",
	Value,
	"nettime",
	translate("Allowed online time")
)

nettime.description = translate(
	"Duration accepted by scutclient, for example 6:15. "
	.. "Leave empty to use the daemon default."
)

nettime.rmempty = true

nettime:depends("auth_method", "dot1x")

nettime.validate = function(self, value)
	if value == nil or value == "" then
		return value
	end

	local hour, minute = split_time(value)

	if hour
		and minute
		and hour < 12
		and minute < 60
	then
		return value
	end

	return nil, translate(
		"Invalid time format. Use H:MM or HH:MM, for example 6:15."
	)
end


-- Hostname

local hostname = instances:taboption(
	"drcom",
	Value,
	"hostname",
	translate("Hostname sent to server")
)

hostname.rmempty = true

hostname:depends("auth_method", "dot1x")
hostname.default = "Lenovo-PC"


-- Give a DHCP client hostname as an optional suggestion.
-- Do NOT use it as a dynamic default.

local lease_hostname = sys.exec(
	"awk 'NF >= 4 && $4 != \"*\" { print $4; exit }' "
	.. "/tmp/dhcp.leases 2>/dev/null"
)

lease_hostname = (lease_hostname or ""):gsub("[\r\n]+$", "")

if lease_hostname ~= "" then
	hostname:value(
		lease_hostname,
		lease_hostname
	)
end


-- Advanced

local route_isolation = instances:taboption(
	"advanced",
	ListValue,
	"route_isolation",
	translate("Routing isolation")
)

route_isolation.rmempty = true
route_isolation.default = "auto"

route_isolation:value(
	"auto",
	translate("Auto (mwan3 aware)")
)
route_isolation:value("native", translate("Native binding only"))
route_isolation:value("mwan3", translate("Force mwan3 isolation"))

route_isolation.description = translate(
	"When mwan3 is running, Auto routes Dr.COM UDP through its WAN table "
	.. "and launches Portal through 'mwan3 use'. Native uses the daemon "
	.. "bindings only."
)


local heartbeat_interval = instances:taboption(
	"advanced",
	Value,
	"heartbeat_interval",
	translate("Heartbeat interval (seconds)")
)

heartbeat_interval.rmempty = true

heartbeat_interval:depends("auth_method", "dot1x")
heartbeat_interval.placeholder = "12"
heartbeat_interval.datatype = "and(uinteger,min(1),max(3600))"


local heartbeat_timeout = instances:taboption(
	"advanced",
	Value,
	"heartbeat_timeout",
	translate("Heartbeat timeout (seconds)")
)

heartbeat_timeout.rmempty = true

heartbeat_timeout:depends("auth_method", "dot1x")
heartbeat_timeout.placeholder = "2"
heartbeat_timeout.datatype = "and(uinteger,min(1),max(3600))"


local eap_timeout = instances:taboption(
	"advanced",
	Value,
	"eap_timeout",
	translate("EAP receive timeout (seconds)")
)

eap_timeout.rmempty = true

eap_timeout:depends("auth_method", "dot1x")
eap_timeout.placeholder = "1"
eap_timeout.datatype = "and(uinteger,min(1),max(3600))"


local eap_retries = instances:taboption(
	"advanced",
	Value,
	"eap_retries",
	translate("EAP retries")
)

eap_retries.rmempty = true

eap_retries:depends("auth_method", "dot1x")
eap_retries.placeholder = "3"
eap_retries.datatype = "and(uinteger,min(1),max(100))"


local onlinehook = instances:taboption(
	"advanced",
	Value,
	"onlinehook",
	translate("Online hook")
)

onlinehook.rmempty = true

onlinehook:depends("auth_method", "dot1x")
onlinehook.description = translate(
	"Shell command executed after EAP authentication success. "
	.. "Use with care."
)


local offlinehook = instances:taboption(
	"advanced",
	Value,
	"offlinehook",
	translate("Offline hook")
)

offlinehook.rmempty = true

offlinehook:depends("auth_method", "dot1x")
offlinehook.description = translate(
	"Shell command executed when the client is forced offline. "
	.. "Use with care."
)


-- Logging

local log_level = instances:taboption(
	"logging",
	ListValue,
	"log_level",
	translate("Log level")
)

log_level.rmempty = false
log_level.default = "info"

log_level:value("error", "error")
log_level:value("warn", "warn")
log_level:value("info", "info")
log_level:value("debug", "debug")
log_level:value("trace", "trace")


local log_size = instances:taboption(
	"logging",
	Value,
	"log_size",
	translate("Maximum log size (bytes)")
)

log_size.rmempty = true
log_size.placeholder = "262144"
log_size.datatype = "and(uinteger,min(1024))"


local log_keep = instances:taboption(
	"logging",
	Value,
	"log_keep",
	translate("Log files to keep")
)

log_keep.rmempty = true
log_keep.placeholder = "2"
log_keep.datatype = "and(uinteger,min(1),max(9))"


local log_system = instances:taboption(
	"logging",
	Flag,
	"log_system",
	translate("System log")
)

log_system.rmempty = false
log_system.default = "1"
log_system.description = translate(
	"Mirror log output to the OpenWrt system log via procd."
)


local log_file = instances:taboption(
	"logging",
	Flag,
	"log_file",
	translate("Per-instance file log")
)

log_file.rmempty = false
log_file.default = "1"
log_file.description = translate(
	"Write this instance's log to /tmp/scutclient/<instance>.log."
)


-- Web Portal

local portal_protocol = instances:taboption(
	"portal",
	ListValue,
	"portal_protocol",
	translate("Portal protocol")
)

portal_protocol.rmempty = true
portal_protocol.default = "auto"
portal_protocol:depends("auth_method", "portal")

portal_protocol:value(
	"auto",
	translate("Auto (prefer Dr.COM Web)")
)
portal_protocol:value("eportal", "ePortal")
portal_protocol:value("drcom", "Dr.COM Web")

portal_protocol.description = translate(
	"Auto uses the Dr.COM Web login endpoint detected with the Location, "
	.. "which works even when the ePortal ports are unreachable. Select "
	.. "a backend manually only if your campus network requires it."
)


local portal_suffix = instances:taboption(
	"portal",
	Value,
	"portal_suffix",
	translate("Account suffix")
)

portal_suffix.rmempty = true
portal_suffix:depends("auth_method", "portal")

portal_suffix.description = translate(
	"Optional account suffix. "
	.. "Leave empty for normal campus accounts. "
	.. "Examples: @dx, @lt."
)


local portal_connect_timeout = instances:taboption(
	"portal",
	Value,
	"portal_connect_timeout",
	translate("Connect timeout (seconds)")
)

portal_connect_timeout.rmempty = true
portal_connect_timeout.placeholder = "5"
portal_connect_timeout.datatype = "and(uinteger,min(1),max(60))"
portal_connect_timeout:depends("auth_method", "portal")


local portal_timeout = instances:taboption(
	"portal",
	Value,
	"portal_timeout",
	translate("Request timeout (seconds)")
)

portal_timeout.rmempty = true
portal_timeout.placeholder = "10"
portal_timeout.datatype = "and(uinteger,min(1),max(120))"
portal_timeout:depends("auth_method", "portal")


local portal_check_interval = instances:taboption(
	"portal",
	Value,
	"portal_check_interval",
	translate("Online check interval (seconds)")
)

portal_check_interval.rmempty = true
portal_check_interval.placeholder = "15"
portal_check_interval.datatype = "and(uinteger,min(5),max(3600))"
portal_check_interval:depends("auth_method", "portal")


local portal_tls_verify = instances:taboption(
	"portal",
	Flag,
	"portal_tls_verify",
	translate("Verify TLS certificates")
)

portal_tls_verify.rmempty = false
portal_tls_verify.default = "1"
portal_tls_verify:depends("auth_method", "portal")
portal_tls_verify.description = translate(
	"Validate https:// portal certificates against the system CA bundle."
)


local portal_http_port = instances:taboption(
	"portal",
	Value,
	"portal_http_port",
	translate("ePortal HTTP port")
)

portal_http_port.rmempty = true
portal_http_port.placeholder = "801"
portal_http_port.datatype = "port"
portal_http_port:depends("auth_method", "portal")
portal_http_port.description = translate(
	"ePortal login port used when the Location is http://. "
	.. "Leave empty to use the protocol default."
)


local portal_https_port = instances:taboption(
	"portal",
	Value,
	"portal_https_port",
	translate("ePortal HTTPS port")
)

portal_https_port.rmempty = true
portal_https_port.placeholder = "802"
portal_https_port.datatype = "port"
portal_https_port:depends("auth_method", "portal")
portal_https_port.description = translate(
	"ePortal login port used when the Location is https://. "
	.. "Leave empty to use the protocol default."
)


local portal_program_index = instances:taboption(
	"portal",
	Value,
	"portal_program_index",
	translate("Program index override")
)

portal_program_index.rmempty = true
portal_program_index:depends("auth_method", "portal")
portal_program_index.description = translate(
	"Optional. Program index of the Dr.COM Web login page. "
	.. "Leave empty unless the campus portal requires a specific value."
)


local portal_page_index = instances:taboption(
	"portal",
	Value,
	"portal_page_index",
	translate("Page index override")
)

portal_page_index.rmempty = true
portal_page_index.placeholder = "0"
portal_page_index.datatype = "uinteger"
portal_page_index:depends("auth_method", "portal")


local portal_js_version = instances:taboption(
	"portal",
	Value,
	"portal_js_version",
	translate("JS version override")
)

portal_js_version.rmempty = true
portal_js_version.placeholder = "4.1.3"
portal_js_version:depends("auth_method", "portal")


local portal_r3 = instances:taboption(
	"portal",
	Value,
	"portal_r3",
	translate("R3 override")
)

portal_r3.rmempty = true
portal_r3:depends("auth_method", "portal")
portal_r3.description = translate(
	"Optional Dr.COM Web R3 value. Only needed when the campus portal "
	.. "uses the carrier selection mode (enable_r3)."
)


return scut
