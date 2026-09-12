module("luci.controller.scutclient", package.seeall)

local http = require "luci.http"
local fs   = require "nixio.fs"
local sys  = require "luci.sys"

local log_file = "/tmp/scutclient.log"

local function trim(value)
	return (value or ""):gsub("[\r\n]+$", "")
end

local function json_response(data)
	http.prepare_content("application/json")
	http.write_json(data)
end

local function get_package_version()
	local version = sys.exec(
		"opkg status scutclient 2>/dev/null | " ..
		"awk -F': ' '/^Version:/{print $2; exit}'"
	)
	return trim(version)
end

local function service_running()
	return sys.call("pidof scutclient >/dev/null 2>&1") == 0
end

function index()
	if not fs.access("/etc/config/scutclient") then
		return
	end

	local uci = require "luci.model.uci".cursor()
	local mainorder = tonumber(uci:get_first("scutclient", "luci", "mainorder")) or 10

	entry(
		{"admin", "services", "scutclient"},
		alias("admin", "services", "scutclient", "status"),
		_("SCUT Client"),
		mainorder
	).dependent = true

	entry(
		{"admin", "services", "scutclient", "status"},
		template("scutclient/status"),
		_("Status"),
		10
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "settings"},
		cbi("scutclient/scutclient"),
		_("Settings"),
		20
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "logs"},
		template("scutclient/logs"),
		_("Logs"),
		30
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "about"},
		template("scutclient/about"),
		_("About"),
		40
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "api_status"},
		call("action_api_status")
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "api_netstat"},
		call("action_api_netstat")
	).leaf = true

	-- 使用 LuCI 的 post() target，自动要求 POST 并校验 token。
	entry(
		{"admin", "services", "scutclient", "api_service"},
		post("action_api_service")
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "get_log"},
		call("action_get_log")
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "scutclient.log"},
		call("action_download_log")
	).leaf = true
end

function action_api_status()
	local uci = require "luci.model.uci".cursor()
	local ntm = require "luci.model.network".init()

	local interface = uci:get_first("scutclient", "scutclient", "interface") or "wan"
	local network = ntm:get_network(interface)

	local result = {
		running = service_running(),
		enabled = uci:get_first("scutclient", "option", "enable") == "1",
		version = get_package_version(),
		interface = interface,
		username = uci:get_first("scutclient", "scutclient", "username") or "",
		hostname = uci:get_first("scutclient", "drcom", "hostname") or "",
		server_auth_ip = uci:get_first("scutclient", "drcom", "server_auth_ip") or "",
		ipaddr = "",
		netmask = "",
		gateway = "",
		dns = "",
		device = "",
		mac = ""
	}

	if network then
		result.ipaddr = network:ipaddr() or ""
		result.netmask = network:netmask() or ""
		result.gateway = network:gwaddr() or ""

		local dns = network:dnsaddrs() or {}
		result.dns = table.concat(dns, ", ")

		local device = network:get_interface()
		if device then
			result.device = device:name() or ""
			result.mac = device:mac() or ""
		end
	end

	json_response(result)
end

function action_api_netstat()
	local output = trim(sys.exec(
		"wget -q -T 3 -O- http://whatismyip.akamai.com 2>/dev/null | head -n 1"
	))

	local state = "unknown"

	if output == "" then
		state = "no_internet"
	elseif output:match("^%d+%.%d+%.%d+%.%d+$") then
		state = "internet"
	else
		state = "no_login"
	end

	json_response({ stat = state })
end

function action_api_service()
	local action = http.formvalue("action") or ""
	local rc = 1

	if action == "start" then
		rc = sys.call("/etc/init.d/scutclient start >/dev/null 2>&1")
	elseif action == "stop" then
		rc = sys.call("/etc/init.d/scutclient stop >/dev/null 2>&1")
	elseif action == "restart" then
		rc = sys.call("/etc/init.d/scutclient restart >/dev/null 2>&1")
	elseif action == "logoff" then
		rc = sys.call("/etc/init.d/scutclient logoff >/dev/null 2>&1")
	else
		http.status(400, "Bad Request")
		json_response({
			success = false,
			message = "Unsupported action"
		})
		return
	end

	json_response({
		success = rc == 0,
		action = action
	})
end

function action_get_log()
	local content = ""

	if fs.access(log_file) then
		content = sys.exec("tail -n 200 " .. log_file)
	else
		content = "No scutclient log is available."
	end

	http.prepare_content("text/plain; charset=utf-8")
	http.write(content)
end

function action_download_log()
	local content = ""

	if fs.access(log_file) then
		content = fs.readfile(log_file) or ""
	end

	http.header("Content-Disposition", 'attachment; filename="scutclient.log"')
	http.prepare_content("text/plain; charset=utf-8")
	http.write(content)
end