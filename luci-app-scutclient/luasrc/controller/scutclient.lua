module("luci.controller.scutclient", package.seeall)

local http = require "luci.http"
local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local uci  = require "luci.model.uci".cursor()

local log_dir = "/tmp/scutclient"

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

-- UCI section id 字符集校验，防止拼接 shell/路径
local function safe_id(value)
	return value ~= nil and value:match("^%w[%w%-_]*$") ~= nil
end

local function valid_instance(section)
	local found = false

	uci:foreach("scutclient", "scutclient", function(s)
		if s[".name"] == section then
			found = true
		end
	end)

	return found
end

local function procd_instances()
	local jsonc = require "luci.jsonc"
	local out = trim(sys.exec("ubus call service list 2>/dev/null"))
	local data = out ~= "" and jsonc.parse(out) or nil

	if data
		and data.scutclient
		and data.scutclient.instances
	then
		return data.scutclient.instances
	end

	return {}
end

local function instance_pid(id)
	local insts = procd_instances()
	local info = insts[id]

	if info
		and info.running
		and info.pid
	then
		return info.pid
	end

	-- 兜底：扫描 /proc 匹配 --instance 参数
	local out = sys.exec(
		"for p in /proc/[0-9]*/cmdline; do " ..
		"if tr '\\0' ' ' < \"$p\" 2>/dev/null | " ..
		"grep -q -- '--instance " .. id .. " '; then " ..
		"basename \"$(dirname \"$p\")\"; break; fi; done 2>/dev/null"
	)
	out = trim(out)

	if out ~= "" and tonumber(out) then
		return tonumber(out)
	end

	return nil
end

local function log_path(instance)
	return log_dir .. "/" .. instance .. ".log"
end

local function check_instance_param(instance)
	if not safe_id(instance) or not valid_instance(instance) then
		http.status(400, "Bad Request")
		json_response({
			success = false,
			message = "Unknown instance"
		})
		return false
	end
	return true
end

function index()
	if not fs.access("/etc/config/scutclient") then
		return
	end

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
		{"admin", "services", "scutclient", "api_log"},
		call("action_api_log")
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "api_log_clear"},
		post("action_api_log_clear")
	).leaf = true

	entry(
		{"admin", "services", "scutclient", "api_log_download"},
		call("action_api_log_download")
	).leaf = true
end

function action_api_status()
	local ntm = require "luci.model.network".init()

	local instances = {}

	uci:foreach("scutclient", "scutclient", function(s)
		local id = s[".name"]
		local interface = s.interface or "wan"

		local inst = {
			id = id,
			name = s.name or id,
			enabled = (s.enabled == "1"),
			username = s.username or "",
			interface = interface,
			server = s.server_auth_ip or "",
			running = false,
			pid = nil,
			device = "",
			ipaddr = "",
			mac = ""
		}

		local pid = instance_pid(id)
		if pid then
			inst.running = true
			inst.pid = pid
		end

		local net = ntm:get_network(interface)
		if net then
			local dev = net:get_interface()
			inst.device = (dev and dev:name()) or ""
			inst.ipaddr = net:ipaddr() or ""
			inst.mac = (dev and dev:mac()) or ""
		end

		instances[#instances + 1] = inst
	end)

	json_response({
		enabled = uci:get_first("scutclient", "option", "enable") == "1",
		version = get_package_version(),
		instances = instances
	})
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
	local instance = http.formvalue("instance") or ""
	local rc = 1

	if instance ~= "" and not check_instance_param(instance) then
		return
	end

	local suffix = ""
	if instance ~= "" then
		suffix = "_instance " .. instance
	end

	if action == "start" then
		rc = sys.call("/etc/init.d/scutclient start" .. suffix .. " >/dev/null 2>&1")
	elseif action == "stop" then
		rc = sys.call("/etc/init.d/scutclient stop" .. suffix .. " >/dev/null 2>&1")
	elseif action == "restart" then
		rc = sys.call("/etc/init.d/scutclient restart" .. suffix .. " >/dev/null 2>&1")
	elseif action == "logoff" then
		rc = sys.call("/etc/init.d/scutclient logoff" .. suffix .. " >/dev/null 2>&1")
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
		action = action,
		instance = instance
	})
end

function action_api_log()
	local instance = http.formvalue("instance") or ""
	local lines = tonumber(http.formvalue("lines")) or 200

	if not check_instance_param(instance) then
		return
	end

	if lines < 10 then
		lines = 10
	elseif lines > 2000 then
		lines = 2000
	end

	local path = log_path(instance)
	local content = ""

	if fs.access(path) then
		content = trim(sys.exec(
			string.format("tail -n %d '%s'", lines, path)
		))
	end

	http.prepare_content("text/plain; charset=utf-8")
	http.write(content)
end

function action_api_log_clear()
	local instance = http.formvalue("instance") or ""

	if not check_instance_param(instance) then
		return
	end

	local path = log_path(instance)

	if fs.access(path) then
		local file = io.open(path, "w")
		if file then
			file:close()
		end
	end

	json_response({ success = true })
end

function action_api_log_download()
	local instance = http.formvalue("instance") or ""

	if not check_instance_param(instance) then
		return
	end

	local path = log_path(instance)
	local content = ""

	if fs.access(path) then
		content = fs.readfile(path) or ""
	end

	http.header(
		"Content-Disposition",
		'attachment; filename="scutclient-' .. instance .. '.log"'
	)
	http.prepare_content("text/plain; charset=utf-8")
	http.write(content)
end
