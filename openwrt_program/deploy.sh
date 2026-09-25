#!/bin/sh
# ESPtoPC Wireless Remote Switch - install/update. Run: sh deploy.sh
set -e

mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd /www/luci-static/resources/view

cat > /usr/share/luci/menu.d/luci-app-esptopcrsw.json << 'MENU_EOF'
{
	"admin/services/esptopcrsw": {
		"title": "ESPtoPC Wireless Remote Switch",
		"order": 10,
		"action": {
			"type": "view",
			"path": "esptopcrsw"
		}
	}
}
MENU_EOF

cat > /usr/share/rpcd/acl.d/luci-app-esptopcrsw.json << 'ACL_EOF'
{
	"luci-app-esptopcrsw": {
		"description": "Access to ESPtoPC Wireless Remote Switch devices",
		"read": {
			"ubus": { "esptopcrsw": [ "list", "dhcp_clients", "pending_devices" ] },
			"uci": [ "esptopcrsw" ]
		},
		"write": {
			"ubus": { "esptopcrsw": [ "list", "dhcp_clients", "pending_devices", "add_device", "rename_device", "remove_device", "command" ] },
			"uci": [ "esptopcrsw" ]
		}
	}
}
ACL_EOF

cat > /usr/libexec/rpcd/esptopcrsw << 'RPCD_EOF'
#!/bin/sh
# rpcd script-plugin backend for ESPtoPC Wireless Remote Switch.
# Protocol: "$0 list" (method description), "$0 call <method>" (JSON args on stdin).
#
# Storage:
#   /etc/config/esptopcrsw        - devices (mac,name) + settings, UCI (flash)
#   /tmp/esptopcrsw/<MAC>.seen    - "unix_ts port" from last announce/heartbeat
#   /tmp/esptopcrsw/<MAC>.status  - last known pc_status ("on"/"off")
#   /tmp/esptopcrsw/<MAC>.onsince - unix_ts of transition to "on" (Power-block timer)
# Everything under /tmp is RAM, lost on router reboot - expected, not a problem.

. /usr/share/libubox/jshn.sh
. /lib/functions.sh

STATE_DIR="/tmp/esptopcrsw"
mkdir -p "$STATE_DIR"

mac_key() { echo "$1" | tr 'a-z' 'A-Z' | tr ':' '-'; }
seen_file()    { echo "$STATE_DIR/$(mac_key "$1").seen"; }
status_file()  { echo "$STATE_DIR/$(mac_key "$1").status"; }
onsince_file() { echo "$STATE_DIR/$(mac_key "$1").onsince"; }

get_offline_timeout() { config_get v settings offline_timeout 300; echo "$v"; }
get_block_window()    { config_get v settings power_block_after_on 60; echo "$v"; }

device_online() {
	local mac="$1" timeout="$2" now last_seen f
	f="$(seen_file "$mac")"
	[ -f "$f" ] || { echo "false"; return; }
	last_seen="$(awk '{print $1}' "$f" 2>/dev/null)"
	now="$(date +%s)"
	if [ -n "$last_seen" ] && [ "$((now - last_seen))" -lt "$timeout" ]; then
		echo "true"
	else
		echo "false"
	fi
}

device_port() {
	local f; f="$(seen_file "$1")"
	if [ -f "$f" ]; then
		awk '{print $2}' "$f"
	else
		echo "80"
	fi
}

command_key() {
	local mac password mac_upper
	mac="$1"
	mac_upper="$(echo "$mac" | tr 'a-z' 'A-Z')"
	config_get password settings password
	echo -n "${mac_upper}:${password}" | md5sum | cut -c1-12
}

resolve_ip() {
	mac_lower="$(echo "$1" | tr 'A-Z' 'a-z')"
	mac_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
	awk -v m="$mac_lower" 'tolower($2)==m {print $3}' /tmp/dhcp.leases 2>/dev/null | tail -n1
}

fetch_status() {
	local mac="$1" ip port url body
	ip="$(resolve_ip "$mac")"
	[ -z "$ip" ] && { echo "unknown"; return; }
	port="$(device_port "$mac")"
	url="http://$ip:$port/status?key=$(command_key "$mac")"
	body="$(uclient-fetch -q -T 3 -O - "$url" 2>/dev/null)"
	case "$body" in
		*'"pc_status":"on"'*)  echo "on" ;;
		*'"pc_status":"off"'*) echo "off" ;;
		*) echo "unknown" ;;
	esac
}

update_status_cache() {
	local mac="$1" status="$2" prev f
	f="$(status_file "$mac")"
	prev="$(cat "$f" 2>/dev/null)"
	echo "$status" > "$f"
	if [ "$status" = "on" ] && [ "$prev" != "on" ]; then
		date +%s > "$(onsince_file "$mac")"
	fi
	if [ "$status" != "on" ]; then
		rm -f "$(onsince_file "$mac")"
	fi
}

power_blocked() {
	local mac="$1" window="$2" f since now
	f="$(onsince_file "$mac")"
	[ -f "$f" ] || { echo "false"; return; }
	since="$(cat "$f")"
	now="$(date +%s)"
	if [ "$((now - since))" -lt "$window" ]; then
		echo "true"
	else
		echo "false"
	fi
}

find_section_by_mac() {
	local wanted="$1" wanted_upper
	wanted_upper="$(echo "$wanted" | tr 'a-z' 'A-Z')"
	FOUND_SECTION=""
	find_one() {
		local m m_upper
		config_get m "$1" mac
		m_upper="$(echo "$m" | tr 'a-z' 'A-Z')"
		[ "$m_upper" = "$wanted_upper" ] && FOUND_SECTION="$1"
	}
	config_foreach find_one device
}

rpc_list() {
	json_init
	json_add_object "list"; json_close_object
	json_add_object "dhcp_clients"; json_close_object
	json_add_object "pending_devices"; json_close_object
	json_add_object "add_device"
	json_add_string "mac" ""
	json_add_string "name" ""
	json_close_object
	json_add_object "rename_device"
	json_add_string "mac" ""
	json_add_string "name" ""
	json_close_object
	json_add_object "remove_device"
	json_add_string "mac" ""
	json_close_object
	json_add_object "command"
	json_add_string "mac" ""
	json_add_string "action" ""
	json_close_object
	json_dump
}

call_list() {
	local timeout window
	config_load esptopcrsw
	timeout="$(get_offline_timeout)"
	window="$(get_block_window)"

	json_init
	json_add_array "devices"

	list_one() {
		local section="$1" mac name online status blocked ip
		config_get mac "$section" mac
		config_get name "$section" name
		[ -z "$mac" ] && return

		online="$(device_online "$mac" "$timeout")"
		ip="$(resolve_ip "$mac")"
		if [ "$online" = "true" ]; then
			status="$(fetch_status "$mac")"
			update_status_cache "$mac" "$status"
			blocked="$(power_blocked "$mac" "$window")"
		else
			status="unknown"
			blocked="false"
		fi

		json_add_object ""
		json_add_string "mac" "$mac"
		json_add_string "name" "$name"
		json_add_string "ip" "${ip:-}"
		[ "$online" = "true" ] && json_add_boolean "online" 1 || json_add_boolean "online" 0
		json_add_string "pc_status" "$status"
		[ "$blocked" = "true" ] && json_add_boolean "power_blocked" 1 || json_add_boolean "power_blocked" 0
		json_close_object
	}
	config_foreach list_one device

	json_close_array
	json_dump
}

call_dhcp_clients() {
	json_init
	json_add_array "clients"
	if [ -f /tmp/dhcp.leases ]; then
		while read -r exp mac ip host cid; do
			[ -z "$mac" ] && continue
			json_add_object ""
			json_add_string "mac" "$mac"
			json_add_string "ip" "$ip"
			json_add_string "hostname" "$host"
			json_close_object
		done < /tmp/dhcp.leases
	fi
	json_close_array
	json_dump
}

call_pending_devices() {
	config_load esptopcrsw
	json_init
	json_add_array "pending"

	for f in "$STATE_DIR"/*.seen; do
		[ -e "$f" ] || continue
		base="$(basename "$f" .seen)"
		mac="$(echo "$base" | tr '-' ':')"

		find_section_by_mac "$mac"
		if [ -z "$FOUND_SECTION" ]; then
			ip="$(resolve_ip "$mac")"
			last_seen="$(awk '{print $1}' "$f")"
			json_add_object ""
			json_add_string "mac" "$mac"
			json_add_string "ip" "${ip:-}"
			json_add_int "last_seen" "${last_seen:-0}"
			json_close_object
		fi
	done

	json_close_array
	json_dump
}

call_add_device() {
	local mac name
	json_load "$(cat)"
	json_get_var mac mac
	json_get_var name name
	if [ -z "$mac" ]; then
		echo '{"error":"mac required"}'
		return 1
	fi
	mac="$(echo "$mac" | tr 'a-z' 'A-Z')"

	config_load esptopcrsw
	find_section_by_mac "$mac"
	if [ -z "$FOUND_SECTION" ]; then
		FOUND_SECTION="$(uci add esptopcrsw device)"
	fi
	uci set "esptopcrsw.$FOUND_SECTION.mac=$mac"
	uci set "esptopcrsw.$FOUND_SECTION.name=$name"
	uci commit esptopcrsw

	json_init
	json_add_boolean "ok" 1
	json_dump
}

call_rename_device() { call_add_device; }

call_remove_device() {
	local mac
	json_load "$(cat)"
	json_get_var mac mac
	if [ -z "$mac" ]; then
		echo '{"error":"mac required"}'
		return 1
	fi

	config_load esptopcrsw
	find_section_by_mac "$mac"
	[ -n "$FOUND_SECTION" ] && uci delete "esptopcrsw.$FOUND_SECTION"
	uci commit esptopcrsw

	json_init
	json_add_boolean "ok" 1
	json_dump
}

call_command() {
	local mac action timeout window online ip port status blocked url resp

	json_load "$(cat)"
	json_get_var mac mac
	json_get_var action action

	if [ -z "$mac" ] || [ -z "$action" ]; then
		echo '{"error":"mac and action required"}'
		return 1
	fi

	config_load esptopcrsw
	timeout="$(get_offline_timeout)"
	window="$(get_block_window)"

	if [ "$action" = "check" ]; then
		ip="$(resolve_ip "$mac")"
		if [ -z "$ip" ]; then
			echo '{"error":"device not found in DHCP leases"}'
			return 1
		fi
		status="$(fetch_status "$mac")"
		if [ "$status" = "unknown" ]; then
			echo '{"error":"device not responding"}'
			return 1
		fi
		port="$(device_port "$mac")"
		echo "$(date +%s) $port" > "$(seen_file "$mac")"
		update_status_cache "$mac" "$status"
		json_init
		json_add_boolean "ok" 1
		json_add_string "pc_status" "$status"
		json_dump
		return 0
	fi

	online="$(device_online "$mac" "$timeout")"
	if [ "$online" != "true" ]; then
		echo '{"error":"device offline"}'
		return 1
	fi

	status="$(fetch_status "$mac")"
	if [ "$status" = "unknown" ]; then
		echo '{"error":"status unknown, try again"}'
		return 1
	fi
	update_status_cache "$mac" "$status"
	blocked="$(power_blocked "$mac" "$window")"

	case "$action" in
		power_on)
			if [ "$status" = "on" ] && [ "$blocked" = "true" ]; then
				echo '{"error":"power button blocked for a bit after turning on"}'
				return 1
			fi
			url="/power/on"
			;;
		power_off)
			if [ "$status" != "on" ]; then
				echo '{"error":"PC is already off"}'
				return 1
			fi
			url="/power/off"
			;;
		reset)
			if [ "$status" != "on" ]; then
				echo '{"error":"PC is off, nothing to reset"}'
				return 1
			fi
			url="/reset"
			;;
		*)
			echo '{"error":"unknown action"}'
			return 1
			;;
	esac

	ip="$(resolve_ip "$mac")"
	if [ -z "$ip" ]; then
		echo '{"error":"device not found in DHCP leases"}'
		return 1
	fi
	port="$(device_port "$mac")"
	resp="$(uclient-fetch -q -T 5 -O - "http://$ip:$port$url?key=$(command_key "$mac")" 2>/dev/null)"

	json_init
	json_add_boolean "ok" 1
	json_add_string "sent" "$action"
	json_dump
}

case "$1" in
	list)
		rpc_list
		;;
	call)
		case "$2" in
			list)          call_list ;;
			dhcp_clients)  call_dhcp_clients ;;
			pending_devices) call_pending_devices ;;
			add_device)    call_add_device ;;
			rename_device) call_rename_device ;;
			remove_device) call_remove_device ;;
			command)       call_command ;;
			*) echo '{"error":"method not found"}'; exit 1 ;;
		esac
		;;
esac
RPCD_EOF
chmod 0755 /usr/libexec/rpcd/esptopcrsw

cat > /www/luci-static/resources/view/esptopcrsw.js << 'JS_EOF'
'use strict';
'require view';
'require poll';
'require rpc';

// Текст на английском специально захардкожен строками (не через _()),
// чтобы LuCI не подменял его переводом в зависимости от языка интерфейса.

var callList = rpc.declare({
	object: 'esptopcrsw',
	method: 'list',
	expect: { devices: [] }
});

var callDhcpClients = rpc.declare({
	object: 'esptopcrsw',
	method: 'dhcp_clients',
	expect: { clients: [] }
});

var callPending = rpc.declare({
	object: 'esptopcrsw',
	method: 'pending_devices',
	expect: { pending: [] }
});

var callAdd = rpc.declare({
	object: 'esptopcrsw',
	method: 'add_device',
	params: ['mac', 'name']
});

var callRename = rpc.declare({
	object: 'esptopcrsw',
	method: 'rename_device',
	params: ['mac', 'name']
});

var callRemove = rpc.declare({
	object: 'esptopcrsw',
	method: 'remove_device',
	params: ['mac']
});

var callCommand = rpc.declare({
	object: 'esptopcrsw',
	method: 'command',
	params: ['mac', 'action']
});

return view.extend({
	load: function () {
		return Promise.all([callList(), callDhcpClients(), callPending()]);
	},

	runCommand: function (mac, action, btn) {
		btn.disabled = true;
		var oldText = btn.textContent;
		btn.textContent = 'Working...';
		callCommand(mac, action).then(function (res) {
			if (res && res.error) window.alert(res.error);
		}).catch(function (err) {
			window.alert(err.message || String(err));
		}).finally(function () {
			btn.disabled = false;
			btn.textContent = oldText;
		});
	},

	renderRow: function (dev) {
		var self = this;
		var statusText, statusColor;

		if (!dev.online) {
			statusText = 'Offline'; statusColor = '#999';
		} else if (dev.pc_status === 'on') {
			statusText = 'On'; statusColor = 'green';
		} else if (dev.pc_status === 'off') {
			statusText = 'Off'; statusColor = 'red';
		} else {
			statusText = 'Unknown'; statusColor = '#999';
		}

		var status = E('span', { 'style': 'color:' + statusColor + ';font-weight:bold' }, statusText);
		var actions = [];

		if (!dev.online) {
			var checkBtn = E('button', { 'class': 'cbi-button', 'title': 'Try to reach this device right now and refresh its status' }, 'Check connection');
			checkBtn.addEventListener('click', function () { self.runCommand(dev.mac, 'check', checkBtn); });
			actions.push(checkBtn);
		} else if (dev.pc_status === 'off') {
			var onBtn = E('button', { 'class': 'cbi-button cbi-button-apply', 'title': 'Short press of the power button - turns the PC on' }, 'Power On');
			onBtn.addEventListener('click', function () {
				if (window.confirm('Power on ' + (dev.name || dev.mac) + '?')) self.runCommand(dev.mac, 'power_on', onBtn);
			});
			actions.push(onBtn);
		} else if (dev.pc_status === 'on') {
			var sleepBtn = E('button', { 'class': 'cbi-button', 'title': 'Short press of the power button while PC is on - result depends on PC power settings (sleep or shutdown)' }, 'Off / Sleep');
			sleepBtn.disabled = !!dev.power_blocked;
			if (dev.power_blocked) sleepBtn.title = 'Blocked for a bit right after power-on';
			sleepBtn.addEventListener('click', function () { self.runCommand(dev.mac, 'power_on', sleepBtn); });
			actions.push(sleepBtn, ' ');

			var offBtn = E('button', { 'class': 'cbi-button cbi-button-reset', 'title': 'Long press of the power button - forces the PC off regardless of OS state' }, 'Force Off');
			offBtn.addEventListener('click', function () {
				if (window.confirm('Force power off the PC?')) self.runCommand(dev.mac, 'power_off', offBtn);
			});
			actions.push(offBtn, ' ');

			var resetBtn = E('button', { 'class': 'cbi-button', 'title': 'Short press of the reset button' }, 'Reset');
			resetBtn.addEventListener('click', function () {
				if (window.confirm('Reset the PC?')) self.runCommand(dev.mac, 'reset', resetBtn);
			});
			actions.push(resetBtn);
		} else {
			actions.push(E('span', {}, '-'));
		}

		var renameBtn = E('button', { 'class': 'cbi-button' }, 'Rename');
		renameBtn.addEventListener('click', function () {
			var newName = window.prompt('New name', dev.name);
			if (newName) callRename(dev.mac, newName).then(function () { location.reload(); });
		});

		var removeBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, 'Remove');
		removeBtn.addEventListener('click', function () {
			if (window.confirm('Remove this device?')) callRemove(dev.mac).then(function () { location.reload(); });
		});

		return E('tr', {}, [
			E('td', {}, dev.name || dev.mac),
			E('td', {}, dev.mac),
			E('td', {}, dev.ip || '-'),
			E('td', {}, status),
			E('td', {}, actions),
			E('td', {}, [renameBtn, ' ', removeBtn])
		]);
	},

	renderTable: function (devices) {
		var self = this;
		var table = E('table', { 'class': 'table', 'id': 'esptopcrsw-table' }, [
			E('tr', { 'class': 'tr-table-title' }, [
				E('th', {}, 'Name'),
				E('th', {}, 'MAC'),
				E('th', {}, 'IP'),
				E('th', {}, 'Status'),
				E('th', {}, 'Commands'),
				E('th', {}, 'Manage')
			])
		]);
		(devices || []).forEach(function (dev) { table.appendChild(self.renderRow(dev)); });
		return table;
	},

	renderPending: function (pending, clients) {
		var self = this;
		if (!pending || !pending.length) return E('div', {});

		var box = E('div', {
			'style': 'border:1px solid #f0ad4e;background:#fff8ec;padding:10px;margin-bottom:1em'
		}, [E('strong', {}, 'New device(s) detected, not yet saved:')]);

		pending.forEach(function (p) {
			var hostname = '';
			(clients || []).forEach(function (c) {
				if (c.mac === p.mac && c.hostname && c.hostname !== '*') hostname = c.hostname;
			});
			var nameInput = E('input', { 'type': 'text', 'placeholder': 'Name', 'value': hostname });
			var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, 'Add');
			addBtn.addEventListener('click', function () {
				callAdd(p.mac, nameInput.value).then(function () { location.reload(); });
			});
			box.appendChild(E('div', { 'style': 'margin-top:6px' }, [
				p.mac + (p.ip ? ' (' + p.ip + ')' : '') + '  ',
				nameInput, ' ', addBtn
			]));
		});

		return box;
	},

	render: function (data) {
		var self = this;
		var devices = data[0];
		var clients = data[1];
		var pending = data[2];

		var style = E('style', {}, [
			'#esptopcrsw-table { border-collapse: collapse; width: 100%; }',
			'#esptopcrsw-table th, #esptopcrsw-table td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }'
		].join('\n'));

		var tableWrap = E('div', {}, [self.renderTable(devices)]);

		var macInput = E('input', { 'type': 'text', 'placeholder': 'AA:BB:CC:DD:EE:FF' });
		var nameInput = E('input', { 'type': 'text', 'placeholder': 'Name' });

		var picker = E('select', {});
		picker.appendChild(E('option', { 'value': '' }, '-- pick from network --'));
		(clients || []).forEach(function (c) {
			var label = (c.hostname && c.hostname !== '*' ? c.hostname : c.ip) + ' (' + c.mac + ', ' + c.ip + ')';
			var opt = E('option', { 'value': c.mac }, label);
			opt.setAttribute('data-hostname', c.hostname && c.hostname !== '*' ? c.hostname : '');
			picker.appendChild(opt);
		});
		picker.addEventListener('change', function () {
			if (!picker.value) return;
			macInput.value = picker.value;
			var opt = picker.options[picker.selectedIndex];
			var hostname = opt.getAttribute('data-hostname');
			if (hostname && !nameInput.value) nameInput.value = hostname;
		});

		var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, 'Add device');
		addBtn.addEventListener('click', function () {
			if (!macInput.value) return;
			callAdd(macInput.value, nameInput.value).then(function () { location.reload(); });
		});

		poll.add(function () {
			return callList().then(function (devices) {
				var fresh = self.renderTable(devices);
				tableWrap.firstChild.replaceWith(fresh);
			});
		}, 15);

		return E('div', {}, [
			style,
			E('div', { 'style': 'display:flex;align-items:center;gap:12px' }, [
				E('h2', { 'style': 'margin:0' }, 'ESPtoPC Wireless Remote Switch'),
				(function () {
					var helpBtn = E('button', { 'class': 'cbi-button' }, 'Help');
					helpBtn.addEventListener('click', function () {
						window.alert(
							'How this works:\n\n' +
							'Each device is a small ESP-01 board wired to a PC\'s power/reset ' +
							'header, reachable over WiFi. It reports whether the PC is on/off and ' +
							'accepts power/reset commands.\n\n' +
							'For a device to show up and work here:\n' +
							'- The board must be powered and connected to this network\n' +
							'- It announces itself automatically once online (see the yellow box ' +
							'above the table, if present) - add it with a name to start using it\n' +
							'- If a device shows Offline, use "Check connection" - if that fails, ' +
							'the board itself is unreachable (power/WiFi on its end)\n\n' +
							'Full build instructions, firmware and hardware files:\n' +
							'https://github.com/steelpuxnastik/ESPtoPC_Wireless_Remote_Switch'
						);
					});
					return helpBtn;
				})()
			]),
			self.renderPending(pending, clients),
			tableWrap,
			E('div', { 'style': 'margin-top:1em' }, [picker, ' ', macInput, ' ', nameInput, ' ', addBtn])
		]);
	}
});
JS_EOF

if [ ! -f /etc/config/esptopcrsw ]; then
cat > /etc/config/esptopcrsw << 'CFG_EOF'
config settings 'settings'
	option password 'poweron-esp01'
	option offline_timeout '300'
	option power_block_after_on '60'
CFG_EOF
echo "Created /etc/config/esptopcrsw with defaults"
fi

/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true

mkdir -p /www-pcremote/cgi-bin
cat > /www-pcremote/cgi-bin/announce << 'ANNOUNCE_EOF'
#!/usr/bin/lua
-- Принимает POST {"mac":"...","password":"...","port":80} от ESP.
-- Пишет last_seen+port в /tmp (RAM) - не трогаем flash на каждый heartbeat.

local jsonc = require "luci.jsonc"
local uci = require "uci"

local function reply(code, status, text)
	print("Status: " .. code .. " " .. status)
	print("Content-Type: text/plain")
	print("")
	print(text)
end

local len = tonumber(os.getenv("CONTENT_LENGTH")) or 0
local body = len > 0 and io.read(len) or ""

local ok, data = pcall(jsonc.parse, body)
if not ok or type(data) ~= "table" or not data.mac or not data.password then
	reply(400, "Bad Request", "bad payload")
	return
end

local cursor = uci.cursor()
local expected_password = cursor:get("esptopcrsw", "settings", "password")

if data.password ~= expected_password then
	reply(403, "Forbidden", "bad password")
	return
end

local mac = string.upper(data.mac)
local port = tostring(data.port or 80)
local filename = "/tmp/esptopcrsw/" .. mac:gsub(":", "-") .. ".seen"

os.execute("mkdir -p /tmp/esptopcrsw")
local f = io.open(filename, "w")
if f then
	f:write(os.time() .. " " .. port)
	f:close()
end

reply(200, "OK", "welcome")
ANNOUNCE_EOF
chmod +x /www-pcremote/cgi-bin/announce

uci -q delete uhttpd.pcremote 2>/dev/null || true
uci set uhttpd.pcremote='uhttpd'
uci set uhttpd.pcremote.listen_http='0.0.0.0:8090'
uci set uhttpd.pcremote.home='/www-pcremote'
uci set uhttpd.pcremote.cgi_prefix='/cgi-bin'
uci commit uhttpd
/etc/init.d/uhttpd restart

echo ""
echo "Done. LuCI -> Services -> ESPtoPC Wireless Remote Switch (Ctrl+F5)"

# CLI-утилита
mkdir -p /usr/bin
cat > /usr/bin/esptopcrsw << 'CLI_EOF'
#!/bin/sh
# ESPtoPC Wireless Remote Switch - CLI
#
# Usage:
#   esptopcrsw                    interactive menu
#   esptopcrsw list                list devices with status
#   esptopcrsw poweron <name>      power on (or sleep, if PC already on)
#   esptopcrsw off <name>          force power off
#   esptopcrsw reset <name>
#   esptopcrsw check <name>        check connection to an offline device
#   esptopcrsw lang [en|ru|uk]     show or change CLI language

LANG_FILE="/etc/esptopcrsw-cli-lang"
LANG_CODE="$(cat "$LANG_FILE" 2>/dev/null)"
[ -z "$LANG_CODE" ] && LANG_CODE="en"

t() {
	case "$LANG_CODE:$1" in
		en:online) echo "Online" ;;                 ru:online) echo "В сети" ;;                  uk:online) echo "В мережі" ;;
		en:offline) echo "Offline" ;;                ru:offline) echo "Не на связи" ;;            uk:offline) echo "Не на зв'язку" ;;
		en:status_on) echo "On" ;;                   ru:status_on) echo "Включен" ;;              uk:status_on) echo "Увімкнено" ;;
		en:status_off) echo "Off" ;;                 ru:status_off) echo "Выключен" ;;            uk:status_off) echo "Вимкнено" ;;
		en:status_unknown) echo "Unknown" ;;         ru:status_unknown) echo "Неизвестно" ;;      uk:status_unknown) echo "Невідомо" ;;
		en:header_name) echo "Name" ;;               ru:header_name) echo "Имя" ;;                uk:header_name) echo "Ім'я" ;;
		en:header_mac) echo "MAC" ;;                 ru:header_mac) echo "MAC" ;;                 uk:header_mac) echo "MAC" ;;
		en:header_ip) echo "IP" ;;                   ru:header_ip) echo "IP" ;;                   uk:header_ip) echo "IP" ;;
		en:header_status) echo "Status" ;;           ru:header_status) echo "Статус" ;;           uk:header_status) echo "Статус" ;;
		en:prompt_pick_device) echo "Pick a device" ;;    ru:prompt_pick_device) echo "Выбери устройство" ;;    uk:prompt_pick_device) echo "Обери пристрій" ;;
		en:prompt_pick_action) echo "Pick an action for" ;; ru:prompt_pick_action) echo "Выбери действие для" ;; uk:prompt_pick_action) echo "Обери дію для" ;;
		en:action_check) echo "Check connection" ;;  ru:action_check) echo "Проверить связь" ;;   uk:action_check) echo "Перевірити зв'язок" ;;
		en:action_poweron) echo "Power On" ;;        ru:action_poweron) echo "Включить" ;;        uk:action_poweron) echo "Увімкнути" ;;
		en:action_poweron_sleep) echo "Off / Sleep" ;; ru:action_poweron_sleep) echo "Выключить / Сон" ;; uk:action_poweron_sleep) echo "Вимкнути / Сон" ;;
		en:action_off) echo "Force Off" ;;           ru:action_off) echo "Принудительно выключить" ;; uk:action_off) echo "Примусово вимкнути" ;;
		en:action_reset) echo "Reset" ;;             ru:action_reset) echo "Перезагрузить" ;;     uk:action_reset) echo "Перезавантажити" ;;
		en:action_back) echo "Back" ;;               ru:action_back) echo "Назад" ;;              uk:action_back) echo "Назад" ;;
		en:action_exit) echo "Exit" ;;               ru:action_exit) echo "Выход" ;;              uk:action_exit) echo "Вихід" ;;
		en:action_lang) echo "Change language (current: $LANG_CODE)" ;;
		ru:action_lang) echo "Сменить язык (сейчас: $LANG_CODE)" ;;
		uk:action_lang) echo "Змінити мову (зараз: $LANG_CODE)" ;;
		en:action_help) echo "Help" ;;           ru:action_help) echo "Справка" ;;            uk:action_help) echo "Довідка" ;;
		en:blocked) echo "blocked for now" ;;        ru:blocked) echo "пока заблокировано" ;;     uk:blocked) echo "поки заблоковано" ;;
		en:msg_reconnecting) echo "Device looks offline, trying to reconnect..." ;;
		ru:msg_reconnecting) echo "Устройство не на связи, пробую переподключиться..." ;;
		uk:msg_reconnecting) echo "Пристрій не на зв'язку, пробую перепідключитися..." ;;
		en:msg_connected) echo "Connected." ;;       ru:msg_connected) echo "Связь восстановлена." ;; uk:msg_connected) echo "Зв'язок відновлено." ;;
		en:msg_running) echo "Running" ;;            ru:msg_running) echo "Выполняю" ;;           uk:msg_running) echo "Виконую" ;;
		en:confirm_action) echo "Confirm" ;; ru:confirm_action) echo "Подтверди" ;; uk:confirm_action) echo "Підтверди" ;;
		en:msg_done) echo "Done." ;;                 ru:msg_done) echo "Готово." ;;               uk:msg_done) echo "Готово." ;;
		en:msg_error) echo "Error" ;;                ru:msg_error) echo "Ошибка" ;;               uk:msg_error) echo "Помилка" ;;
		en:msg_device_offline) echo "Device is offline, giving up" ;;
		ru:msg_device_offline) echo "Устройство не на связи, отменяю" ;;
		uk:msg_device_offline) echo "Пристрій не на зв'язку, скасовую" ;;
		en:msg_invalid_choice) echo "Invalid choice" ;; ru:msg_invalid_choice) echo "Неверный выбор" ;; uk:msg_invalid_choice) echo "Невірний вибір" ;;
		en:msg_not_found) echo "Device not found" ;; ru:msg_not_found) echo "Устройство не найдено" ;; uk:msg_not_found) echo "Пристрій не знайдено" ;;
		en:msg_no_devices) echo "No devices saved yet - add them via LuCI" ;;
		ru:msg_no_devices) echo "Пока нет сохранённых устройств - добавь через LuCI" ;;
		uk:msg_no_devices) echo "Поки немає збережених пристроїв - додай через LuCI" ;;
		en:prompt_lang) echo "Choose language: 1) English  2) Русский  3) Українська" ;;
		ru:prompt_lang) echo "Выбери язык: 1) English  2) Русский  3) Українська" ;;
		uk:prompt_lang) echo "Обери мову: 1) English  2) Русский  3) Українська" ;;
		*) echo "$1" ;;
	esac
}

status_label() {
	if [ "$1" != "true" ]; then
		t offline
	elif [ "$2" = "on" ]; then
		t status_on
	elif [ "$2" = "off" ]; then
		t status_off
	else
		t status_unknown
	fi
}

list_devices() {
	local raw count i mac name online status blocked ip
	raw="$(ubus call esptopcrsw list '{}' 2>/dev/null)"
	[ -z "$raw" ] && return
	count="$(echo "$raw" | jsonfilter -e '$.devices[*].mac' | wc -l)"
	i=0
	while [ "$i" -lt "$count" ]; do
		mac="$(echo "$raw" | jsonfilter -e "\$.devices[$i].mac")"
		name="$(echo "$raw" | jsonfilter -e "\$.devices[$i].name")"
		online="$(echo "$raw" | jsonfilter -e "\$.devices[$i].online")"
		status="$(echo "$raw" | jsonfilter -e "\$.devices[$i].pc_status")"
		blocked="$(echo "$raw" | jsonfilter -e "\$.devices[$i].power_blocked")"
		ip="$(echo "$raw" | jsonfilter -e "\$.devices[$i].ip")"
		echo "$mac|$name|$online|$status|$blocked|$ip"
		i=$((i + 1))
	done
}

find_device_line() {
	local wanted lower_wanted
	wanted="$1"
	lower_wanted="$(echo "$wanted" | tr 'A-Z' 'a-z')"
	list_devices | while IFS='|' read -r mac dname online status blocked ip; do
		lname="$(echo "$dname" | tr 'A-Z' 'a-z')"
		lmac="$(echo "$mac" | tr 'A-Z' 'a-z')"
		lmac="$(echo "$mac" | tr '[:upper:]' '[:lower:]')"
		if [ "$lname" = "$lower_wanted" ] || [ "$lmac" = "$lower_wanted" ]; then
			echo "$mac|$dname|$online|$status|$blocked|$ip"
			break
		fi
	done
}
action_label() {
	case "$1" in
		power_on) t action_poweron ;;
		power_off) t action_off ;;
		reset) t action_reset ;;
		*) echo "$1" ;;
	esac
}
run_action_by_mac() {
	local mac="$1" dname="$2" online="$3" action="$4" res err

	if [ "$online" != "true" ]; then
		echo "$(t msg_reconnecting)"
		res="$(ubus call esptopcrsw command "{\"mac\":\"$mac\",\"action\":\"check\"}" 2>/dev/null)"
		if echo "$res" | grep -q '"ok":true'; then
			echo "$(t msg_connected)"
		else
			echo "$(t msg_device_offline): $dname"
			return 1
		fi
	fi

	[ "$action" = "check" ] && return 0

	printf "%s: %s -> %s? [y/N] " "$(t confirm_action)" "$dname" "$(action_label "$action")"
	read confirm
	case "$confirm" in
		y|Y|yes|Yes) ;;
		*) return 1 ;;
	esac

	echo "$(t msg_running) ($action)..."
	res="$(ubus call esptopcrsw command "{\"mac\":\"$mac\",\"action\":\"$action\"}" 2>/dev/null)"
	if echo "$res" | grep -q '"ok":true'; then
		echo "$(t msg_done)"
	else
		err="$(echo "$res" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')"
		echo "$(t msg_error): ${err:-?}"
		return 1
	fi
}

run_action() {
	local line
	line="$(find_device_line "$1")"
	if [ -z "$line" ]; then
		echo "$(t msg_not_found): $1"
		return 1
	fi
	run_action_by_mac "$(echo "$line" | cut -d'|' -f1)" "$(echo "$line" | cut -d'|' -f2)" \
		"$(echo "$line" | cut -d'|' -f3)" "$2"
}

cmd_list() {
	local any=0
	printf "%-16s %-18s %-15s %-10s\n" "$(t header_name)" "$(t header_mac)" "$(t header_ip)" "$(t header_status)"
	list_devices | while IFS='|' read -r mac dname online status blocked ip; do
		printf "%-16s %-18s %-15s %-10s\n" "$dname" "$mac" "$ip" "$(status_label "$online" "$status")"
		any=1
	done
	[ "$any" = "0" ] && echo "$(t msg_no_devices)"
}

cmd_lang() {
	if [ -n "$1" ]; then
		case "$1" in
			en|ru|uk) echo "$1" > "$LANG_FILE"; LANG_CODE="$1"; echo "Language: $1" ;;
			*) echo "Unknown language: $1 (use: en / ru / uk)" ;;
		esac
	else
		echo "$(t prompt_lang)"
		printf "> "
		read c
		case "$c" in
			1) echo en > "$LANG_FILE"; LANG_CODE="en" ;;
			2) echo ru > "$LANG_FILE"; LANG_CODE="ru" ;;
			3) echo uk > "$LANG_FILE"; LANG_CODE="uk" ;;
		esac
	fi
}

cmd_menu() {
	local tmp i choice line mac dname online status blocked j actions achoice action
	while true; do
		tmp="$(mktemp)"
		list_devices > "$tmp"
		echo ""
		echo "$(t prompt_pick_device):"
		i=1
		if [ -s "$tmp" ]; then
			while IFS='|' read -r mac dname online status blocked ip; do
				echo "  $i) $dname [$(status_label "$online" "$status")]"
				i=$((i + 1))
			done < "$tmp"
		else
			echo "  $(t msg_no_devices)"
		fi
		echo "  L) $(t action_lang)"
		echo "  H) $(t action_help)"
		echo "  0) $(t action_exit)"
		printf "> "
		read choice
		if [ "$choice" = "0" ]; then
			rm -f "$tmp"
			break
		fi
		if [ "$choice" = "L" ] || [ "$choice" = "l" ]; then
			cmd_lang
			rm -f "$tmp"
			continue
		fi
		if [ "$choice" = "H" ] || [ "$choice" = "h" ]; then
			cmd_help
			rm -f "$tmp"
			continue
		fi
		line="$(sed -n "${choice}p" "$tmp")"
		rm -f "$tmp"
		if [ -z "$line" ]; then
			echo "$(t msg_invalid_choice)"
			continue
		fi
		mac="$(echo "$line" | cut -d'|' -f1)"
		dname="$(echo "$line" | cut -d'|' -f2)"
		online="$(echo "$line" | cut -d'|' -f3)"
		status="$(echo "$line" | cut -d'|' -f4)"
		blocked="$(echo "$line" | cut -d'|' -f5)"

		echo ""
		echo "$(t prompt_pick_action) [$dname]:"
		actions=""
		if [ "$online" != "true" ]; then
			echo "  1) $(t action_check)"
			actions="check"
		elif [ "$status" = "off" ]; then
			echo "  1) $(t action_poweron)"
			actions="power_on"
		elif [ "$status" = "on" ]; then
			if [ "$blocked" = "true" ]; then
				echo "  1) $(t action_poweron_sleep) ($(t blocked))"
			else
				echo "  1) $(t action_poweron_sleep)"
			fi
			echo "  2) $(t action_off)"
			echo "  3) $(t action_reset)"
			actions="power_on power_off reset"
		fi
		echo "  0) $(t action_back)"
		printf "> "
		read achoice
		[ "$achoice" = "0" ] && continue
		action="$(echo "$actions" | cut -d' ' -f"$achoice")"
		if [ -z "$action" ]; then
			echo "$(t msg_invalid_choice)"
			continue
		fi
		run_action_by_mac "$mac" "$dname" "$online" "$action"
	done
}

cmd_help() {
	case "$LANG_CODE" in
		ru)
			cat << 'HELP_RU'
ESPtoPC Wireless Remote Switch - CLI

  esptopcrsw                     интерактивное меню (устройство -> действие)
  esptopcrsw list                 таблица устройств с текущим статусом
  esptopcrsw poweron <имя>        включить (или усыпить, если ПК уже включен)
  esptopcrsw off <имя>            принудительно выключить
  esptopcrsw reset <имя>          перезагрузить
  esptopcrsw check <имя>          проверить/восстановить связь с устройством
  esptopcrsw lang [en|ru|uk]      показать или сменить язык интерфейса
  esptopcrsw help                 эта справка

<имя> - как задано в LuCI при добавлении устройства (или сам MAC-адрес).
poweron/off/reset спрашивают подтверждение (y/N), прежде чем что-либо делать.
HELP_RU
			;;
		uk)
			cat << 'HELP_UK'
ESPtoPC Wireless Remote Switch - CLI

  esptopcrsw                     інтерактивне меню (пристрій -> дія)
  esptopcrsw list                 таблиця пристроїв з поточним статусом
  esptopcrsw poweron <ім'я>       увімкнути (або приспати, якщо ПК вже увімкнено)
  esptopcrsw off <ім'я>           примусово вимкнути
  esptopcrsw reset <ім'я>         перезавантажити
  esptopcrsw check <ім'я>         перевірити/відновити зв'язок з пристроєм
  esptopcrsw lang [en|ru|uk]      показати або змінити мову інтерфейсу
  esptopcrsw help                 ця довідка

<ім'я> - як задано в LuCI при додаванні пристрою (або сам MAC-адреса).
poweron/off/reset питають підтвердження (y/N), перш ніж щось робити.
HELP_UK
			;;
		*)
			cat << 'HELP_EN'
ESPtoPC Wireless Remote Switch - CLI

  esptopcrsw                     interactive menu (pick device, then action)
  esptopcrsw list                 table of devices with live status
  esptopcrsw poweron <name>       power on (or sleep, if PC already on)
  esptopcrsw off <name>           force power off
  esptopcrsw reset <name>         reset
  esptopcrsw check <name>         check/restore connection to a device
  esptopcrsw lang [en|ru|uk]      show or change interface language
  esptopcrsw help                 this text

<name> is whatever you named the device in LuCI (or its MAC address).
poweron/off/reset ask for a y/N confirmation before doing anything.
HELP_EN
			;;
	esac
}

case "$1" in
	list) cmd_list ;;
	poweron) run_action "$2" power_on ;;
	off) run_action "$2" power_off ;;
	reset) run_action "$2" reset ;;
	check) run_action "$2" check ;;
	lang) shift; cmd_lang "$@" ;;
	help|-h|--help) cmd_help ;;
	"") cmd_menu ;;
	*)
		echo "Unknown command: $1"
		cmd_help
		;;
esac
CLI_EOF
chmod +x /usr/bin/esptopcrsw
[ -f /etc/esptopcrsw-cli-lang ] || echo en > /etc/esptopcrsw-cli-lang

echo "CLI installed: esptopcrsw"

# Проверка наличия jsonfilter, которым пользуется CLI
if ! command -v jsonfilter >/dev/null 2>&1; then
	echo "WARNING: jsonfilter not found - CLI list/poweron/etc will not work. Check: opkg list-installed | grep libubox / jsonfilter"
fi
