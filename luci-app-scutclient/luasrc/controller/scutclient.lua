module("luci.controller.scutclient", package.seeall)

local http = require "luci.http"
local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"
local uci  = require "luci.model.uci".cursor()

local log_dir = "/tmp/scutclient"
local state_dir = "/var/run/scutclient"

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

local function instance_pid(id, procd)
	local info = (procd or procd_instances())[id]

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

-- network.interface dump：一次请求只调一次 ubus，
-- 所有实例共享同一份 netifd 状态。
local function get_network_dump()
	local data = util.ubus("network.interface", "dump", {})

	if type(data) == "table" and type(data.interface) == "table" then
		return data.interface
	end

	return {}
end

local function find_network_status(name, dump)
	if not name or name == "" then
		return nil
	end

	for _, net in ipairs(dump or {}) do
		if net.interface == name then
			return net
		end
	end

	return nil
end

local function valid_netdev(name)
	return type(name) == "string"
		and name ~= ""
		and name:find("/", 1, true) == nil
end

local function normalize_mac(value)
	value = trim(value or "")

	if value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return value:upper()
	end

	return ""
end

-- 运行时 MAC 优先取 sysfs，其次 netifd network.device status；
-- 无线 STA / 厂商 netdev 经 luci.model.network 的 dev:mac() 拿不到。
local function runtime_mac(device)
	if not valid_netdev(device) then
		return ""
	end

	local mac = normalize_mac(
		fs.readfile("/sys/class/net/" .. device .. "/address")
	)

	if mac ~= "" then
		return mac
	end

	local dev = util.ubus("network.device", "status", { name = device })

	if type(dev) == "table" then
		mac = normalize_mac(dev.macaddr or dev.address or "")

		if mac ~= "" then
			return mac
		end
	end

	return ""
end

-- 读取 C 核心写入的实例运行状态文件（.tmp + rename 原子替换，
-- 不会读到半写内容）。格式：state=/detail=/updated=/heartbeat=
local function read_instance_state(id)
	if not safe_id(id) then
		return nil
	end

	local path = state_dir .. "/" .. id .. ".state"

	local content = fs.readfile(path)

	if not content then
		return nil
	end

	local state = {}

	for line in content:gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")

		if key then
			state[key] = value
		end
	end

	return state
end

-- 无状态文件时的回退推断；running 绝不能 fallback 成 online。
local function fallback_instance_state(inst)
	if not inst.enabled then
		return "disabled"
	end

	if not inst.interface_up then
		return "waiting_interface"
	end

	if not inst.running then
		return "stopped"
	end

	return "starting"
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

-- Portal 探测：logical interface 必须真实存在于 /etc/config/network，
-- 字符集校验拒绝注入；不接受 url/device/command 等其他输入。
local function valid_logical_interface(name)
	if type(name) ~= "string"
		or name == ""
		or #name > 64
	then
		return false
	end

	if not name:match("^[%w_.%-]+$") then
		return false
	end

	local found = false

	uci:foreach("network", "interface", function(s)
		if s[".name"] == name then
			found = true
		end
	end)

	return found
end

-- 解析 logical WAN 的真实 netdev 与源 IPv4（无线设备名绑定间歇性
-- 失败，HTTP 探测优先按源 IPv4 绑定）。
local function resolve_runtime_network(interface)
	local dump = get_network_dump()

	if type(dump) ~= "table" then
		return nil, nil
	end

	for _, net in ipairs(dump) do
		if net.interface == interface then
			local device = net.l3_device or net.device
			local ipv4 = ""

			if type(net["ipv4-address"]) == "table"
				and type(net["ipv4-address"][1]) == "table"
				and type(net["ipv4-address"][1].address) == "string"
				and net["ipv4-address"][1].address
					:match("^%d+%.%d+%.%d+%.%d+$")
			then
				ipv4 = net["ipv4-address"][1].address
			end

			return device, ipv4
		end
	end

	return nil, nil
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

	-- 使用 LuCI 的 post() target，自动要求 POST 并校验 token。
	entry(
		{"admin", "services", "scutclient", "api_service"},
		post("action_api_service")
	).leaf = true

	-- Portal Location 探测：POST + CSRF token；使用当前表单的
	-- logical WAN，不要求实例已保存到 UCI。
	entry(
		{"admin", "services", "scutclient", "api_portal_probe"},
		post("action_api_portal_probe")
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
	local instances = {}
	local network_dump = get_network_dump()
	local procd = procd_instances()

	uci:foreach("scutclient", "scutclient", function(s)
		local id = s[".name"]
		-- 多实例模式下不静默 fallback 到 wan
		local interface = s.interface or ""

		local inst = {
			id = id,
			name = s.name or id,
			enabled = (s.enabled == "1"),
			username = s.username or "",
			interface = interface,
			server = s.server_auth_ip or "",

			running = false,
			pid = nil,

			interface_up = false,
			interface_pending = false,
			interface_available = false,

			device = "",
			ipaddr = "",

			configured_mac = normalize_mac(s.macaddr or ""),
			mac = "",
			mac_source = "",

			process_state = "stopped",
			auth_state = "unknown",
			auth_detail = "",
			auth_updated = nil,
			heartbeat = nil
		}

		local p = procd[id]

		if p and p.running and p.pid then
			inst.running = true
			inst.pid = p.pid
		else
			local pid = instance_pid(id, procd)

			if pid then
				inst.running = true
				inst.pid = pid
			end
		end

		local net = find_network_status(interface, network_dump)

		if net then
			inst.interface_up = (net.up == true)
			inst.interface_pending = (net.pending == true)
			inst.interface_available = (net.available == true)

			inst.device = net.l3_device or net.device or ""

			if type(net["ipv4-address"]) == "table" then
				for _, a in ipairs(net["ipv4-address"]) do
					if type(a) == "table"
						and type(a.address) == "string"
						and a.address:match("^%d+%.%d+%.%d+%.%d+$")
					then
						inst.ipaddr = a.address
						break
					end
				end
			end
		end

		-- 运行时真实 MAC 优先，配置 MAC 仅作 fallback
		inst.mac = runtime_mac(inst.device)

		if inst.mac ~= "" then
			inst.mac_source = "runtime"
		elseif inst.configured_mac ~= "" then
			inst.mac = inst.configured_mac
			inst.mac_source = "configured"
		end

		if inst.mac ~= "" and inst.configured_mac ~= "" then
			inst.mac_match =
				inst.mac:upper() == inst.configured_mac:upper()
		end

		local state = read_instance_state(id)

		if state then
			inst.auth_state = state.state or "unknown"
			inst.auth_detail = state.detail or ""
			inst.auth_updated = tonumber(state.updated)
			inst.heartbeat = tonumber(state.heartbeat)
		else
			inst.auth_state = fallback_instance_state(inst)
			inst.auth_detail = ""
		end

		inst.process_state = inst.running and "running" or "stopped"

		instances[#instances + 1] = inst
	end)

	json_response({
		enabled =
			uci:get_first("scutclient", "option", "enable") == "1",
		version = get_package_version(),
		instances = instances
	})
end

function action_api_portal_probe()
	local interface = http.formvalue("interface") or ""

	if not valid_logical_interface(interface) then
		http.status(400, "Bad Request")
		return json_response({
			success = false,
			reason = "invalid_interface"
		})
	end

	local device, source_ip = resolve_runtime_network(interface)

	if not device
		or device == ""
		or not device:match("^[%w_.:%-]+$")
		or source_ip == ""
	then
		return json_response({
			success = false,
			reason = "interface_not_ready",
			interface = interface
		})
	end

	local output = trim(sys.exec(
		"/usr/lib/scutclient/scutclient-portal-probe " ..
		util.shellquote(device) .. " " ..
		util.shellquote(source_ip) .. " 2>/dev/null"
	))

	local http_code = tonumber(output:match("http_code=(%d+)"))
	local location = trim(output:match("location=(.+)") or "")

	if not http_code then
		return json_response({
			success = false,
			reason = "request_failed",
			interface = interface,
			device = device
		})
	end

	-- 成功条件：300~399 且 Location 为 http(s):// 绝对地址
	if location ~= ""
		and location:match("^https?://")
		and http_code >= 300
		and http_code <= 399
	then
		return json_response({
			success = true,
			interface = interface,
			device = device,
			http_code = http_code,
			location = location
		})
	end

	local reason = "no_redirect"

	if http_code == 200 then
		reason = "no_location"
	end

	return json_response({
		success = false,
		reason = reason,
		http_code = http_code,
		interface = interface,
		device = device
	})
end

function action_api_service()
	local action = http.formvalue("action") or ""
	local instance = http.formvalue("instance") or ""
	local rc = 1

	if instance ~= "" and not check_instance_param(instance) then
		return
	end

	-- rc.common 原生支持按实例操作：start/stop/restart <id>；
	-- logoff 需要 portal 参数，仍走 logoff_instance。
	if action == "start" or action == "stop" or action == "restart" then
		local target = action
		if instance ~= "" then
			target = action .. " " .. instance
		end
		rc = sys.call("/etc/init.d/scutclient " .. target .. " >/dev/null 2>&1")
	elseif action == "logoff" then
		if instance ~= "" then
			rc = sys.call("/etc/init.d/scutclient logoff_instance " ..
				instance .. " >/dev/null 2>&1")
		else
			rc = sys.call("/etc/init.d/scutclient logoff >/dev/null 2>&1")
		end
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
