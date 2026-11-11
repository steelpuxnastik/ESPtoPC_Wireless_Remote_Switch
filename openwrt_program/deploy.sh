#!/bin/sh
# ESPtoPC Wireless Remote Switch - install/update on OpenWrt. Run: sh deploy.sh
#
# Installs, in this order:
#   1. LuCI menu entry + rpcd ACL
#   2. rpcd backend       /usr/libexec/rpcd/esptopcrsw   (ubus object "esptopcrsw")
#   3. LuCI view          /www/luci-static/resources/view/esptopcrsw.js
#   4. UCI defaults       /etc/config/esptopcrsw
#   5. announce CGI       /www-esptopcrsw/cgi-bin/announce  (uhttpd on :8090, receives ESP heartbeats)
#   6. CLI                /usr/bin/esptopcrsw
set -e

mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd /www/luci-static/resources/view

# ---------------------------------------------------------------- 1. menu + ACL

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
			"ubus": { "esptopcrsw": [ "list", "dhcp_clients", "pending_devices", "dismiss_pending", "add_device", "rename_device", "remove_device", "command" ] },
			"uci": [ "esptopcrsw" ]
		}
	}
}
ACL_EOF

# ---------------------------------------------------------------- 2. rpcd backend

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

# ------------------------------------------------------------------ helpers

now()   { date +%s; }
upper() { echo "$1" | tr 'a-z' 'A-Z'; }

# JSON in/out
read_args() { json_load "$(cat)"; }
fail()      { echo "{\"error\":\"$1\"}"; return 1; }
reply_ok()  { json_init; json_add_boolean "ok" 1; json_dump; }

# UCI "settings" section (call config_load first): setting NAME DEFAULT
setting() { local v; config_get v settings "$1" "$2"; echo "$v"; }

# ------------------------------------------------------------------ per-device state (RAM)

mac_key()      { upper "$1" | tr ':' '-'; }
seen_file()    { echo "$STATE_DIR/$(mac_key "$1").seen"; }
status_file()  { echo "$STATE_DIR/$(mac_key "$1").status"; }
onsince_file() { echo "$STATE_DIR/$(mac_key "$1").onsince"; }

# within FILE SECONDS: true if the timestamp stored in FILE is younger than SECONDS
within() {
	local ts
	ts="$(awk '{print $1}' "$1" 2>/dev/null)"
	[ -n "$ts" ] && [ "$(($(now) - ts))" -lt "$2" ]
}

is_online()        { within "$(seen_file "$1")" "$2"; }
is_power_blocked() { within "$(onsince_file "$1")" "$2"; }

device_port() {
	local f; f="$(seen_file "$1")"
	if [ -f "$f" ]; then
		awk '{print $2}' "$f"
	else
		echo "80"
	fi
}

# Mark the device as just seen (keeps its known port).
touch_seen() {
	local port; port="$(device_port "$1")"
	echo "$(now) $port" > "$(seen_file "$1")"
}

# Remember the last known PC state; start the power-button lockout on an off -> on transition.
update_status_cache() {
	local mac="$1" status="$2" prev f
	[ "$status" = "unknown" ] && return 0
	f="$(status_file "$mac")"
	prev="$(cat "$f" 2>/dev/null)"
	echo "$status" > "$f"
	if [ "$status" = "on" ] && [ "$prev" = "off" ]; then
		now > "$(onsince_file "$mac")"
	fi
	if [ "$status" != "on" ]; then
		rm -f "$(onsince_file "$mac")"
	fi
}

# ------------------------------------------------------------------ talking to the ESP

command_key() {
	local password
	config_get password settings password
	echo -n "$(upper "$1"):${password}" | md5sum | cut -c1-12
}

resolve_ip() {
	local mac_lower
	mac_lower="$(echo "$1" | tr 'A-Z' 'a-z')"
	awk -v m="$mac_lower" 'tolower($2)==m {print $3}' /tmp/dhcp.leases 2>/dev/null | tail -n1
}

# device_get MAC PATH TIMEOUT: GET http://<device>PATH, prints the body (empty on failure)
device_get() {
	local ip
	ip="$(resolve_ip "$1")"
	[ -n "$ip" ] || return 1
	uclient-fetch -q -T "$3" -O - "http://$ip:$(device_port "$1")$2?key=$(command_key "$1")" 2>/dev/null
}

# fetch_status MAC [TIMEOUT=3] [TRIES=1] -> on | off | unknown
fetch_status() {
	local mac="$1" tmo="${2:-3}" tries="${3:-1}" body
	[ -n "$(resolve_ip "$mac")" ] || { echo "unknown"; return; }
	while [ "$tries" -gt 0 ]; do
		body="$(device_get "$mac" /status "$tmo")"
		case "$body" in
			*'"pc_status":"on"'*)  echo "on"; return ;;
			*'"pc_status":"off"'*) echo "off"; return ;;
		esac
		tries=$((tries - 1))
		[ "$tries" -gt 0 ] && sleep 1
	done
	echo "unknown"
}

# ------------------------------------------------------------------ UCI devices

find_section_by_mac() {
	local wanted
	wanted="$(upper "$1")"
	FOUND_SECTION=""
	find_one() {
		local m
		config_get m "$1" mac
		[ "$(upper "$m")" = "$wanted" ] && FOUND_SECTION="$1"
	}
	config_foreach find_one device
}

# ------------------------------------------------------------------ rpc methods

# decl METHOD [ARG...]: describe one method and its string arguments
decl() {
	json_add_object "$1"
	shift
	local arg
	for arg in "$@"; do json_add_string "$arg" ""; done
	json_close_object
}

rpc_list() {
	json_init
	decl list
	decl dhcp_clients
	decl pending_devices
	decl dismiss_pending mac
	decl add_device mac name
	decl rename_device mac name
	decl remove_device mac
	decl command mac action
	json_dump
}

call_list() {
	local timeout window
	config_load esptopcrsw
	timeout="$(setting offline_timeout 300)"
	window="$(setting power_block_after_on 60)"

	json_init
	json_add_array "devices"

	list_one() {
		local section="$1" mac name ip status online=0 blocked=0
		config_get mac "$section" mac
		config_get name "$section" name
		[ -z "$mac" ] && return

		ip="$(resolve_ip "$mac")"
		if is_online "$mac" "$timeout"; then
			online=1
			status="$(fetch_status "$mac" 2 2)"
		else
			# No heartbeat lately: one quick direct probe (1 s). An answer means it is online.
			status="$(fetch_status "$mac" 1)"
			if [ "$status" != "unknown" ]; then
				online=1
				touch_seen "$mac"
			fi
		fi
		if [ "$online" = 1 ]; then
			update_status_cache "$mac" "$status"
			is_power_blocked "$mac" "$window" && blocked=1
		fi

		json_add_object ""
		json_add_string "mac" "$mac"
		json_add_string "name" "$name"
		json_add_string "ip" "${ip:-}"
		json_add_boolean "online" "$online"
		json_add_string "pc_status" "$status"
		json_add_boolean "power_blocked" "$blocked"
		json_close_object
	}
	config_foreach list_one device

	json_close_array
	json_dump
}

call_dhcp_clients() {
	local exp mac ip host cid
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

# Boards that announced themselves but are not saved in UCI yet.
call_pending_devices() {
	local f mac ip last_seen
	config_load esptopcrsw
	json_init
	json_add_array "pending"

	for f in "$STATE_DIR"/*.seen; do
		[ -e "$f" ] || continue
		mac="$(basename "$f" .seen | tr '-' ':')"

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

call_dismiss_pending() {
	local mac
	read_args
	json_get_var mac mac
	case "$mac" in
		*[!0-9A-Fa-f:]*|"") fail "bad mac"; return 1 ;;
	esac
	rm -f "$(seen_file "$mac")" "$(status_file "$mac")" "$(onsince_file "$mac")"
	reply_ok
}

call_add_device() {
	local mac name
	read_args
	json_get_var mac mac
	json_get_var name name
	[ -n "$mac" ] || { fail "mac required"; return 1; }
	mac="$(upper "$mac")"

	config_load esptopcrsw
	find_section_by_mac "$mac"
	[ -n "$FOUND_SECTION" ] || FOUND_SECTION="$(uci add esptopcrsw device)"
	uci set "esptopcrsw.$FOUND_SECTION.mac=$mac"
	uci set "esptopcrsw.$FOUND_SECTION.name=$name"
	uci commit esptopcrsw
	reply_ok
}

call_rename_device() { call_add_device; }

call_remove_device() {
	local mac
	read_args
	json_get_var mac mac
	[ -n "$mac" ] || { fail "mac required"; return 1; }

	config_load esptopcrsw
	find_section_by_mac "$mac"
	[ -n "$FOUND_SECTION" ] && uci delete "esptopcrsw.$FOUND_SECTION"
	uci commit esptopcrsw
	reply_ok
}

call_command() {
	local mac action timeout window status url resp

	read_args
	json_get_var mac mac
	json_get_var action action
	[ -n "$mac" ] && [ -n "$action" ] || { fail "mac and action required"; return 1; }

	config_load esptopcrsw
	timeout="$(setting offline_timeout 300)"
	window="$(setting power_block_after_on 60)"

	# "check": try to reach the board right now; success also marks it online
	if [ "$action" = "check" ]; then
		[ -n "$(resolve_ip "$mac")" ] || { fail "device not found in DHCP leases"; return 1; }
		status="$(fetch_status "$mac" 2 2)"
		[ "$status" != "unknown" ] || { fail "device not responding"; return 1; }
		touch_seen "$mac"
		update_status_cache "$mac" "$status"
		json_init
		json_add_boolean "ok" 1
		json_add_string "pc_status" "$status"
		json_dump
		return 0
	fi

	is_online "$mac" "$timeout" || { fail "device offline"; return 1; }

	status="$(fetch_status "$mac" 2 2)"
	[ "$status" != "unknown" ] || { fail "status unknown, try again"; return 1; }
	update_status_cache "$mac" "$status"

	case "$action" in
		power_on)
			if [ "$status" = "on" ] && is_power_blocked "$mac" "$window"; then
				fail "power button blocked for a bit after turning on"; return 1
			fi
			url="/power/on"
			;;
		power_off)
			[ "$status" = "on" ] || { fail "PC is already off"; return 1; }
			url="/power/off"
			;;
		reset)
			[ "$status" = "on" ] || { fail "PC is off, nothing to reset"; return 1; }
			url="/reset"
			;;
		*)
			fail "unknown action"; return 1
			;;
	esac

	# power_off holds the button for 5 s and replies afterwards -> 10 s timeout
	resp="$(device_get "$mac" "$url" 10)"
	[ -n "$resp" ] || { fail "device did not confirm the command"; return 1; }

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
			list)            call_list ;;
			dhcp_clients)    call_dhcp_clients ;;
			pending_devices) call_pending_devices ;;
			dismiss_pending) call_dismiss_pending ;;
			add_device)      call_add_device ;;
			rename_device)   call_rename_device ;;
			remove_device)   call_remove_device ;;
			command)         call_command ;;
			*) fail "method not found"; exit 1 ;;
		esac
		;;
esac
RPCD_EOF
chmod 0755 /usr/libexec/rpcd/esptopcrsw

# ---------------------------------------------------------------- 3. LuCI view

cat > /www/luci-static/resources/view/esptopcrsw.js << 'JS_EOF'
'use strict';
'require view';
'require poll';
'require rpc';

// UI text is hard-coded in English on purpose (not wrapped in _()), so LuCI
// does not swap it for a translation depending on the interface language.

var COLUMNS = ['Name', 'MAC / IP', 'Status', 'Commands', 'Manage'];

var HELP_TEXT =
	'How this works:\n\n' +
	'Each device is a small ESP-01 board wired to a PC\'s power/reset ' +
	'header, reachable over WiFi. It reports whether the PC is on/off and ' +
	'accepts power/reset commands.\n\n' +
	'For a device to show up and work here:\n' +
	'- The board must be properly wired to PC, powered and connected to this network\n' +
	'- It announces itself automatically once online (see the yellow box ' +
	'above the table, if present) - add it with a name to start using it\n' +
	'- If a device shows Offline, use "Check connection" - if that fails, ' +
	'the board itself is unreachable (power/WiFi on its end)\n\n' +
	'Full build instructions, firmware and hardware files:\n' +
	'https://github.com/steelpuxnastik/ESPtoPC_Wireless_Remote_Switch';

var STYLE = [
	'#esptopcrsw-table { border-collapse: collapse; width: 100%; }',
	'#esptopcrsw-table th, #esptopcrsw-table td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }',
	// phone: a table row becomes a card, the column name comes from the cell's data-title
	'@media (max-width: 700px) {',
	'  #esptopcrsw-table .tr-table-title { display: none; }',
	'  #esptopcrsw-table, #esptopcrsw-table tr, #esptopcrsw-table td { display: block; width: 100%; box-sizing: border-box; }',
	'  #esptopcrsw-table tr { margin-bottom: 12px; border: 1px solid #ccc; }',
	'  #esptopcrsw-table td { border: none; border-bottom: 1px solid #ddd; }',
	'  #esptopcrsw-table td::before { content: attr(data-title); display: block; font-size: 0.8em; opacity: 0.7; }',
	'}'
].join('\n');

function declare(method, params, expect) {
	var opts = { object: 'esptopcrsw', method: method };
	if (params) opts.params = params;
	if (expect) opts.expect = expect;
	return rpc.declare(opts);
}

var callList        = declare('list', null, { devices: [] });
var callDhcpClients = declare('dhcp_clients', null, { clients: [] });
var callPending     = declare('pending_devices', null, { pending: [] });
var callDismiss     = declare('dismiss_pending', ['mac']);
var callAdd         = declare('add_device', ['mac', 'name']);
var callRename      = declare('rename_device', ['mac', 'name']);
var callRemove      = declare('remove_device', ['mac']);
var callCommand     = declare('command', ['mac', 'action']);

function reload() { location.reload(); }

function button(label, cls, title, onClick) {
	var attrs = { 'class': 'cbi-button' + (cls ? ' ' + cls : '') };
	if (title) attrs.title = title;
	var btn = E('button', attrs, label);
	btn.addEventListener('click', onClick);
	return btn;
}

return view.extend({
	load: function () {
		return Promise.all([callList(), callDhcpClients(), callPending()]);
	},

	runCommand: function (mac, action, btn) {
		var self = this;
		var oldText = btn.textContent;
		btn.disabled = true;
		btn.textContent = 'Working...';
		callCommand(mac, action).then(function (res) {
			if (res && res.error) window.alert(res.error);
		}).catch(function (err) {
			window.alert(err.message || String(err));
		}).finally(function () {
			btn.disabled = false;
			btn.textContent = oldText;
			// the PC state changes with a delay: refresh now and twice more
			[500, 3000, 8000].forEach(function (ms) {
				setTimeout(function () { self.refreshTable(); }, ms);
			});
		});
	},

	renderStatus: function (dev) {
		var label = 'Unknown', color = '#999';
		if (!dev.online) {
			label = 'Offline';
		} else if (dev.pc_status === 'on') {
			label = 'On'; color = 'green';
		} else if (dev.pc_status === 'off') {
			label = 'Off'; color = 'red';
		}
		return E('span', { 'style': 'color:' + color + ';font-weight:bold' }, label);
	},

	renderActions: function (dev) {
		var self = this;

		// click handler: optional confirmation, then run the action on the clicked button
		function send(action, question) {
			return function (ev) {
				if (!question || window.confirm(question)) self.runCommand(dev.mac, action, ev.currentTarget);
			};
		}

		if (!dev.online) {
			return [button('Check connection', '', 'Try to reach this device right now and refresh its status', send('check'))];
		}

		if (dev.pc_status === 'off') {
			return [button('Power On', 'cbi-button-apply', 'Short press of the power button - turns the PC on',
				send('power_on', 'Power on ' + (dev.name || dev.mac) + '?'))];
		}

		if (dev.pc_status === 'on') {
			var sleepBtn = button('Off / Sleep', '',
				'Short press of the power button while PC is on - result depends on PC power settings (sleep or shutdown)',
				send('power_on'));
			if (dev.power_blocked) {
				sleepBtn.disabled = true;
				sleepBtn.title = 'Blocked for a bit right after power-on';
			}
			return [
				sleepBtn, ' ',
				button('Force Off', 'cbi-button-reset', 'Long press of the power button - forces the PC off regardless of OS state',
					send('power_off', 'Force power off the PC?')), ' ',
				button('Reset', '', 'Short press of the reset button', send('reset', 'Reset the PC?'))
			];
		}

		return [E('span', {}, '-')];
	},

	renderManage: function (dev) {
		return [
			button('Rename', '', '', function () {
				var newName = window.prompt('New name', dev.name);
				if (newName) callRename(dev.mac, newName).then(reload);
			}), ' ',
			button('Remove', 'cbi-button-remove', '', function () {
				if (window.confirm('Remove this device?')) callRemove(dev.mac).then(reload);
			})
		];
	},

	renderRow: function (dev) {
		var cells = [
			dev.name || dev.mac,
			[
				E('div', {}, dev.mac),
				dev.ip ? E('div', { 'style': 'color:#888;font-size:0.9em' }, dev.ip) : ''
			],
			this.renderStatus(dev),
			this.renderActions(dev),
			this.renderManage(dev)
		];
		return E('tr', {}, cells.map(function (content, i) {
			return E('td', { 'data-title': COLUMNS[i] }, content);
		}));
	},

	renderTable: function (devices) {
		var self = this;
		var table = E('table', { 'class': 'table', 'id': 'esptopcrsw-table' }, [
			E('tr', { 'class': 'tr-table-title' }, COLUMNS.map(function (name) {
				return E('th', {}, name);
			}))
		]);
		(devices || []).forEach(function (dev) { table.appendChild(self.renderRow(dev)); });
		return table;
	},

	// Yellow box: boards that announced themselves but are not saved yet.
	renderPending: function (pending, clients) {
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
			box.appendChild(E('div', { 'style': 'margin-top:6px' }, [
				p.mac + (p.ip ? ' (' + p.ip + ')' : '') + '  ',
				nameInput, ' ',
				button('Add', 'cbi-button-add', '', function () {
					callAdd(p.mac, nameInput.value).then(reload);
				}), ' ',
				button('Dismiss', '', 'Hide this until the board announces itself again', function () {
					callDismiss(p.mac).then(reload);
				})
			]));
		});

		return box;
	},

	// Manual add: pick a client from the DHCP list or type a MAC.
	renderAddForm: function (clients) {
		var macInput = E('input', { 'type': 'text', 'placeholder': 'AA:BB:CC:DD:EE:FF' });
		var nameInput = E('input', { 'type': 'text', 'placeholder': 'Name' });

		var picker = E('select', {});
		picker.appendChild(E('option', { 'value': '' }, '-- pick from network --'));
		(clients || []).forEach(function (c) {
			var hostname = (c.hostname && c.hostname !== '*') ? c.hostname : '';
			var opt = E('option', { 'value': c.mac }, (hostname || c.ip) + ' (' + c.mac + ', ' + c.ip + ')');
			opt.setAttribute('data-hostname', hostname);
			picker.appendChild(opt);
		});
		picker.addEventListener('change', function () {
			if (!picker.value) return;
			macInput.value = picker.value;
			var hostname = picker.options[picker.selectedIndex].getAttribute('data-hostname');
			if (hostname && !nameInput.value) nameInput.value = hostname;
		});

		var addBtn = button('Add device', 'cbi-button-add', '', function () {
			if (macInput.value) callAdd(macInput.value, nameInput.value).then(reload);
		});

		return E('div', { 'style': 'margin-top:1em' }, [picker, ' ', macInput, ' ', nameInput, ' ', addBtn]);
	},

	render: function (data) {
		var self = this;
		var tableWrap = E('div', {}, [self.renderTable(data[0])]);

		self.refreshTable = function () {
			return callList().then(function (devices) {
				tableWrap.firstChild.replaceWith(self.renderTable(devices));
			});
		};
		poll.add(self.refreshTable, 15);

		return E('div', {}, [
			E('style', {}, STYLE),
			E('div', { 'style': 'display:flex;align-items:center;gap:12px' }, [
				E('h2', { 'style': 'margin:0' }, 'ESPtoPC Wireless Remote Switch'),
				button('Help', '', '', function () { window.alert(HELP_TEXT); })
			]),
			self.renderPending(data[2], data[1]),
			tableWrap,
			self.renderAddForm(data[1])
		]);
	}
});
JS_EOF

# ---------------------------------------------------------------- 4. UCI defaults + rpcd restart

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
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/*

# ---------------------------------------------------------------- 5. announce CGI

mkdir -p /www-esptopcrsw/cgi-bin
cat > /www-esptopcrsw/cgi-bin/announce << 'ANNOUNCE_EOF'
#!/bin/sh
# Receives POST {"mac":"...","password":"...","port":80} from the ESP (handshake + heartbeat).
# Writes last_seen+port to /tmp (RAM), so flash is not touched on every heartbeat.
# Plain sh + jshn + uci on purpose: the Lua "uci" module is not installed on OpenWrt 25.x.
. /usr/share/libubox/jshn.sh

reply() { printf 'Status: %s\r\nContent-Type: text/plain\r\n\r\n%s\n' "$1" "$2"; }

len="${CONTENT_LENGTH:-0}"
case "$len" in ''|*[!0-9]*) len=0 ;; esac
if [ "$len" -le 0 ] || [ "$len" -ge 1024 ]; then reply "400 Bad Request" "bad payload"; exit 0; fi
body="$(dd bs=1 count="$len" 2>/dev/null)"

json_load "$body" 2>/dev/null
json_get_var mac mac
json_get_var password password
json_get_var port port
if [ -z "$mac" ] || [ -z "$password" ]; then reply "400 Bad Request" "bad payload"; exit 0; fi

if [ "$password" != "$(uci -q get esptopcrsw.settings.password)" ]; then
	reply "403 Forbidden" "bad password"; exit 0
fi

mac="$(echo "$mac" | tr 'a-z' 'A-Z')"
if ! echo "$mac" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'; then
	reply "400 Bad Request" "bad mac"; exit 0
fi
case "$port" in ''|*[!0-9]*) port=80 ;; esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=80; fi

mkdir -p /tmp/esptopcrsw
echo "$(date +%s) $port" > "/tmp/esptopcrsw/$(echo "$mac" | tr ':' '-').seen"
reply "200 OK" "welcome"
ANNOUNCE_EOF
chmod +x /www-esptopcrsw/cgi-bin/announce

# Second uhttpd instance on :8090 serving only the announce CGI.
uci -q delete uhttpd.esptopcrsw || true
uci set uhttpd.esptopcrsw='uhttpd'
uci set uhttpd.esptopcrsw.listen_http='0.0.0.0:8090'
uci set uhttpd.esptopcrsw.home='/www-esptopcrsw'
uci set uhttpd.esptopcrsw.cgi_prefix='/cgi-bin'
uci commit uhttpd
/etc/init.d/uhttpd restart

# ---------------------------------------------------------------- 6. CLI

mkdir -p /usr/bin
cat > /usr/bin/esptopcrsw << 'CLI_EOF'
#!/bin/sh
# ESPtoPC Wireless Remote Switch - CLI
#
# Usage:
#   esptopcrsw                     interactive menu (Enter = refresh)
#   esptopcrsw list                list devices with status
#   esptopcrsw poweron <name>      power on (or sleep, if PC already on)
#   esptopcrsw off <name>          force power off
#   esptopcrsw reset <name>
#   esptopcrsw check <name>        check connection to an offline device
#   esptopcrsw lang [en|ru|uk]     show or change CLI language

LANG_FILE="/etc/esptopcrsw-cli-lang"
LANG_CODE="$(cat "$LANG_FILE" 2>/dev/null)"
[ -z "$LANG_CODE" ] && LANG_CODE="en"

# ------------------------------------------------------------------ texts
# One row per message: key|English|Русский|Українська   (@LANG@ = current language code)

texts() {
	cat << 'TEXTS_EOF'
online|Online|В сети|В мережі
offline|Offline|Не на связи|Не на зв'язку
status_on|On|Включен|Увімкнено
status_off|Off|Выключен|Вимкнено
status_unknown|Unknown|Неизвестно|Невідомо
header_name|Name|Имя|Ім'я
header_mac|MAC|MAC|MAC
header_ip|IP|IP|IP
header_status|Status|Статус|Статус
prompt_pick_device|Pick a device|Выбери устройство|Обери пристрій
prompt_pick_action|Pick an action for|Выбери действие для|Обери дію для
prompt_lang|Choose language: 1) English  2) Русский  3) Українська|Выбери язык: 1) English  2) Русский  3) Українська|Обери мову: 1) English  2) Русский  3) Українська
action_check|Check connection|Проверить связь|Перевірити зв'язок
action_poweron|Power On|Включить|Увімкнути
action_poweron_sleep|Off / Sleep|Выключить / Сон|Вимкнути / Сон
action_off|Force Off|Принудительно выключить|Примусово вимкнути
action_reset|Reset|Перезагрузить|Перезавантажити
action_back|Back|Назад|Назад
action_refresh|Refresh|Обновить|Оновити
action_exit|Exit|Выход|Вихід
action_lang|Change language (current: @LANG@)|Сменить язык (сейчас: @LANG@)|Змінити мову (зараз: @LANG@)
action_help|Help|Справка|Довідка
blocked|blocked for now|пока заблокировано|поки заблоковано
msg_reconnecting|Device looks offline, trying to reconnect...|Устройство не на связи, пробую переподключиться...|Пристрій не на зв'язку, пробую перепідключитися...
msg_connected|Connected.|Связь восстановлена.|Зв'язок відновлено.
msg_running|Running|Выполняю|Виконую
confirm_action|Confirm|Подтверди|Підтверди
msg_done|Done.|Готово.|Готово.
msg_error|Error|Ошибка|Помилка
msg_device_offline|Device is offline, giving up|Устройство не на связи, отменяю|Пристрій не на зв'язку, скасовую
msg_invalid_choice|Invalid choice|Неверный выбор|Невірний вибір
msg_not_found|Device not found|Устройство не найдено|Пристрій не знайдено
msg_no_devices|No devices saved yet - add them via LuCI|Пока нет сохранённых устройств - добавь через LuCI|Поки немає збережених пристроїв - додай через LuCI
TEXTS_EOF
}
TEXTS="$(texts)"

# t KEY -> text in the current language (English if the language is unknown, the key itself if missing)
t() {
	local col=2
	case "$LANG_CODE" in ru) col=3 ;; uk) col=4 ;; esac
	echo "$TEXTS" | awk -F'|' -v k="$1" -v c="$col" -v l="$LANG_CODE" '
		$1 == k { gsub(/@LANG@/, l, $c); print $c; found = 1; exit }
		END { if (!found) print k }'
}

# ------------------------------------------------------------------ devices

# status_label ONLINE PC_STATUS
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

# Prints one line per device: mac|name|online|pc_status|power_blocked|ip
list_devices() {
	local raw count i
	raw="$(ubus call esptopcrsw list '{}' 2>/dev/null)"
	[ -z "$raw" ] && return
	field() { echo "$raw" | jsonfilter -e "\$.devices[$i].$1"; }
	count="$(echo "$raw" | jsonfilter -e '$.devices[*].mac' | wc -l)"
	i=0
	while [ "$i" -lt "$count" ]; do
		echo "$(field mac)|$(field name)|$(field online)|$(field pc_status)|$(field power_blocked)|$(field ip)"
		i=$((i + 1))
	done
}

# line_field LINE N: N-th field of a list_devices line
line_field() { echo "$1" | cut -d'|' -f"$2"; }

# find_device_line NAME_OR_MAC: the list_devices line of that device
find_device_line() {
	local wanted
	wanted="$(echo "$1" | tr 'A-Z' 'a-z')"
	list_devices | while IFS='|' read -r mac dname online status blocked ip; do
		if [ "$(echo "$dname" | tr 'A-Z' 'a-z')" = "$wanted" ] || [ "$(echo "$mac" | tr 'A-Z' 'a-z')" = "$wanted" ]; then
			echo "$mac|$dname|$online|$status|$blocked|$ip"
			break
		fi
	done
}

# ------------------------------------------------------------------ actions

ubus_command() { ubus call esptopcrsw command "{\"mac\":\"$1\",\"action\":\"$2\"}" 2>/dev/null; }
is_ok()        { echo "$1" | grep -Eq '"ok":[[:space:]]*true'; }

action_label() {
	case "$1" in
		power_on) t action_poweron ;;
		power_off) t action_off ;;
		reset) t action_reset ;;
		*) echo "$1" ;;
	esac
}

# run_action_by_mac MAC NAME ONLINE ACTION: reconnect if offline, confirm, run
run_action_by_mac() {
	local mac="$1" dname="$2" online="$3" action="$4" res err confirm

	if [ "$online" != "true" ]; then
		echo "$(t msg_reconnecting)"
		if is_ok "$(ubus_command "$mac" check)"; then
			echo "$(t msg_connected)"
		else
			echo "$(t msg_device_offline): $dname"
			return 1
		fi
	fi

	[ "$action" = "check" ] && return 0

	printf "%s: %s -> %s? [y/N] " "$(t confirm_action)" "$dname" "$(action_label "$action")"
	read -r confirm
	case "$confirm" in
		y|Y|yes|Yes) ;;
		*) return 1 ;;
	esac

	echo "$(t msg_running) ($action)..."
	res="$(ubus_command "$mac" "$action")"
	if is_ok "$res"; then
		echo "$(t msg_done)"
	else
		err="$(echo "$res" | sed -n 's/.*"error":[[:space:]]*"\([^"]*\)".*/\1/p')"
		echo "$(t msg_error): ${err:-?}"
		return 1
	fi
}

# run_action NAME_OR_MAC ACTION
run_action() {
	local line
	line="$(find_device_line "$1")"
	if [ -z "$line" ]; then
		echo "$(t msg_not_found): $1"
		return 1
	fi
	run_action_by_mac "$(line_field "$line" 1)" "$(line_field "$line" 2)" "$(line_field "$line" 3)" "$2"
}

# ------------------------------------------------------------------ commands

cmd_list() {
	local out
	printf "%-16s %-18s %-15s %-10s\n" "$(t header_name)" "$(t header_mac)" "$(t header_ip)" "$(t header_status)"
	out="$(list_devices)"
	[ -z "$out" ] && { echo "$(t msg_no_devices)"; return; }
	echo "$out" | while IFS='|' read -r mac dname online status blocked ip; do
		printf "%-16s %-18s %-15s %-10s\n" "$dname" "$mac" "$ip" "$(status_label "$online" "$status")"
	done
}

cmd_lang() {
	local c
	if [ -n "$1" ]; then
		case "$1" in
			en|ru|uk) echo "$1" > "$LANG_FILE"; LANG_CODE="$1"; echo "Language: $1" ;;
			*) echo "Unknown language: $1 (use: en / ru / uk)" ;;
		esac
	else
		echo "$(t prompt_lang)"
		printf "> "
		read -r c
		case "$c" in
			1) echo en > "$LANG_FILE"; LANG_CODE="en" ;;
			2) echo ru > "$LANG_FILE"; LANG_CODE="ru" ;;
			3) echo uk > "$LANG_FILE"; LANG_CODE="uk" ;;
		esac
	fi
}

# device_menu MAC NAME ONLINE PC_STATUS BLOCKED: second level of the interactive menu
device_menu() {
	local mac="$1" dname="$2" online="$3" status="$4" blocked="$5" actions="" choice action

	echo ""
	echo "$(t prompt_pick_action) [$dname]:"
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
	read -r choice || return

	[ "$choice" = "0" ] && return
	action=""
	case "$choice" in
		""|*[!0-9]*) ;;
		*) action="$(echo "$actions" | awk -v n="$choice" '{print $n}')" ;;
	esac
	if [ -z "$action" ]; then
		echo "$(t msg_invalid_choice)"
		return
	fi
	run_action_by_mac "$mac" "$dname" "$online" "$action"
}

cmd_menu() {
	local tmp i choice line mac dname online status blocked ip

	while true; do
		tmp="$(mktemp)"
		list_devices > "$tmp"
		echo ""
		echo "$(t prompt_pick_device):"
		if [ -s "$tmp" ]; then
			i=1
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
		echo "  Enter) $(t action_refresh)"
		printf "> "
		read -r choice || { rm -f "$tmp"; break; }   # EOF (Ctrl-D): leave the menu

		line=""
		case "$choice" in
			"")          ;;                       # Enter: just redraw with fresh status
			0)           rm -f "$tmp"; break ;;
			[Ll])        cmd_lang ;;
			[Hh])        cmd_help ;;
			*[!0-9]*)    echo "$(t msg_invalid_choice)" ;;
			*)
				line="$(sed -n "${choice}p" "$tmp")"
				[ -n "$line" ] || echo "$(t msg_invalid_choice)"
				;;
		esac
		rm -f "$tmp"

		if [ -n "$line" ]; then
			device_menu "$(line_field "$line" 1)" "$(line_field "$line" 2)" "$(line_field "$line" 3)" \
				"$(line_field "$line" 4)" "$(line_field "$line" 5)"
		fi
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

# The CLI parses the rpcd replies with jsonfilter
if ! command -v jsonfilter >/dev/null 2>&1; then
	echo "WARNING: jsonfilter not found - CLI list/poweron/etc will not work. Install: apk add jsonfilter (OpenWrt 25.x) or opkg install jsonfilter (older)"
fi

echo ""
echo "Done. LuCI -> Services -> ESPtoPC Wireless Remote Switch (Ctrl+F5). CLI: esptopcrsw"
