-- LuCI configuration page for scutclient

local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"

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
	translate("Configure the SCUT Dr.com client. Save the settings before restarting the service.")
)


-- Quick links

local guide = scut:section(SimpleSection)
guide.template = "scutclient/quicklinks"


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


local debug = options:option(
	Flag,
	"debug",
	translate("Debug logging")
)

debug.default = "0"
debug.description = translate(
	"Enable verbose scutclient debug output. Disable it during normal use."
)


-- Account

local client = scut:section(
	TypedSection,
	"scutclient",
	translate("Account")
)

client.anonymous = true
client.addremove = false


local username = client:option(
	Value,
	"username",
	translate("Username")
)

username.rmempty = false
username.description = translate(
	"Usually your student number or the username issued by the university."
)


local password = client:option(
	Value,
	"password",
	translate("Password")
)

password.password = true
password.rmempty = false


-- OpenWrt logical network interface

local interface = client:option(
	ListValue,
	"interface",
	translate("Authentication interface")
)

interface.default = "wan"
interface.rmempty = false

local found_wan = false

uci:foreach("network", "interface", function(section)
	local name = section[".name"]

	if name and name ~= "" and name ~= "loopback" then
		interface:value(name, name)

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
	.. "The service resolves it to the actual network device automatically."
)


-- Dr.com settings

local drcom = scut:section(
	TypedSection,
	"drcom",
	translate("Dr.com Settings")
)

drcom.anonymous = true
drcom.addremove = false


local server = drcom:option(
	Value,
	"server_auth_ip",
	translate("Authentication server")
)

server.rmempty = false
server.datatype = "ip4addr"
server.default = "202.38.210.131"


local dns = drcom:option(
	Value,
	"dns",
	translate("DNS server")
)

dns.rmempty = false
dns.datatype = "ip4addr"
dns.default = "222.201.130.30"


local version = drcom:option(
	ListValue,
	"version",
	translate("Dr.com version")
)

version.rmempty = false

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


local hash = drcom:option(
	ListValue,
	"hash",
	translate("DrAuthSvr.dll hash")
)

hash.rmempty = false

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

local nettime = drcom:option(
	Value,
	"nettime",
	translate("Allowed online time")
)

nettime.description = translate(
	"Duration accepted by scutclient, for example 6:15. "
	.. "Leave empty to use the daemon default."
)

nettime.rmempty = true

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

local hostname = drcom:option(
	Value,
	"hostname",
	translate("Hostname sent to server")
)

hostname.rmempty = false
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


return scut