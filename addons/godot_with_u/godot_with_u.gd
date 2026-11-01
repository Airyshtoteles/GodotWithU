# gdlint:disable=max-file-lines
@tool
extends EditorPlugin
## GodotWithU v0.8.0 — Real-time collaborative workspace for Godot Editor.
##
## Transport modes:
## - ENet: direct host/join for native editors on LAN/VPN.
## - WebSocket relay: browser-safe mode for Web/WASM editors via a Node relay.
##
## IMPORTANT: After making changes to ANY plugin GDScript file, you MUST
## completely restart BOTH Godot Editor instances. The .godot/ script cache
## may keep the old version loaded in memory. Disable/re-enable the plugin
## or close and reopen both editors to ensure they run the same code.

# ── Preloads ─────────────────────────────────────────────────────────
# Keep only the serializer preloaded: editor plugin scripts are loaded lazily so
# toggling the addon does not pin stale instantiable classes in Godot's cache.
# Paths are relative to this script, so the addon works under any folder name.
const ActionSerializerClass  = preload("actions/action_serializer.gd")

# ── Constants ────────────────────────────────────────────────────────
const PLUGIN_NAME    := "GodotWithU"
const PLUGIN_VERSION := "0.8.0"
## Wire protocol spoken by this addon, sent in the handshake. 1 is 0.7.x and
## older (their handshake has no such field), 2 is 0.8.0 (scene_state packets).
## Bump it whenever peers of two versions can no longer understand each other.
const PROTOCOL_VERSION := 2
## Engine meta key under which this plugin publishes itself so sibling editor
## addons (e.g. ServerProjectTree) can ask it to broadcast peer notifications.
const SHARED_META_KEY := "godot_with_u_plugin"
const POLL_INTERVAL_SEC := 0.05
## Incoming packets are read every frame and applied until this much time has
## been spent; the rest waits for the next frame so a large initial state never
## freezes the editor in one frame.
const PACKET_BUDGET_USEC := 8000
## Nodes per scene_state packet when sending a scene's initial state.
const SCENE_STATE_CHUNK_NODES := 50
## Print one line per packet sent, received and applied (debugging only).
const VERBOSE_PACKET_LOG := false
## Renew unchanged node selections before LockManager's 10-second lease expires.
const SELECTION_HEARTBEAT_INTERVAL_MSEC := 3000
const SYNC_PENDING_TIMEOUT_SEC := 3.0
## Send a backend activity ping every 20 s while a session is active so the
## React manager shows the local user as "online" even without SPT configured.
const GWU_ACTIVITY_PING_TICKS := 100   ## 400 × 0.05 s = 20 s
const GWU_ACTIVITY_PING_SOURCE := "gwu"
const GWU_ACTIVITY_TERRITORY_MODE := "editor_action_sync"
const NETWORK_TRANSPORT_WEBSOCKET := "websocket"
const NETWORK_DEFAULT_WS_URL := "wss://synchro.godaas.org/ws-relay"
const NETWORK_DEFAULT_WS_ROOM := "default"
## How the relay checks peers, as it announces it (see network_manager.gd).
const RELAY_AUTH_NONE := "none"
const RELAY_AUTH_PASSWORD := "password"
const RELAY_AUTH_BACKEND := "backend"
## Hosts that are this machine: a relay there may receive the Godot Manager token.
const LOCAL_HOSTS := ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
const META_VERTICAL_GUIDES := "_edit_vertical_guides_"
const META_HORIZONTAL_GUIDES := "_edit_horizontal_guides_"
const ANIMATED_SPRITE_SYNC_PROPERTIES := [
	"sprite_frames",
	"animation",
	"autoplay",
	"frame",
	"speed_scale",
]
const ANIMATION_PLAYER_SYNC_PROPERTIES := [
	"current_animation",
	"autoplay",
	"speed_scale",
]
## Minimum delay between two same-file collision toasts for one peer and file.
const _SAME_FILE_NOTIFY_COOLDOWN := 120.0
const FILE_SYNC_SIZE_LIMIT := 4 * 1024 * 1024  ## 4 MB max per file

# ── State ────────────────────────────────────────────────────────────
var _network_manager: RefCounted = null
var _poll_timer: Timer = null
var _interceptor: RefCounted = null
var _lock_manager: RefCounted = null
var _lock_overlay: RefCounted = null
var _script_sync: RefCounted = null
var _ghost_overlay: Control = null
var _dock: Control = null
var _auth_client: RefCounted = null
var _auth_busy: bool = false
var _auth_bearer_token: String = ""
var _auth_user: Dictionary = {}
var _gwu_ping_ticks: int = 0   ## counts poll ticks; resets each time a ping is sent
var _local_peer_id: String = "peer_%s" % str(randi()).sha256_text().substr(0, 8)
var _local_peer_name: String = ""
var _mode: String = ""   # "host", "join", or ""
var _current_room: String = ""
## Relay URL of the current or last attempted WebSocket session.
var _current_relay_url: String = ""
var _connected_transport_peer_count: int = 0
var _last_selection_heartbeat_msec: int = 0

## Timestamp when _sync_pending was set; used for timeout fallback.
var _sync_pending_since: float = 0.0

## Maps ENet network peer IDs (int) to application-level peer IDs (String).
## Populated when receiving the first packet (handshake) from each peer.
var _net_id_to_peer_id: Dictionary = {}   ## int → String
var _peer_names: Dictionary = {}   ## peer_id → display name
## Which scene each peer currently has open (peer_id → scene_file_path).
## Updated when a scene_opened packet is received from a peer.
var _peer_scenes: Dictionary = {}  ## peer_id → scene_path
## Which GDScript file each peer currently has open in the script editor.
## Updated when a script_opened packet is received from a peer.
var _peer_scripts: Dictionary = {}  ## peer_id → script_path
## Path of the GDScript the local user currently has open in the script editor.
var _local_open_script: String = ""
## Throttle same-file collision toasts: "peer_id:file" → last notification time.
var _same_file_notified: Dictionary = {}  ## String → float

# ── File sync ────────────────────────────────────────────────────────
## Snapshot of all res:// file paths when we connected; diffed on each
## filesystem_changed to detect creates, deletes and renames.
var _file_snapshot: Dictionary = {}       ## res:// path → true
## Paths received from the network — suppresses echoing them back.
var _received_file_paths: Dictionary = {} ## path → true

# ── Incoming packets ─────────────────────────────────────────────────
## Packets read from the transport but not applied yet ([net_id, bytes] pairs).
var _inbox: Array = []
var _inbox_pos: int = 0
## Peers whose dock entry must be refreshed at the end of the frame.
var _presence_dirty: Dictionary = {}   ## peer_id → true
## Host only: scene state already sent on peer_connected, per net_id, so the
## scene_opened that the same joiner sends right after is not answered twice.
var _state_sent_on_connect: Dictionary = {}   ## net_id → scene_path
## Peers already warned about a protocol mismatch in this session.
var _protocol_warned: Dictionary = {}   ## peer_id → true


# ═════════════════════════════════════════════════════════════════════
#  Lifecycle
# ═════════════════════════════════════════════════════════════════════

func _enter_tree() -> void:
	print("[%s] Plugin initialized (v%s)" % [PLUGIN_NAME, PLUGIN_VERSION])

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_SEC
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_process_network_tick)
	add_child(_poll_timer)

	# Each step stops at the first module that fails to load.
	if not (_init_locking() and _init_interceptors() and _init_editor_ui()):
		return
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)
	scene_changed.connect(_on_own_scene_changed)
	Engine.set_meta(SHARED_META_KEY, self)
	print("[%s] Ready — use the dock panel to Join." % PLUGIN_NAME)

	# Attempt silent authentication using any token saved by the Cloud addon.
	_try_silent_authenticate()


func _init_locking() -> bool:
	_lock_manager = _instantiate_addon_script("locking/lock_manager.gd", "LockManager") as RefCounted
	if _lock_manager == null:
		return false
	_lock_overlay = _instantiate_addon_script("locking/lock_overlay.gd", "LockOverlay") as RefCounted
	if _lock_overlay == null:
		return false
	_lock_overlay.init(self, _lock_manager)
	return true


func _init_interceptors() -> bool:
	_interceptor = _instantiate_addon_script(
		"actions/action_interceptor.gd", "ActionInterceptor") as RefCounted
	if _interceptor == null:
		return false
	_interceptor.init(self)
	_interceptor.set_lock_manager(_lock_manager)
	_interceptor.action_captured.connect(_on_action_captured)

	_script_sync = _instantiate_addon_script(
		"crdt/script_interceptor.gd", "ScriptInterceptor") as RefCounted
	if _script_sync == null:
		return false
	_script_sync.init(self, _local_peer_id)
	_script_sync.crdt_op_generated.connect(_on_crdt_op)
	_script_sync.cursor_changed.connect(_on_cursor_changed)
	_script_sync.active_editor_changed.connect(_on_active_editor_changed)
	_script_sync.buffer_created.connect(_on_buffer_created)
	return true


func _init_editor_ui() -> bool:
	_ghost_overlay = _instantiate_addon_script(
		"crdt/ghost_cursor_overlay.gd", "GhostCursorOverlay") as Control
	if _ghost_overlay == null:
		return false

	_auth_client = _instantiate_addon_script("auth/auth_client.gd", "AuthClient") as RefCounted
	if _auth_client == null:
		return false
	_auth_client.attach(self)

	_init_dock()
	return _dock != null


## Folder the plugin is installed in. Modules load relative to it, so copying the
## addon under another folder name (e.g. the community repository) needs no edit.
func _addon_dir() -> String:
	return (get_script() as Script).resource_path.get_base_dir()


func _instantiate_addon_script(relative_path: String, label: String) -> Object:
	var script_path := _addon_dir().path_join(relative_path)
	var script := _load_addon_script(script_path, label)
	if script == null:
		return null
	if not script.can_instantiate():
		var fresh_script := _load_addon_script_from_source(script_path, label)
		if fresh_script != null and fresh_script.can_instantiate():
			script = fresh_script
		else:
			push_error(
				("[%s] %s at %s cannot be instantiated. Disable/re-enable the addon after "
				+ "this update; restart Godot only if the cache still keeps the old script.")
				% [PLUGIN_NAME, label, script_path])
			return null
	return script.new()


func _load_addon_script(script_path: String, label: String) -> Script:
	var resource := ResourceLoader.load(script_path, "Script", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null or not (resource is Script):
		push_error("[%s] Could not load %s from %s." % [PLUGIN_NAME, label, script_path])
		return null
	return resource as Script


func _load_addon_script_from_source(script_path: String, label: String) -> Script:
	if not FileAccess.file_exists(script_path):
		push_error("[%s] Could not find %s at %s." % [PLUGIN_NAME, label, script_path])
		return null
	var source := FileAccess.get_file_as_string(script_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		push_error("[%s] Could not read %s from %s: %s." % [
			PLUGIN_NAME, label, script_path, error_string(read_error)])
		return null
	var script := GDScript.new()
	script.resource_path = script_path
	script.source_code = source
	var reload_error := script.reload(false)
	if reload_error != OK:
		push_error("[%s] Could not compile %s from %s: %s." % [
			PLUGIN_NAME, label, script_path, error_string(reload_error)])
		return null
	return script


func _exit_tree() -> void:
	# Send a blocking disconnect ping so the manager marks this user offline
	# immediately when Godot closes — async pings won't complete at shutdown.
	if _auth_client != null and (_dock == null or _dock.is_activity_ping_enabled()):
		_send_gwu_activity_ping_blocking(true)
	_do_stop()

	if _poll_timer:
		_poll_timer.timeout.disconnect(_process_network_tick)
		_poll_timer.queue_free()
		_poll_timer = null

	if _interceptor:
		_interceptor.action_captured.disconnect(_on_action_captured)
		_interceptor.teardown()
		_interceptor = null

	if _script_sync:
		_script_sync.crdt_op_generated.disconnect(_on_crdt_op)
		_script_sync.cursor_changed.disconnect(_on_cursor_changed)
		_script_sync.active_editor_changed.disconnect(_on_active_editor_changed)
		_script_sync.buffer_created.disconnect(_on_buffer_created)
		_script_sync.teardown()
		_script_sync = null

	if _ghost_overlay:
		_ghost_overlay.detach()
		if _ghost_overlay.get_parent():
			_ghost_overlay.get_parent().remove_child(_ghost_overlay)
		_ghost_overlay.queue_free()
		_ghost_overlay = null

	if _lock_overlay:
		_lock_overlay.teardown()
		_lock_overlay = null
	_lock_manager = null

	_teardown_dock()
	if _auth_client:
		_auth_client.detach()
		_auth_client = null
	_auth_bearer_token = ""
	var rfs := EditorInterface.get_resource_filesystem()
	if rfs.filesystem_changed.is_connected(_on_filesystem_changed):
		rfs.filesystem_changed.disconnect(_on_filesystem_changed)
	if scene_changed.is_connected(_on_own_scene_changed):
		scene_changed.disconnect(_on_own_scene_changed)
	if Engine.has_meta(SHARED_META_KEY) and Engine.get_meta(SHARED_META_KEY) == self:
		Engine.remove_meta(SHARED_META_KEY)
	print("[%s] Plugin shut down." % PLUGIN_NAME)


# ═════════════════════════════════════════════════════════════════════
#  Connect / Stop — Pure GDScript NetworkManager
# ═════════════════════════════════════════════════════════════════════

func _do_host(config: Dictionary) -> void:
	if _mode != "": return
	var relay_token := _relay_token(config)

	_network_manager = _instantiate_addon_script(
		"sync/network_manager.gd", "NetworkManager") as RefCounted
	if _network_manager == null:
		if _dock: _dock.set_disconnected()
		return
	_local_peer_name = _sanitize_peer_name(String(config.get("peer_name", "")))
	var transport := String(config.get("transport", NETWORK_TRANSPORT_WEBSOCKET))
	var err := FAILED
	var status_text := ""
	var info_mode := ""

	if transport == NETWORK_TRANSPORT_WEBSOCKET:
		var server_url := _migrate_relay_url(String(config.get("server_url", NETWORK_DEFAULT_WS_URL)))
		var room := String(config.get("room", NETWORK_DEFAULT_WS_ROOM)).strip_edges()
		_current_relay_url = server_url
		err = _network_manager.host_websocket(server_url, room, _local_peer_name, relay_token)
		status_text = "WS host %s" % room
		info_mode = "ws host"
		print(
			"[%s] Hosting via WebSocket relay %s in room '%s' — peer_id: %s"
			% [PLUGIN_NAME, server_url, room, _local_peer_id]
		)
	else:
		var port := int(config.get("port", 7654))
		err = _network_manager.host_enet(port)
		status_text = "Hosting :%d" % port
		info_mode = "enet host"
		print("[%s] Hosting on port %d — peer_id: %s" % [PLUGIN_NAME, port, _local_peer_id])

	if err != OK:
		if _dock: _dock.set_disconnected()
		_network_manager = null
		return

	_network_manager.peer_connected.connect(_on_peer_connected)
	_network_manager.peer_disconnected.connect(_on_peer_disconnected)
	_network_manager.relay_auth_mode_received.connect(_on_relay_auth_mode_received)
	_mode = "host"
	_current_room = String(config.get("room", "")).strip_edges()
	_connected_transport_peer_count = 0
	_last_selection_heartbeat_msec = 0
	_gwu_ping_ticks = 0
	_file_snapshot = _scan_all_files()

	if _dock:
		_dock.set_connected(status_text)
		_dock.update_info("v%s • %s • %s" % [PLUGIN_VERSION, _local_peer_id, info_mode])
	_refresh_dock_session_state()
	_queue_gwu_activity_ping()


func _do_join(config: Dictionary) -> void:
	if _mode != "": return
	var relay_token := _relay_token(config)

	_local_peer_name = _sanitize_peer_name(String(config.get("peer_name", "")))
	var transport := String(config.get("transport", NETWORK_TRANSPORT_WEBSOCKET))

	# Pause op generation until the relay assigns our role. In WebSocket mode,
	# the first peer in a room is promoted automatically and keeps its local
	# buffers; later peers clear theirs before accepting the coordinator state.
	if _script_sync:
		_script_sync.set_sync_pending(true)
		_sync_pending_since = Time.get_unix_time_from_system()
		if transport != NETWORK_TRANSPORT_WEBSOCKET:
			_script_sync.clear_all_buffers()

	_network_manager = _instantiate_addon_script(
		"sync/network_manager.gd", "NetworkManager") as RefCounted
	if _network_manager == null:
		if _dock: _dock.set_disconnected()
		if _script_sync:
			_script_sync.set_sync_pending(false)
		_sync_pending_since = 0.0
		return
	var err := FAILED
	var status_text := ""
	var info_mode := ""

	if transport == NETWORK_TRANSPORT_WEBSOCKET:
		var server_url := _migrate_relay_url(String(config.get("server_url", NETWORK_DEFAULT_WS_URL)))
		var room := String(config.get("room", NETWORK_DEFAULT_WS_ROOM)).strip_edges()
		_current_relay_url = server_url
		err = _network_manager.join_websocket(server_url, room, _local_peer_name, relay_token)
		status_text = "WS join %s" % room
		info_mode = "ws join"
		print(
			"[%s] Joined WebSocket relay %s in room '%s' — peer_id: %s"
			% [PLUGIN_NAME, server_url, room, _local_peer_id]
		)
	else:
		var ip := String(config.get("ip", "127.0.0.1")).strip_edges()
		var port := int(config.get("port", 7654))
		if ip.is_empty():
			ip = "127.0.0.1"
		err = _network_manager.join_enet(ip, port)
		status_text = "Joined %s:%d" % [ip, port]
		info_mode = "enet join"
		print("[%s] Joined host at %s:%d — peer_id: %s" % [PLUGIN_NAME, ip, port, _local_peer_id])

	if err != OK:
		if _dock: _dock.set_disconnected()
		_network_manager = null
		if _script_sync:
			_script_sync.set_sync_pending(false)
		_sync_pending_since = 0.0
		return

	_network_manager.peer_connected.connect(_on_peer_connected)
	_network_manager.peer_disconnected.connect(_on_peer_disconnected)
	_network_manager.role_assigned.connect(_on_network_role_assigned)
	_network_manager.relay_auth_mode_received.connect(_on_relay_auth_mode_received)
	_mode = "join"
	_current_room = String(config.get("room", "")).strip_edges()
	_connected_transport_peer_count = 0
	_last_selection_heartbeat_msec = 0
	_gwu_ping_ticks = 0
	_file_snapshot = _scan_all_files()

	if _dock:
		_dock.set_connected(status_text)
		_dock.update_info("v%s • %s • %s" % [PLUGIN_VERSION, _local_peer_id, info_mode])
	_refresh_dock_session_state()
	_queue_gwu_activity_ping()


func _on_network_role_assigned(role: String, promoted: bool) -> void:
	if _network_manager == null:
		return
	if _network_manager.get_transport() != NETWORK_TRANSPORT_WEBSOCKET:
		return

	var assigned_role := role.strip_edges().to_lower()
	if assigned_role == "host":
		_mode = "host"
		if _script_sync:
			_script_sync.set_sync_pending(false)
			_sync_pending_since = 0.0
	else:
		_mode = "join"
		if _script_sync:
			_script_sync.clear_all_buffers()
			_script_sync.set_sync_pending(true)
			_sync_pending_since = Time.get_unix_time_from_system()

	if _dock:
		var role_label := "coordinator" if _mode == "host" else "peer"
		_dock.update_info("v%s • %s • ws %s" % [PLUGIN_VERSION, _local_peer_id, role_label])
	_refresh_dock_session_state()
	if promoted and _mode == "host":
		_resync_after_promotion.call_deferred()


func _resync_after_promotion() -> void:
	if not _has_active_session() or _mode != "host":
		return
	if _network_manager.get_transport() != NETWORK_TRANSPORT_WEBSOCKET:
		return

	print("[%s] Promoted to coordinator — broadcasting authoritative state." % PLUGIN_NAME)
	_send_initial_state(0)


## Called automatically when the underlying transport closes while a session
## is active (internet loss, relay restart, etc.).
## Shows a Godot toast, notifies the manager, and tears down the session.
func _on_connection_dropped() -> void:
	print("[%s] ⚡ Connection dropped — stopping sync." % PLUGIN_NAME)
	# Godot editor toast
	if Engine.is_editor_hint():
		var toaster := EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(
				"⚡ Connexion perdue — sync arrêtée",
				EditorToaster.SEVERITY_ERROR,
				"La connexion au serveur relais a été perdue. La synchronisation est arrêtée automatiquement."
			)
	# Notify the manager so all project members see a toast
	_post_disconnection_event()
	# Tear down the session (sets dock to red "Offline")
	_do_stop()
	# Override the generic "Offline" message with a specific disconnection label
	if _dock:
		_dock.show_connection_dropped()


## The relay refused the join: no credential, a wrong one, or no access to the
## room. No session ever started, so stop without the "connection lost" toast or
## the manager event, and show the field the relay asks for.
func _on_relay_rejected(rejection: Dictionary) -> void:
	var code := String(rejection.get("code", ""))
	var mode := String(rejection.get("auth", ""))
	var relay_url := _current_relay_url
	print("[%s] Relay refused the join (%s): %s" % [
		PLUGIN_NAME, code, String(rejection.get("message", ""))])
	_do_stop()
	var message := ""
	match code:
		"auth_invalid":
			message = "Wrong relay password."
		"project_access_denied":
			message = "Your account cannot open this project on the relay."
		_:
			if mode == RELAY_AUTH_PASSWORD:
				message = "This relay needs a password. Enter it, then Join again."
			elif _backend_token_for_relay(relay_url).is_empty():
				message = _backend_login_hint(relay_url)
			else:
				message = "The relay did not accept your Godot Manager login."
	_show_relay_auth_needed(relay_url, mode, message)


func _on_relay_auth_mode_received(mode: String) -> void:
	if _dock:
		_dock.remember_relay_auth_mode(_current_relay_url, mode)


## Fire-and-forget: POST a disconnection event to the backend so all project
## members receive a live toast notification in the manager.
func _post_disconnection_event() -> void:
	if _current_room.is_empty() or _auth_client == null:
		return
	_auth_client.post_disconnection_event(_current_room, _local_peer_name)


func _do_stop() -> void:
	# Notify the backend that this peer is going offline before tearing down.
	if _has_active_session() and _auth_client != null:
		if _dock == null or _dock.is_activity_ping_enabled():
			_send_gwu_activity_ping(true)
	_gwu_ping_ticks = 0
	if _network_manager:
		_network_manager.stop()
		_network_manager = null
	_mode = ""
	_current_room = ""
	_connected_transport_peer_count = 0
	_net_id_to_peer_id.clear()
	_peer_names.clear()
	_peer_scenes.clear()
	_peer_scripts.clear()
	_file_snapshot.clear()
	_received_file_paths.clear()
	_same_file_notified.clear()
	_inbox.clear()
	_inbox_pos = 0
	_presence_dirty.clear()
	_state_sent_on_connect.clear()
	_protocol_warned.clear()
	_sync_pending_since = 0.0
	if _script_sync:
		_script_sync.set_sync_pending(false)
	_refresh_dock_session_state()

	# Release ALL remote locks — we're disconnected, no peer is valid
	if _lock_manager:
		for locking_peer in _lock_manager.get_locking_peers():
			if locking_peer != _local_peer_id:
				_lock_manager.release_all_for_peer(locking_peer)

	if _dock:
		_dock.set_disconnected()
		_dock.update_info("v%s" % PLUGIN_VERSION)


# ═════════════════════════════════════════════════════════════════════
#  Network Message Handling
# ═════════════════════════════════════════════════════════════════════

## Reads the transport every frame and applies queued packets until
## PACKET_BUDGET_USEC is spent. Periodic housekeeping stays on the poll timer.
func _process(_delta: float) -> void:
	if _network_manager == null:
		return
	var received: Array = _network_manager.poll_messages()
	if not received.is_empty():
		_inbox.append_array(received)
	if _inbox_pos < _inbox.size():
		var deadline := Time.get_ticks_usec() + PACKET_BUDGET_USEC
		while _inbox_pos < _inbox.size() and _network_manager != null:
			var entry: Array = _inbox[_inbox_pos]
			_inbox_pos += 1
			_on_relay_message(entry[0], entry[1])
			if Time.get_ticks_usec() >= deadline:
				break
		if _inbox_pos >= _inbox.size():
			_inbox.clear()
			_inbox_pos = 0
	_flush_peer_presence()


func _process_network_tick() -> void:
	# Detect unexpected disconnection (transport died while a session was active).
	# A relay that refused the join closes too, but that is not a lost session.
	if _mode != "" and _network_manager != null and not _network_manager.is_active():
		var rejection: Dictionary = _network_manager.get_rejection()
		if rejection.is_empty():
			_on_connection_dropped()
		else:
			_on_relay_rejected(rejection)
		return

	# A selection_changed signal only fires when the selected node changes.
	# Renew the current selection lease explicitly so a lock remains valid while
	# the user continuously edits the same node.
	if _has_active_session() and _interceptor:
		var now_msec := Time.get_ticks_msec()
		if _last_selection_heartbeat_msec == 0 \
				or now_msec - _last_selection_heartbeat_msec \
				>= SELECTION_HEARTBEAT_INTERVAL_MSEC:
			_last_selection_heartbeat_msec = now_msec
			_interceptor.emit_selection_heartbeat()

	# Timeout fallback: if no crdt_sync arrived within the timeout,
	# clear _sync_pending so the client can start editing normally.
	if _script_sync and _sync_pending_since > 0.0:
		var elapsed := Time.get_unix_time_from_system() - _sync_pending_since
		if elapsed >= SYNC_PENDING_TIMEOUT_SEC:
			_script_sync.set_sync_pending(false)
			_sync_pending_since = 0.0
			print("[%s] sync_pending timed out after %.1fs" % [PLUGIN_NAME, elapsed])

	# Retry any actions that arrived before their target node existed
	if _interceptor:
		_interceptor.retry_pending()

	# Periodically check for timed-out locks
	if _lock_manager:
		_lock_manager.check_timeouts()

	# Periodically ping the backend so the local user shows as "online" in the
	# manager, even when SPT is not configured. Fire-and-forget; no session needed.
	if _has_active_session() and _auth_client != null:
		if _dock == null or _dock.is_activity_ping_enabled():
			_gwu_ping_ticks += 1
			if _gwu_ping_ticks >= GWU_ACTIVITY_PING_TICKS:
				_gwu_ping_ticks = 0
				_send_gwu_activity_ping.call_deferred()


func _has_active_session() -> bool:
	return _network_manager != null and _mode != ""


func _queue_gwu_activity_ping() -> void:
	if _auth_client == null:
		return
	if _dock != null and not _dock.is_activity_ping_enabled():
		return
	_gwu_ping_ticks = 0
	_send_gwu_activity_ping.call_deferred()


## Public accessor for sibling editor addons (read via Engine meta).
## Returns true while a host/join session is open on either transport.
func has_active_session() -> bool:
	return _has_active_session()


## Public accessor for sibling editor addons — the current room name (or "").
func get_current_room() -> String:
	return _current_room


## Public accessor for sibling editor addons — the local peer display name.
func get_local_peer_name() -> String:
	return _local_peer_name


## Send a fire-and-forget activity ping to the backend so the manager shows this
## user as "online". Called from _process_network_tick via call_deferred.
func _send_gwu_activity_ping(disconnect: bool = false) -> void:
	if _auth_client == null:
		return
	var settings: Dictionary = _auth_client.load_settings()
	var project_name := String(settings.get("backend_project_name", "")).strip_edges()
	if project_name.is_empty():
		project_name = String(ProjectSettings.get_setting("application/config/name", "")).strip_edges()
	if project_name.is_empty():
		return
	var open_files: Array = []
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root and not String(scene_root.scene_file_path).is_empty():
		open_files.append(String(scene_root.scene_file_path).trim_prefix("res://"))
	if not _local_open_script.is_empty():
		var script_display := String(_local_open_script).trim_prefix("res://")
		if not open_files.has(script_display):
			open_files.append(script_display)
	_auth_client.post_activity_ping(
		project_name, open_files, disconnect, _build_gwu_activity_metadata())


## Blocking variant used during _exit_tree so the disconnect is guaranteed to
## reach the backend before Godot closes (async calls don't complete at shutdown).
func _send_gwu_activity_ping_blocking(disconnect: bool = false) -> void:
	if _auth_client == null:
		return
	var settings: Dictionary = _auth_client.load_settings()
	var project_name := String(settings.get("backend_project_name", "")).strip_edges()
	if project_name.is_empty():
		project_name = String(ProjectSettings.get_setting("application/config/name", "")).strip_edges()
	if project_name.is_empty():
		return
	_auth_client.post_activity_ping_blocking(project_name, disconnect, _build_gwu_activity_metadata())


func _build_gwu_activity_metadata() -> Dictionary:
	var active := _has_active_session()
	return {
		"ping_source": GWU_ACTIVITY_PING_SOURCE,
		"territory_mode": GWU_ACTIVITY_TERRITORY_MODE,
		"editor_action_sync": active,
		"multi_editor_active": active,
	}


## Sibling editor addons (ServerProjectTree) call this through Engine meta when
## they want peers to see a toast without going through any CRDT/file path.
## Returns true when a packet was sent, false when no session is active.
func broadcast_peer_notification(notification_kind: String, data: Dictionary) -> bool:
	if not _has_active_session():
		return false
	var kind := String(notification_kind).strip_edges()
	if kind.is_empty():
		return false
	var payload := {
		"type": "peer_notification",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {
			"kind": kind,
			"payload": data if typeof(data) == TYPE_DICTIONARY else {},
		},
	}
	_send_packet(ActionSerializerClass.serialize(payload))
	return true


func _send_packet(packet: PackedByteArray) -> void:
	if _has_active_session():
		if VERBOSE_PACKET_LOG:
			print("[%s] SEND: %d bytes" % [PLUGIN_NAME, packet.size()])
		_network_manager.broadcast_packet(packet)
	else:
		print("[%s] SEND SKIPPED: mode='%s' network_manager=%s" % [
			PLUGIN_NAME, _mode, _network_manager != null
		])


## Send a packet to a single specific peer (by transport-specific net_id).
func _send_packet_to(net_id: int, packet: PackedByteArray) -> void:
	if _has_active_session():
		_network_manager.send_to_peer(net_id, packet)


func _on_relay_message(sender_net_id: int, data: PackedByteArray) -> void:
	if VERBOSE_PACKET_LOG:
		print("[%s] RECV: %d bytes" % [PLUGIN_NAME, data.size()])
	var action: Dictionary = ActionSerializerClass.deserialize(data)
	if action.is_empty():
		print("[%s] RECV: deserialization failed!" % PLUGIN_NAME)
		return

	var action_type: String = action.get("type", "")
	var sender_peer_id: String = action.get("peer_id", "")
	var sender_peer_name: String = _sanitize_peer_name(String(action.get("peer_name", "")))

	if VERBOSE_PACKET_LOG:
		print("[%s] RECV action: type=%s peer=%s (me=%s)" % [
			PLUGIN_NAME, action_type,
			_peer_display_name(sender_peer_id, sender_peer_name),
			_peer_display_name(_local_peer_id)
		])

	# Skip own messages
	if sender_peer_id == _local_peer_id:
		if VERBOSE_PACKET_LOG:
			print("[%s] RECV: skipped own message" % PLUGIN_NAME)
		return

	if action_type.is_empty():
		push_warning("[%s] RECV: missing action type" % PLUGIN_NAME)
		return

	# Map the ENet network ID to the application peer ID on first contact
	if not sender_peer_id.is_empty() and not _net_id_to_peer_id.has(sender_net_id):
		_net_id_to_peer_id[sender_net_id] = sender_peer_id
		print("[%s] Mapped net_id=%d → peer_id=%s" % [PLUGIN_NAME, sender_net_id, sender_peer_id])

	if not sender_peer_id.is_empty():
		_update_peer_presence(sender_peer_id, sender_peer_name)

	# Keep track of which scene each peer has open. Any packet that carries
	# scene_path tells us the sender's active scene (not just scene_opened).
	var packet_scene_path: String = action.get("scene_path", "")
	if not sender_peer_id.is_empty() and not packet_scene_path.is_empty():
		_peer_scenes[sender_peer_id] = packet_scene_path
		_update_peer_presence(sender_peer_id)
		_notify_same_file_if_needed(sender_peer_id, sender_peer_name, packet_scene_path)

	# Scene-node actions must only be applied when both peers have the same
	# scene open. If the sender's scene_path is known and differs from the
	# local scene, discard the packet to avoid corrupting unrelated scenes.
	const SCENE_NODE_ACTIONS := [
		"select", "property", "node_add", "node_delete", "node_rename", "node_reorder",
		"script_attach", "script_detach", "scene_guides", "scene_state",
	]
	if action_type in SCENE_NODE_ACTIONS:
		var sender_scene: String = action.get("scene_path", "")
		var guard_root := EditorInterface.get_edited_scene_root()
		var local_scene: String = guard_root.scene_file_path if guard_root else ""
		if not sender_scene.is_empty() and not local_scene.is_empty() and local_scene != sender_scene:
			if VERBOSE_PACKET_LOG:
				print("[%s] RECV: skipping '%s' — scene mismatch (local='%s' remote='%s')" % [
					PLUGIN_NAME, action_type, local_scene, sender_scene])
			return

	match action_type:
		"handshake":
			# The net_id mapping is handled above; only the protocol is left to check.
			print("[%s] Handshake received from %s" % [
				PLUGIN_NAME, _peer_display_name(sender_peer_id, sender_peer_name)])
			_check_peer_protocol(sender_peer_id, sender_peer_name, action)
		"select", "property", "node_add", "node_delete", "node_rename", "node_reorder", "scene_guides":
			if VERBOSE_PACKET_LOG:
				print("[%s] APPLYING: %s" % [PLUGIN_NAME, action.get("type")])
			if _interceptor:
				_interceptor.apply_remote_action(action)
		"scene_state":
			# Initial state of a scene, many nodes per packet (see _send_initial_state).
			if _interceptor:
				_interceptor.apply_remote_action(action)
			if _script_sync:
				for entry in action.get("data", {}).get("nodes", []):
					var attached: Dictionary = entry.get("script", {})
					var state_script_path: String = attached.get("script_path", "")
					if not state_script_path.is_empty():
						_script_sync.initialize_buffer_from_content(
							state_script_path, String(attached.get("script_content", "")))
		"script_detach":
			print("[%s] APPLYING: script_detach" % PLUGIN_NAME)
			if _interceptor:
				_interceptor.apply_remote_action(action)
			if _script_sync:
				var detach_data: Dictionary = action.get("data", {})
				var detach_path: String = detach_data.get("script_path", "")
				if not detach_path.is_empty():
					_script_sync.remove_buffer(detach_path)
		"script_attach":
			print("[%s] APPLYING: script_attach" % PLUGIN_NAME)
			if _interceptor:
				_interceptor.apply_remote_action(action)
			# Also initialize a CRDT buffer so future text edits sync
			if _script_sync:
				var attach_data: Dictionary = action.get("data", {})
				var spath: String = attach_data.get("script_path", "")
				var scontent: String = attach_data.get("script_content", "")
				if not spath.is_empty():
					_script_sync.initialize_buffer_from_content(spath, scontent)
		"crdt":
			if _script_sync:
				_script_sync.apply_remote_op(
					action.get("data", {}),
					action.get("node_path", "")
				)
		"crdt_sync":
			if _script_sync:
				var sync_path: String = action.get("node_path", "")
				# Track that this sender has a buffer for this script path.
				if not sender_peer_id.is_empty() and not sync_path.is_empty():
					_peer_scripts[sender_peer_id] = sync_path
					_update_peer_presence(sender_peer_id)
					_notify_same_file_if_needed(sender_peer_id, sender_peer_name, sync_path)
				if _mode == "host":
					# Host is authoritative. If we already have a buffer
					# for this script, reject the incoming sync and send
					# our own buffer back so the client converges.
					if _script_sync.has_buffer(sync_path):
						var state: Dictionary = _script_sync.export_buffer(sync_path)
						if not state.is_empty():
							var reply := {
								"type": "crdt_sync",
								"peer_id": _local_peer_id,
								"timestamp": Time.get_unix_time_from_system(),
								"node_path": sync_path,
								"data": state,
							}
							_send_packet(ActionSerializerClass.serialize(reply))
					else:
						# Host has no buffer — accept the client's buffer
						_script_sync.import_buffer_state(
							sync_path, action.get("data", {}))
				else:
					# Clients always accept crdt_sync (host is authoritative)
					_script_sync.import_buffer_state(
						sync_path, action.get("data", {}))
					# Host's sync arrived — client can now generate ops safely
					_script_sync.set_sync_pending(false)
					_sync_pending_since = 0.0
		"cursor_update":
			if _ghost_overlay:
				_ghost_overlay.update_peer_cursor(
					action.get("peer_id", ""),
					action.get("data", {})
				)
		"script_opened":
			# Track which script this peer now has open.
			var opened_script: String = action.get("data", {}).get("script_path", "")
			if not sender_peer_id.is_empty() and not opened_script.is_empty():
				_peer_scripts[sender_peer_id] = opened_script
				_update_peer_presence(sender_peer_id)
				_notify_same_file_if_needed(sender_peer_id, sender_peer_name, opened_script)
			# Any peer that has a CRDT buffer for this script sends crdt_sync
			# so the newly-opened peer gets the authoritative content.
			if not opened_script.is_empty() and _script_sync:
				if _script_sync.has_buffer(opened_script):
					var state: Dictionary = _script_sync.export_buffer(opened_script)
					if not state.is_empty():
						var reply := {
							"type": "crdt_sync",
							"peer_id": _local_peer_id,
							"peer_name": _local_peer_name,
							"timestamp": Time.get_unix_time_from_system(),
							"node_path": opened_script,
							"data": state,
						}
						if _mode == "host":
							var net_id := _get_net_id_for_peer(sender_peer_id)
							if net_id != -1:
								_send_packet_to(net_id, ActionSerializerClass.serialize(reply))
							else:
								_send_packet(ActionSerializerClass.serialize(reply))
						else:
							_send_packet(ActionSerializerClass.serialize(reply))
						print("[%s] Sent crdt_sync for '%s' to peer who just opened it" % [
							PLUGIN_NAME, opened_script])
		"file_create":
			var fc_path: String = action.get("data", {}).get("path", "")
			var fc_ok := false
			if _dock:
				if _dock.is_all_sync_enabled():
					fc_ok = true
				elif _is_scene_file(fc_path) and _dock.is_file_sync_enabled():
					fc_ok = true
				elif _is_gd_file(fc_path) and _dock.is_gd_sync_enabled():
					fc_ok = true
			if fc_ok:
				_apply_file_create(action)
		"file_delete":
			var fd_path: String = action.get("data", {}).get("path", "")
			var fd_ok := false
			if _dock:
				if _dock.is_all_sync_enabled():
					fd_ok = true
				elif _is_scene_file(fd_path) and _dock.is_file_sync_enabled():
					fd_ok = true
				elif _is_gd_file(fd_path) and _dock.is_gd_sync_enabled():
					fd_ok = true
			if fd_ok:
				_apply_file_delete(action)
		"peer_notification":
			# Informational packet from a sibling editor addon. No CRDT/file
			# side effects — we only surface a transient toast locally.
			_show_peer_notification_toast(sender_peer_id, sender_peer_name, action.get("data", {}))
		"scene_opened":
			# Track which scene this peer now has open.
			var sender_scene: String = action.get("data", {}).get("scene_path", "")
			if not sender_peer_id.is_empty() and not sender_scene.is_empty():
				_peer_scenes[sender_peer_id] = sender_scene
				_update_peer_presence(sender_peer_id)
				_notify_same_file_if_needed(sender_peer_id, sender_peer_name, sender_scene)
			# Any peer that already has the same scene open sends its current state
			# so the newly-opened peer gets all nodes that exist in the session.
			if not sender_scene.is_empty():
				var my_root := EditorInterface.get_edited_scene_root()
				if my_root and my_root.scene_file_path == sender_scene:
					if _mode == "host":
						# Host: directed send — most efficient, avoids flooding all peers.
						var net_id := _get_net_id_for_peer(sender_peer_id)
						# The joiner announces the scene it had open when it
						# connected; that state already left on peer_connected.
						# Later scene_opened packets (scene switches) are answered.
						var already_sent: bool = _state_sent_on_connect.has(net_id) \
								and String(_state_sent_on_connect[net_id]) == sender_scene
						_state_sent_on_connect.erase(net_id)
						if net_id != -1 and not already_sent:
							_send_initial_state(net_id)
					else:
						# Client: cannot address other clients directly in ENet star
						# topology, so broadcast (target=0; the host relays it).
						# node_add is idempotent on already-synced receivers so this is safe.
						_send_initial_state(0)


func _on_peer_connected(peer_id: int) -> void:
	print("[%s] Peer connected (net_id=%d)" % [PLUGIN_NAME, peer_id])
	_connected_transport_peer_count += 1
	_refresh_dock_session_state()

	# Send a handshake so the remote peer can map our net_id → peer_id
	var handshake := {
		"type": "handshake",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"protocol": PROTOCOL_VERSION,
		"plugin_version": PLUGIN_VERSION,
	}
	_send_packet(ActionSerializerClass.serialize(handshake))
	# A peer may join while we have already had the same node selected for a
	# while. Send the current lease immediately instead of waiting for the next
	# 3-second heartbeat tick.
	if _interceptor:
		_last_selection_heartbeat_msec = Time.get_ticks_msec()
		_interceptor.emit_selection_heartbeat()

	# Only the JOINER announces its scene — this triggers the host (and other
	# established peers) to send their authoritative state back.
	# The HOST must NOT broadcast scene_opened here: if it did, the joiner
	# (who has stale disk positions) would receive it, call _send_initial_state
	# with pos=0, corrupt the host's live state, and the host's poll would then
	# emit pos=0 back to the joiner — overwriting the correct positions.
	var my_root := EditorInterface.get_edited_scene_root()
	if my_root and not my_root.scene_file_path.is_empty() and _mode == "join":
		var announce := {
			"type": "scene_opened",
			"peer_id": _local_peer_id,
			"peer_name": _local_peer_name,
			"timestamp": Time.get_unix_time_from_system(),
			"data": {"scene_path": my_root.scene_file_path},
		}
		_send_packet(ActionSerializerClass.serialize(announce))
		# Activate sync guard so our stale disk state does not overwrite
		# the authoritative state coming back from the host.
		if _interceptor:
			_interceptor.set_scene_sync_guard()

	# When hosting, send the current scene state to the new joiner, and
	# remember it so the joiner's scene_opened for that scene is not answered
	# with the same state a second time.
	if _mode == "host":
		_send_initial_state(peer_id)
		var sent_root := EditorInterface.get_edited_scene_root()
		_state_sent_on_connect[peer_id] = sent_root.scene_file_path if sent_root else ""


func _on_peer_disconnected(peer_id: int) -> void:
	_state_sent_on_connect.erase(peer_id)
	# Look up the application-level peer ID from the ENet network ID
	var app_peer_id: String = _net_id_to_peer_id.get(peer_id, "")
	if app_peer_id.is_empty():
		print("[%s] Peer disconnected (net_id=%d) — no handshake mapping" % [
			PLUGIN_NAME, peer_id])
		# No handshake was received for this net_id, but they may still
		# hold locks under a peer_id we never mapped. Release any locks
		# from peers that are no longer in our known connections.
		if _lock_manager:
			var active_peer_ids: Array[String] = []
			for mapped_peer in _net_id_to_peer_id.values():
				active_peer_ids.append(str(mapped_peer))
			for locking_peer in _lock_manager.get_locking_peers():
				if locking_peer not in active_peer_ids and locking_peer != _local_peer_id:
					print("[%s] Releasing orphan locks for unmapped peer '%s'" % [
						PLUGIN_NAME, _peer_display_name(locking_peer)])
					_lock_manager.release_all_for_peer(locking_peer)
					if _dock: _dock.remove_peer(locking_peer)
					if _ghost_overlay: _ghost_overlay.remove_peer(locking_peer)
		_connected_transport_peer_count = maxi(_connected_transport_peer_count - 1, 0)
		_refresh_dock_session_state()
		return

	# Resolve the display name before erasing it from the cache below.
	var who := _peer_display_name(app_peer_id)
	if _dock: _dock.remove_peer(app_peer_id)
	if _lock_manager: _lock_manager.release_all_for_peer(app_peer_id)
	if _ghost_overlay: _ghost_overlay.remove_peer(app_peer_id)
	_net_id_to_peer_id.erase(peer_id)
	_presence_dirty.erase(app_peer_id)
	_peer_names.erase(app_peer_id)
	_peer_scenes.erase(app_peer_id)
	_peer_scripts.erase(app_peer_id)
	_connected_transport_peer_count = maxi(_connected_transport_peer_count - 1, 0)
	_refresh_dock_session_state()
	print("[%s] Peer disconnected: %s (net_id=%d)" % [PLUGIN_NAME, who, peer_id])


# ═════════════════════════════════════════════════════════════════════
#  Action / CRDT Handlers (local edits → broadcast)
# ═════════════════════════════════════════════════════════════════════

func _on_action_captured(action: Dictionary) -> void:
	if not _has_active_session():
		return
	action["peer_id"] = _local_peer_id
	action["peer_name"] = _local_peer_name
	var capture_root := EditorInterface.get_edited_scene_root()
	if capture_root:
		action["scene_path"] = capture_root.scene_file_path
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_crdt_op(op: Dictionary, script_path: String) -> void:
	if not _has_active_session() or script_path.is_empty():
		return
	var action := {
		"type": "crdt",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": script_path,
		"data": op,
	}
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_buffer_created(script_path: String) -> void:
	if not _has_active_session():
		return   # Not connected, nothing to sync
	if not _script_sync:
		return
	# Don't broadcast our freshly-bootstrapped (from-disk) buffer if any peer
	# already has a CRDT buffer for this script — they are the source of truth.
	# We'll receive their crdt_sync shortly via the script_opened announce sent
	# from _on_active_editor_changed, which overwrites our local bootstrap.
	for pid in _peer_scripts:
		if String(_peer_scripts[pid]) == script_path:
			print("[%s] Skipping crdt_sync broadcast for '%s' — peer already has buffer" % [
				PLUGIN_NAME, script_path])
			return
	var state: Dictionary = _script_sync.export_buffer(script_path)
	if state.is_empty():
		return
	var sync_action := {
		"type": "crdt_sync",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": script_path,
		"data": state,
	}
	_send_packet(ActionSerializerClass.serialize(sync_action))
	print("[%s] Broadcast crdt_sync for newly created buffer: %s" % [PLUGIN_NAME, script_path])



func _on_cursor_changed(data: Dictionary, script_path: String) -> void:
	if not _has_active_session() or script_path.is_empty():
		return
	var action := {
		"type": "cursor_update",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {
			"peer_name": _local_peer_name,
			"script_path": script_path,
			"line": data.get("line", 0),
			"column": data.get("column", 0),
		},
	}
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_active_editor_changed(code_edit: CodeEdit, script_path: String) -> void:
	_local_open_script = script_path
	if _ghost_overlay:
		if _ghost_overlay.get_parent():
			_ghost_overlay.get_parent().remove_child(_ghost_overlay)
		code_edit.add_child(_ghost_overlay)
		_ghost_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_ghost_overlay.attach_to(code_edit, script_path)
	# Announce to all peers which script we just opened so they can
	# send us their authoritative CRDT buffer for it.
	if _has_active_session() and not script_path.is_empty():
		var announce := {
			"type": "script_opened",
			"peer_id": _local_peer_id,
			"peer_name": _local_peer_name,
			"timestamp": Time.get_unix_time_from_system(),
			"data": {"script_path": script_path},
		}
		_send_packet(ActionSerializerClass.serialize(announce))
		# Activate sync-pending guard if any peer already has this script open
		# (they are the source of truth, not our local file copy).
		var peers_have_it := false
		for pid in _peer_scripts:
			if String(_peer_scripts[pid]) == script_path:
				peers_have_it = true
				break
		# Also check CRDT buffers from peers' recent packets (more reliable).
		if not peers_have_it and _script_sync:
			peers_have_it = _script_sync.has_buffer(script_path)
		if peers_have_it and _script_sync:
			_script_sync.set_sync_pending(true)
			_sync_pending_since = Time.get_unix_time_from_system()
			print("[%s] sync_pending activated for script: %s" % [PLUGIN_NAME, script_path])


## Show a local Godot toast + notify the manager when a remote peer opens the
## same file the local user has active. Throttled per (peer, file) pair.
func _notify_same_file_if_needed(peer_id: String, peer_name: String, remote_file: String) -> void:
	if not _has_active_session() or remote_file.is_empty() or peer_id == _local_peer_id:
		return
	var local_scene: String = ""
	var root := EditorInterface.get_edited_scene_root()
	if root:
		local_scene = root.scene_file_path
	var matched_file := ""
	if not remote_file.is_empty():
		if remote_file == local_scene or remote_file == _local_open_script:
			matched_file = remote_file
	if matched_file.is_empty():
		return
	var key := "%s:%s" % [peer_id, matched_file]
	var now := Time.get_unix_time_from_system()
	if _same_file_notified.has(key) \
			and (now - float(_same_file_notified[key])) < _SAME_FILE_NOTIFY_COOLDOWN:
		return
	_same_file_notified[key] = now
	var who := _peer_display_name(peer_id, peer_name)
	var fname := matched_file.get_file()
	if Engine.is_editor_hint():
		var toaster := EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(
				"⚠ %s is also editing %s" % [who, fname],
				EditorToaster.SEVERITY_WARNING,
				"You and %s are both working on %s" % [who, matched_file]
			)
	_post_collab_presence(matched_file, who)


## Fire-and-forget: POST same-file presence info to the backend so the
## React manager can surface a toast to all project members.
func _post_collab_presence(file_path: String, peer_name: String) -> void:
	if _current_room.is_empty() or _auth_client == null:
		return
	_auth_client.post_collab_presence(_current_room, file_path, peer_name)


func _update_peer_presence(peer_id: String, peer_name: String = "") -> void:
	if peer_id.is_empty():
		return

	var clean_name := _sanitize_peer_name(peer_name)
	if not clean_name.is_empty():
		_peer_names[peer_id] = clean_name

	# Called for nearly every packet: the dock entry is refreshed once per frame.
	_presence_dirty[peer_id] = true


func _flush_peer_presence() -> void:
	if _presence_dirty.is_empty():
		return
	if _dock:
		for peer_id in _presence_dirty:
			_dock.upsert_peer(peer_id, _get_peer_label(peer_id))
	_presence_dirty.clear()


## Resolve a peer's display name (pseudo) for notifications and Output logs.
## Prefers the cached display name, then the name carried in the current packet,
## then falls back to the raw peer_id when no name is known yet.
func _peer_display_name(peer_id: String, packet_name: String = "") -> String:
	if peer_id.is_empty():
		return peer_id
	if peer_id == _local_peer_id and not _local_peer_name.is_empty():
		return _local_peer_name
	var cached := String(_peer_names.get(peer_id, "")).strip_edges()
	if not cached.is_empty():
		return cached
	var pkt := packet_name.strip_edges()
	if not pkt.is_empty():
		return pkt
	return peer_id


func _get_peer_label(peer_id: String) -> String:
	var label := _peer_display_name(peer_id)
	var files: Array[String] = []
	var scene: String = String(_peer_scenes.get(peer_id, ""))
	if not scene.is_empty():
		files.append(scene.get_file())
	var script: String = String(_peer_scripts.get(peer_id, ""))
	if not script.is_empty() and script != scene:
		files.append(script.get_file())
	if not files.is_empty():
		label += " (" + ", ".join(files) + ")"
	return label


func _sanitize_peer_name(peer_name: String) -> String:
	var clean_name := peer_name.strip_edges()
	if clean_name.is_empty():
		return ""
	return clean_name


# ═════════════════════════════════════════════════════════════════════
#  Initial State Sync — send current scene to newly joined peers
# ═════════════════════════════════════════════════════════════════════

## Called when a peer joins, or after coordinator promotion. Iterates the
## current edited scene and sends it to one peer, or broadcasts it when the
## target is 0.
func _send_initial_state(target_net_id: int) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		print("[%s] Initial sync skipped: no edited scene" % PLUGIN_NAME)
		_send_crdt_state(target_net_id)
		return

	print("[%s] Sending initial scene state to net_id=%d..." % [PLUGIN_NAME, target_net_id])
	# One scene_state packet carries SCENE_STATE_CHUNK_NODES nodes, each with
	# its node_add data, every sync-worthy property and its script, instead of
	# one packet per node and one more per property.
	var nodes := _get_all_scene_nodes(root)
	var entries: Array = []
	var packets := 0

	for node in nodes:
		var is_root := node == root
		var rel_path := "." if is_root else str(root.get_path_to(node))
		var entry := {"node_path": rel_path}

		# The root already exists on the joiner side: only its properties travel.
		var is_instance_root := not is_root and not str(node.scene_file_path).is_empty()
		if not is_root:
			var parent := node.get_parent()
			var add_data := {
				"parent_path": str(root.get_path_to(parent)),
				"node_type": node.get_class(),
				"node_name": str(node.name),
				"child_index": node.get_index(),
			}
			# Instanced sub-scene: carry the PackedScene path so the joiner
			# re-instantiates the whole sub-scene rather than a bare node.
			if is_instance_root:
				add_data["scene_instance"] = str(node.scene_file_path)
			entry["add"] = add_data

		var props := {}
		for prop_name in _get_sync_properties(node):
			var encoded: Dictionary = ActionSerializerClass.encode_property_value(node.get(prop_name))
			if bool(encoded.get("ok", false)):
				props[prop_name] = encoded.get("value")
		entry["props"] = props

		# Skip instance roots: their script ships with the PackedScene the
		# joiner instantiates, so re-attaching it here would be redundant
		# (and could clobber a scene-local script override).
		var node_script = node.get_script()
		if node_script and node_script is Script and not is_instance_root:
			entry["script"] = {
				"script_path": node_script.resource_path,
				"script_content": node_script.source_code,
			}

		entries.append(entry)
		if entries.size() >= SCENE_STATE_CHUNK_NODES:
			_send_scene_state(target_net_id, root, entries)
			entries = []
			packets += 1

	if not entries.is_empty():
		_send_scene_state(target_net_id, root, entries)
		packets += 1
	print("[%s] Initial sync sent: %d nodes in %d packets" % [PLUGIN_NAME, nodes.size(), packets])

	var guides_action := {
		"type": "scene_guides",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"scene_path": root.scene_file_path,
		"node_path": ".",
		"data": _build_scene_guides_payload(root),
	}
	_send_packet_to(target_net_id, ActionSerializerClass.serialize(guides_action))

	_send_crdt_state(target_net_id)


func _send_scene_state(target_net_id: int, root: Node, entries: Array) -> void:
	var action := {
		"type": "scene_state",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"scene_path": root.scene_file_path,
		"node_path": ".",
		"data": {"nodes": entries},
	}
	_send_packet_to(target_net_id, ActionSerializerClass.serialize(action))


## Send every known CRDT buffer to one peer, or to all peers when target is 0.
## Kept separate from scene sync so promotion recovery also works when no scene
## is currently open in the promoted editor.
func _send_crdt_state(target_net_id: int) -> void:
	if _script_sync:
		var buffers: Dictionary = _script_sync.export_all_buffers()
		for script_path in buffers:
			var sync_action := {
				"type": "crdt_sync",
				"peer_id": _local_peer_id,
				"timestamp": Time.get_unix_time_from_system(),
				"node_path": script_path,
				"data": buffers[script_path],
			}
			_send_packet_to(target_net_id, ActionSerializerClass.serialize(sync_action))
		print("[%s] Initial sync sent: %d script buffers" % [PLUGIN_NAME, buffers.size()])


## Returns the list of property names worth syncing for a given node.
## We sync transform-related properties and visibility by default.
func _get_sync_properties(node: Node) -> Array[String]:
	var props: Array[String] = []

	if node is Node3D or node is Node2D:
		props.append_array(["position", "rotation", "scale"])

	# Control nodes — layout anchors + offsets (position/size) + transform
	if node is Control:
		# layout_mode MUST be first — it determines how anchors/offsets/size are interpreted.
		# If applied last, Godot recalculates size from anchors and overrides the synced size.
		props.append_array([
			"layout_mode",
			"anchor_left", "anchor_right", "anchor_top", "anchor_bottom",
			"offset_left", "offset_right", "offset_top", "offset_bottom",
			"rotation", "scale", "pivot_offset", "size",
			"custom_minimum_size",
			"size_flags_horizontal", "size_flags_vertical",
			"grow_horizontal", "grow_vertical"])

	# BoxContainer (HBoxContainer / VBoxContainer)
	if node is BoxContainer:
		props.append_array(["vertical", "alignment"])

	# Properties that only apply when present — checked via _has_property so
	# they work for any CanvasItem subclass (Node2D, Control, etc.) and any
	# AudioStreamPlayer variant without needing an explicit `is` check.
	for prop_name in ["visible", "modulate", "self_modulate",
			"text", "placeholder_text", "button_pressed",
			"stream", "volume_db"]:
		if _has_property(node, prop_name):
			if not props.has(prop_name):
				props.append(prop_name)
	for prop_name in _get_material_resource_props(node):
		if not props.has(prop_name):
			props.append(prop_name)

	if node is Sprite2D or node is Sprite3D:
		props.append("texture")

	if node is AnimatedSprite2D or node is AnimatedSprite3D:
		props.append_array(_get_animated_sprite_sync_props(node))

	# ColorRect
	if node is ColorRect:
		props.append("color")

	# TextureRect texture
	if node is TextureRect:
		if _has_property(node, "texture"):
			props.append("texture")

	# Range-based controls: ProgressBar, HSlider, VSlider, SpinBox
	if node is Range:
		props.append_array(["value", "min_value", "max_value"])

	# Camera2D
	if node is Camera2D:
		if _has_property(node, "zoom"):
			props.append("zoom")
		if _has_property(node, "offset"):
			props.append("offset")

	# Camera3D
	if node is Camera3D:
		if _has_property(node, "fov"):
			props.append("fov")
		props.append_array(["near", "far"])

	# MeshInstance2D: mesh + texture
	if node is MeshInstance2D:
		props.append_array(["mesh", "texture"])

	# MeshInstance3D: mesh
	if node is MeshInstance3D:
		props.append("mesh")

	# MultiMeshInstance2D / MultiMeshInstance3D
	if node is MultiMeshInstance2D or node is MultiMeshInstance3D:
		props.append("multimesh")

	# Light2D (PointLight2D, DirectionalLight2D)
	if node is Light2D:
		props.append_array(["color", "energy", "enabled"])
	if node is PointLight2D:
		props.append("texture")

	# Light3D (OmniLight3D, SpotLight3D, DirectionalLight3D)
	if node is Light3D:
		props.append_array(["light_color", "light_energy"])
	if node is OmniLight3D:
		props.append("omni_range")
	if node is SpotLight3D:
		props.append_array(["spot_range", "spot_angle"])

	# AnimationPlayer
	if node is AnimationPlayer:
		props.append_array(_get_animation_player_sync_props(node as AnimationPlayer))
		props.append_array(_get_animation_library_props(node as AnimationPlayer))

	# CollisionShape2D / CollisionShape3D
	if node is CollisionShape2D or node is CollisionShape3D:
		props.append_array(["shape", "disabled"])

	return props


func _get_animation_library_props(player: AnimationPlayer) -> Array[String]:
	var props: Array[String] = []
	for prop in player.get_property_list():
		var prop_name := String(prop.get("name", ""))
		if prop_name.begins_with("libraries/") and not props.has(prop_name):
			props.append(prop_name)
	return props


func _get_animation_player_sync_props(player: AnimationPlayer) -> Array[String]:
	var props: Array[String] = []
	for prop_name in ANIMATION_PLAYER_SYNC_PROPERTIES:
		if _has_property(player, prop_name) and not props.has(prop_name):
			props.append(prop_name)
	return props


func _get_animated_sprite_sync_props(node: Node) -> Array[String]:
	var props: Array[String] = []
	if not (node is AnimatedSprite2D or node is AnimatedSprite3D):
		return props
	for prop_name in ANIMATED_SPRITE_SYNC_PROPERTIES:
		if _has_property(node, prop_name) and not props.has(prop_name):
			props.append(prop_name)
	return props


func _get_material_resource_props(node: Node) -> Array[String]:
	# Same list get_property_list() would give, without building it: that list
	# has hundreds of entries for a Control and this runs for every node.
	var props: Array[String] = []
	if node is MeshInstance3D:
		for i in (node as MeshInstance3D).get_surface_override_material_count():
			props.append("surface_material_override/%d" % i)
	for prop_name in ["material", "material_override", "material_overlay", "process_material"]:
		if prop_name in node:
			props.append(prop_name)
	return props


func _build_scene_guides_payload(root: Node) -> Dictionary:
	return {
		"vertical": _normalize_guides_array(root.get_meta(META_VERTICAL_GUIDES, [])),
		"horizontal": _normalize_guides_array(root.get_meta(META_HORIZONTAL_GUIDES, [])),
	}


static func _normalize_guides_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for item in value:
			if typeof(item) == TYPE_INT or typeof(item) == TYPE_FLOAT:
				result.append(float(item))
	return result


func _has_property(node: Node, property_name: String) -> bool:
	return property_name in node


## Recursively collect all nodes belonging to the edited scene.
func _get_all_scene_nodes(root: Node) -> Array[Node]:
	var result: Array[Node] = [root]
	for child in root.get_children():
		if child.owner == root:
			result.append(child)
			_collect_scene_children(child, root, result)
	return result


func _collect_scene_children(node: Node, root: Node, result: Array[Node]) -> void:
	for child in node.get_children():
		if child.owner == root:
			result.append(child)
			_collect_scene_children(child, root, result)


# ═════════════════════════════════════════════════════════════════════
#  Editor Dock
# ═════════════════════════════════════════════════════════════════════

func _init_dock() -> void:
	_dock = _instantiate_addon_script("ui/godot_with_u_dock.gd", "GodotWithUDock") as Control
	if _dock == null:
		return
	_dock.host_requested.connect(_do_host)
	_dock.join_requested.connect(_do_join)
	_dock.stop_requested.connect(_do_stop)
	_dock.auth_requested.connect(_on_dock_auth_requested)
	_dock.generate_token_requested.connect(_on_dock_generate_token_requested)
	_dock.refresh_rooms_requested.connect(_on_dock_refresh_rooms_requested)
	_dock.disconnect_requested.connect(_on_dock_disconnect_requested)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	_refresh_dock_session_state()


func _teardown_dock() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _refresh_dock_session_state() -> void:
	var active := _mode != ""
	var transport := ""
	if _network_manager != null and _network_manager.has_method("get_transport"):
		transport = String(_network_manager.get_transport()).strip_edges()

	# Publish session state to EditorSettings so other addons (e.g. ServerProjectTree)
	# can read it without holding any direct reference to this plugin or its dock.
	var es := EditorInterface.get_editor_settings()
	es.set_setting("godot_with_u/session_active",    active)
	es.set_setting("godot_with_u/session_room",      _current_room if active else "")
	es.set_setting("godot_with_u/session_peer_id",   _local_peer_id if active else "")
	es.set_setting("godot_with_u/session_peer_name", _local_peer_name if active else "")

	if _dock == null or not _dock.has_method("set_session_state"):
		return

	_dock.set_session_state({
		"active": active,
		"mode": _mode,
		"transport": transport,
		"room": _current_room,
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"peer_count": _connected_transport_peer_count,
	})


# ═════════════════════════════════════════════════════════════════════
#  Scene Change Sync
# ═════════════════════════════════════════════════════════════════════

## Called when the local editor switches to a different scene.
func _on_own_scene_changed(scene_root: Node) -> void:
	if _mode == "":
		return
	var scene_path := scene_root.scene_file_path if scene_root else ""
	# Announce the scene change to all peers.
	var announce := {
		"type": "scene_opened",
		"peer_id": _local_peer_id,
		"peer_name": _local_peer_name,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {"scene_path": scene_path},
	}
	_send_packet(ActionSerializerClass.serialize(announce))
	# Always activate the scene sync guard when connected to a session.
	# Remote peers who already have this scene open will respond with their
	# authoritative state and clear the guard immediately. If no one has the
	# scene open the guard simply expires after ~2 s (40 ticks × 50 ms).
	# This prevents B's freshly-loaded (default) node positions from being
	# broadcast to peer A and corrupting A's work.
	if _interceptor and not scene_path.is_empty():
		_interceptor.set_scene_sync_guard()
	# Do NOT push state from the peer who just opened the file — it may have
	# a fresh/empty copy. Peers who already have this scene open will receive
	# the scene_opened packet above and respond with their authoritative state.


## Reverse lookup: peer_id String → network transport ID int, or -1 if unknown.
func _get_net_id_for_peer(peer_id: String) -> int:
	for net_id in _net_id_to_peer_id:
		if String(_net_id_to_peer_id[net_id]) == peer_id:
			return net_id
	return -1


# ═════════════════════════════════════════════════════════════════════
#  File Sync
# ═════════════════════════════════════════════════════════════════════

func _on_filesystem_changed() -> void:
	if _mode == "":
		return
	var all_sync: bool   = _dock != null and _dock.is_all_sync_enabled()
	var scene_sync: bool = all_sync or (_dock != null and _dock.is_file_sync_enabled())
	var gd_sync: bool    = all_sync or (_dock != null and _dock.is_gd_sync_enabled())
	if not all_sync and not scene_sync and not gd_sync:
		_received_file_paths.clear()
		return
	var current := _scan_all_files()
	var old_snapshot := _file_snapshot
	_file_snapshot = current  # update first to prevent double-send
	for path in current:
		if not old_snapshot.has(path) and not _received_file_paths.has(path):
			if all_sync:
				_send_file_create(path)
			elif _is_scene_file(path) and scene_sync:
				_send_file_create(path)
			elif _is_gd_file(path) and gd_sync:
				_send_file_create(path)
		elif old_snapshot.has(path) and current[path] != old_snapshot[path] \
				and not _received_file_paths.has(path):
			if all_sync:
				_send_file_create(path)
			elif _is_scene_file(path) and scene_sync:
				_send_file_create(path)
			elif _is_gd_file(path) and gd_sync:
				_send_file_create(path)
	for path in old_snapshot:
		if not current.has(path) and not _received_file_paths.has(path):
			if all_sync:
				_send_file_delete(path)
			elif _is_scene_file(path) and scene_sync:
				_send_file_delete(path)
			elif _is_gd_file(path) and gd_sync:
				_send_file_delete(path)
	_received_file_paths.clear()


func _scan_all_files() -> Dictionary:
	var result: Dictionary = {}
	var dir := EditorInterface.get_resource_filesystem().get_filesystem()
	if dir:
		_scan_fs_dir(dir, result)
	return result


func _scan_fs_dir(dir: EditorFileSystemDirectory, result: Dictionary) -> void:
	for i in dir.get_file_count():
		var path := dir.get_file_path(i)
		if _should_sync_file(path):
			result[path] = _file_snapshot_value(path)
	for i in dir.get_subdir_count():
		var subdir := dir.get_subdir(i)
		if subdir.get_name() != ".godot":
			_scan_fs_dir(subdir, result)


func _should_sync_file(path: String) -> bool:
	return not path.ends_with(".import") and not path.begins_with("res://.godot/")


func _is_scene_file(path: String) -> bool:
	return path.ends_with(".tscn") or path.ends_with(".tres") or path.ends_with(".res")


func _is_gd_file(path: String) -> bool:
	return path.ends_with(".gd") \
		or _is_shader_file(path)


func _is_shader_file(path: String) -> bool:
	return path.ends_with(".gdshader") \
		or path.ends_with(".gdshaderinc")


func _file_snapshot_value(path: String) -> String:
	var modified_time := 0
	if FileAccess.file_exists(path):
		modified_time = int(FileAccess.get_modified_time(path))
	var size := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		size = int(file.get_length())
		file.close()
	return "%d:%d" % [modified_time, size]


func _send_file_create(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var size := file.get_length()
	if size > FILE_SYNC_SIZE_LIMIT:
		push_warning("[%s] File too large to sync (%d bytes): %s" % [PLUGIN_NAME, size, path])
		file.close()
		return
	var content := file.get_buffer(size)
	file.close()
	var action := {
		"type": "file_create",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {"path": path, "content": content},
	}
	_send_packet(ActionSerializerClass.serialize(action))
	print("[%s] FILE SYNC: create %s (%d bytes)" % [PLUGIN_NAME, path, size])


func _send_file_delete(path: String) -> void:
	var action := {
		"type": "file_delete",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {"path": path},
	}
	_send_packet(ActionSerializerClass.serialize(action))
	print("[%s] FILE SYNC: delete %s" % [PLUGIN_NAME, path])


func _apply_file_create(action: Dictionary) -> void:
	var data: Dictionary = action.get("data", {})
	var path: String = data.get("path", "")
	var content: PackedByteArray = data.get("content", PackedByteArray())
	if path.is_empty() or not path.begins_with("res://"):
		return
	if ".." in path:
		push_warning("[%s] Rejected file_create: suspicious path '%s'" % [PLUGIN_NAME, path])
		return
	_received_file_paths[path] = true
	if _file_content_matches(path, content):
		_file_snapshot[path] = _file_snapshot_value(path)
		print("[%s] FILE SYNC: skipped identical write %s" % [PLUGIN_NAME, path])
		return
	if _should_skip_live_scene_file_write(path):
		print("[%s] FILE SYNC: skipped live scene write %s" % [PLUGIN_NAME, path])
		return
	if _should_skip_live_text_file_write(path, content):
		print("[%s] FILE SYNC: skipped live editor write %s" % [PLUGIN_NAME, path])
		return
	var dir_abs := ProjectSettings.globalize_path(path.get_base_dir())
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_warning("[%s] FILE SYNC: cannot write '%s'" % [PLUGIN_NAME, path])
		_received_file_paths.erase(path)
		return
	file.store_buffer(content)
	file.close()
	EditorInterface.get_resource_filesystem().update_file(path)
	_file_snapshot[path] = _file_snapshot_value(path)
	if _is_shader_file(path):
		_refresh_shader_file_references(path)
		call_deferred("_refresh_shader_file_references", path)
	print("[%s] FILE SYNC: received create %s (%d bytes)" % [PLUGIN_NAME, path, content.size()])


func _file_content_matches(path: String, content: PackedByteArray) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var existing := file.get_buffer(file.get_length())
	file.close()
	return existing == content


func _should_skip_live_scene_file_write(path: String) -> bool:
	if not _is_scene_file(path):
		return false
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return false
	return root.scene_file_path == path


func _should_skip_live_text_file_write(path: String, content: PackedByteArray) -> bool:
	if not _is_gd_file(path):
		return false
	if not _script_sync or not _script_sync.has_buffer(path):
		return false
	var incoming_text := content.get_string_from_utf8()
	if incoming_text.is_empty() and not content.is_empty():
		return false
	var buffer_text := String(_script_sync.get_buffer_text(path))
	return _normalize_text_for_compare(buffer_text) == _normalize_text_for_compare(incoming_text)


func _normalize_text_for_compare(text: String) -> String:
	return text.replace("\r\n", "\n").replace("\r", "\n")


func _refresh_shader_file_references(path: String) -> void:
	var shader := ResourceLoader.load(path, "Shader", ResourceLoader.CACHE_MODE_REPLACE) as Shader
	if not shader:
		shader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as Shader
	if not shader:
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return

	var updated_count := 0
	for node in _get_all_scene_nodes(root):
		for prop in _get_material_resource_props(node):
			var value: Variant = node.get(prop)
			if value is Shader and String((value as Shader).resource_path) == path:
				node.set(prop, shader)
				node.notify_property_list_changed()
				updated_count += 1
			elif _replace_shader_resource_reference(value, shader, path):
				node.notify_property_list_changed()
				updated_count += 1

	if updated_count > 0:
		print("[%s] FILE SYNC: refreshed shader references for %s (%d)" % [
			PLUGIN_NAME, path, updated_count])


func _replace_shader_resource_reference(value: Variant, shader: Shader,
		path: String, depth: int = 0) -> bool:
	if depth >= 4:
		return false
	if value is ShaderMaterial:
		var material := value as ShaderMaterial
		if material.shader and String(material.shader.resource_path) == path:
			material.shader = shader
			return true
		return false
	if not (value is Resource):
		return false

	var changed := false
	var resource := value as Resource
	for prop in resource.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var prop_name := String(prop.get("name", ""))
		if prop_name in ["script", "resource_path", "resource_name"]:
			continue
		var prop_value: Variant = resource.get(prop_name)
		if prop_value is Shader and String((prop_value as Shader).resource_path) == path:
			resource.set(prop_name, shader)
			changed = true
		elif _replace_shader_resource_reference(prop_value, shader, path, depth + 1):
			changed = true
	return changed


func _apply_file_delete(action: Dictionary) -> void:
	var data: Dictionary = action.get("data", {})
	var path: String = data.get("path", "")
	if path.is_empty() or not path.begins_with("res://"):
		return
	if ".." in path:
		push_warning("[%s] Rejected file_delete: suspicious path '%s'" % [PLUGIN_NAME, path])
		return
	_received_file_paths[path] = true
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)
		# Clean up the .import sidecar file if present
		var import_path := path + ".import"
		if FileAccess.file_exists(import_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(import_path))
	_file_snapshot.erase(path)
	EditorInterface.get_resource_filesystem().scan()
	print("[%s] FILE SYNC: received delete %s" % [PLUGIN_NAME, path])


# ═════════════════════════════════════════════════════════════════════
#  Authentication
# ═════════════════════════════════════════════════════════════════════

## Picks what to send as the relay's `auth_token`, from the auth mode the relay
## announced for this URL (config "relay_auth_mode", "" when it never said).
## The join is always attempted, even with nothing to send: the relay's answer,
## welcome or refusal, is what keeps the remembered mode up to date when a
## relay's owner changes it. ENet has no relay and sends nothing.
func _relay_token(config: Dictionary) -> String:
	if String(config.get("transport", NETWORK_TRANSPORT_WEBSOCKET)) != NETWORK_TRANSPORT_WEBSOCKET:
		return ""
	var server_url := _migrate_relay_url(String(config.get("server_url", NETWORK_DEFAULT_WS_URL)))
	var password := String(config.get("relay_password", "")).strip_edges()
	var backend_token := _backend_token_for_relay(server_url)
	match String(config.get("relay_auth_mode", "")):
		RELAY_AUTH_NONE:
			return ""
		RELAY_AUTH_PASSWORD:
			return password
		RELAY_AUTH_BACKEND:
			return backend_token
	# Mode unknown: offer what we have.
	return backend_token if not backend_token.is_empty() else password


## The Godot Manager token, but only for a relay run by the server that issued it
## (same host as the backend URL), its explicit trusted relay, or this machine.
## Any other relay could claim to need a backend login just to collect tokens,
## so it gets "".
func _backend_token_for_relay(relay_url: String) -> String:
	if _auth_bearer_token.is_empty() or _auth_client == null:
		return ""
	var relay_host := _url_host(relay_url)
	if relay_host.is_empty():
		return ""
	if LOCAL_HOSTS.has(relay_host):
		return _auth_bearer_token
	var settings: Dictionary = _auth_client.load_settings()
	var backend_url := String(settings.get("backend_url", "")).strip_edges().trim_suffix("/")
	# Only this exact secure relay may receive a Studio token across domains.
	if backend_url == "https://studio.godaas.org" \
			and relay_url.strip_edges() == NETWORK_DEFAULT_WS_URL:
		return _auth_bearer_token
	if relay_host == _url_host(backend_url):
		return _auth_bearer_token
	return ""


func _backend_login_hint(relay_url: String) -> String:
	if _auth_bearer_token.is_empty():
		return "This relay needs a Godot Manager login. Authenticate above, then Join again."
	var backend_host := ""
	if _auth_client != null:
		backend_host = _url_host(String(_auth_client.load_settings().get("backend_url", "")))
	return "Your login belongs to %s, so it is not sent to the relay at %s." % [
		backend_host, _url_host(relay_url)]


func _show_relay_auth_needed(relay_url: String, mode: String, message: String) -> void:
	if _dock:
		_dock.show_relay_auth_needed(relay_url, mode, message)


## Host part of a URL, lower case, without port or brackets ("" if none).
static func _url_host(url: String) -> String:
	var rest := url.strip_edges().to_lower()
	var scheme_end := rest.find("://")
	if scheme_end != -1:
		rest = rest.substr(scheme_end + 3)
	for separator in ["/", "?", "#"]:
		var cut := rest.find(separator)
		if cut != -1:
			rest = rest.substr(0, cut)
	var at := rest.rfind("@")
	if at != -1:
		rest = rest.substr(at + 1)
	if rest.begins_with("["):
		var closing := rest.find("]")
		return rest.substr(1, closing - 1) if closing != -1 else ""
	var colon := rest.rfind(":")
	return rest.substr(0, colon) if colon != -1 else rest


## Preserve custom endpoints while migrating the former hosted address.
static func _migrate_relay_url(value: String) -> String:
	var url := value.strip_edges()
	if url.trim_suffix("/") == "wss://studio.godaas.org/ws-relay":
		return NETWORK_DEFAULT_WS_URL
	return url


## Studio uses its independent relay; other backends keep their own endpoint.
static func _relay_url_for_backend(backend_url: String) -> String:
	var url := backend_url.strip_edges()
	while url.ends_with("/"):
		url = url.trim_suffix("/")
	if url == "https://studio.godaas.org":
		return NETWORK_DEFAULT_WS_URL
	if url.begins_with("https://"):
		return "wss://" + url.trim_prefix("https://") + "/ws-relay"
	if url.begins_with("http://"):
		return "ws://" + url.trim_prefix("http://") + "/ws-relay"
	return NETWORK_DEFAULT_WS_URL


func _try_silent_authenticate() -> void:
	if _auth_client == null or _dock == null:
		return
	var settings: Dictionary = _auth_client.load_settings()
	_dock.set_auth_settings(settings)
	var token := String(settings.get("api_token", "")).strip_edges()
	var mode := String(settings.get("auth_mode", "api_token"))
	if mode != "api_token" or token.is_empty():
		_dock.set_authenticated(false)
		_dock.set_auth_status(
			"Not authenticated. Add connection information and click Authenticate.", "info")
		return
	_dock.set_auth_busy(true)
	_dock.set_auth_status("Verifying saved token...", "info")
	var result: Dictionary = await _auth_client.ensure_authenticated(settings, "")
	_dock.set_auth_busy(false)
	_apply_auth_result(result)


func _on_dock_disconnect_requested() -> void:
	_auth_bearer_token = ""
	_auth_user = {}
	if _dock != null:
		_dock.set_authenticated(false)
		_dock.set_auth_status("Disconnected.", "info")


func _on_dock_refresh_rooms_requested() -> void:
	if _auth_busy or _auth_client == null or _dock == null:
		return
	if _auth_bearer_token.is_empty() or _auth_user.is_empty():
		_dock.set_auth_status("Not authenticated — cannot refresh project list.", "error")
		return
	_auth_busy = true
	_dock.set_auth_busy(true)
	_dock.set_auth_status("Refreshing project list...", "info")
	await _resolve_project_and_lock(_auth_user)
	_dock.set_auth_busy(false)
	_auth_busy = false


func _on_dock_auth_requested(settings: Dictionary, password: String) -> void:
	if _auth_busy or _auth_client == null or _dock == null:
		return
	_auth_busy = true
	var saved: Dictionary = _auth_client.save_settings(settings)
	_dock.set_auth_settings(saved)
	_dock.set_auth_busy(true)
	_dock.set_auth_status("Authenticating...", "info")
	var result: Dictionary = await _auth_client.ensure_authenticated(saved, password)
	_dock.set_auth_busy(false)
	_auth_busy = false
	_apply_auth_result(result)


func _on_dock_generate_token_requested(settings: Dictionary) -> void:
	if _auth_busy or _auth_client == null or _dock == null:
		return
	_auth_busy = true
	_auth_client.save_settings(settings)
	_dock.set_auth_busy(true)
	_dock.set_auth_status("Generating API token...", "info")
	# Token generation requires an authenticated session: try saved settings first.
	var auth_result: Dictionary = await _auth_client.ensure_authenticated(settings, "")
	if not bool(auth_result.get("ok", false)):
		_dock.set_auth_busy(false)
		_auth_busy = false
		_dock.set_auth_status(String(auth_result.get(
			"error", "Authenticate first to generate a token.")), "error")
		return
	var gen_result: Dictionary = await _auth_client.generate_api_token(settings)
	_dock.set_auth_busy(false)
	_auth_busy = false
	if bool(gen_result.get("ok", false)):
		var new_settings: Dictionary = gen_result.get("settings", {})
		_dock.set_auth_settings(new_settings)
		_auth_bearer_token = String(gen_result.get("key", ""))
		_dock.set_authenticated(true)
		_dock.set_auth_status("API token generated and saved.", "success")
	else:
		_dock.set_auth_status(String(gen_result.get("error", "Token generation failed.")), "error")


func _apply_auth_result(result: Dictionary) -> void:
	if _dock == null:
		return
	if bool(result.get("ok", false)):
		_auth_bearer_token = String(result.get("token", ""))
		_dock.set_authenticated(true)
		var user: Dictionary = result.get("user", {})
		_auth_user = user
		var who := String(user.get("email", "")).strip_edges()
		if who.is_empty():
			who = String(user.get("name", "")).strip_edges()
		if who.is_empty():
			who = "user"
		_dock.set_auth_status("Authenticated as %s. Resolving project access..." % who, "info")
		await _resolve_project_and_lock(user)
	else:
		_auth_bearer_token = ""
		_auth_user = {}
		_dock.set_authenticated(false)
		_dock.set_auth_status(String(result.get("error", "Authentication failed.")), "error")


## After auth, fetch the user's project list and look up the backend project ID
## that matches the configured backend project name. Auto-fill and lock the connection
## fields (pseudo / transport / URL / room) when found.
func _resolve_project_and_lock(user: Dictionary) -> void:
	if _dock == null or _auth_client == null:
		return
	var settings: Dictionary = _auth_client.load_settings()
	var projects_result: Dictionary = await _auth_client.fetch_projects(settings)
	if not bool(projects_result.get("ok", false)):
		_auth_bearer_token = ""
		_dock.set_authenticated(false)
		_dock.set_auth_status(String(projects_result.get("error", "Failed to load projects.")), "error")
		return

	var local_project_name := String(
		ProjectSettings.get_setting("application/config/name", "")).strip_edges()
	var backend_project_name := String(settings.get("backend_project_name", "")).strip_edges()
	if backend_project_name.is_empty():
		backend_project_name = local_project_name
	if backend_project_name.is_empty():
		_auth_bearer_token = ""
		_dock.set_authenticated(false)
		_dock.set_auth_status("Backend project name is required.", "error")
		return

	var project_id: String = _auth_client.find_project_id_by_name(
		projects_result, backend_project_name)
	if project_id.is_empty():
		_auth_bearer_token = ""
		_dock.set_authenticated(false)
		_dock.set_auth_status(
			"No backend project matches '%s'. Check Backend project name in Settings."
				% backend_project_name,
			"error"
		)
		return

	var email := String(user.get("email", "")).strip_edges()
	if email.is_empty():
		email = String(user.get("name", "")).strip_edges()
	_local_peer_name = email
	# Flatten owned + shared projects into a single list for the room dropdown.
	var all_projects: Array = []
	var owned_projects = projects_result.get("projects", [])
	var shared_projects = projects_result.get("shared", [])
	if owned_projects is Array:
		all_projects.append_array(owned_projects)
	if shared_projects is Array:
		all_projects.append_array(shared_projects)
	# Join the relay of the backend that issued the token: the only relay that can
	# check it, and the only one _backend_token_for_relay will hand it to.
	var relay_url := _relay_url_for_backend(String(settings.get("backend_url", "")))
	_dock.apply_user_auth(email, project_id, relay_url, all_projects)
	_dock.remember_relay_auth_mode(relay_url, RELAY_AUTH_BACKEND)
	_dock.set_auth_status("Authenticated as %s — project '%s' ready." % [
		email, backend_project_name], "success")


## Warns once per peer and session when it speaks another protocol. Such a
## session looks connected while the scene state cannot get through, so the
## user would otherwise see nothing at all. Only this side can warn when the
## other runs 0.7 or older: those versions do not check.
func _check_peer_protocol(peer_id: String, peer_name: String, handshake: Dictionary) -> void:
	var remote_protocol := int(handshake.get("protocol", 1))
	if remote_protocol == PROTOCOL_VERSION or _protocol_warned.has(peer_id):
		return
	_protocol_warned[peer_id] = true
	var who := _peer_display_name(peer_id, peer_name)
	var remote_version := String(handshake.get("plugin_version", "0.7 or older"))
	var title := "⚠ %s uses GodotWithU %s, you use %s: scenes will not sync" % [
		who, remote_version, PLUGIN_VERSION]
	var details := ""
	if remote_protocol < PROTOCOL_VERSION:
		details = ("%s has the older addon. Update GodotWithU in that project (or editor), "
			+ "then restart the editor.") % who
	else:
		details = ("This editor has the older addon. Update GodotWithU in this project, "
			+ "then restart the editor.")
	push_warning("[%s] Protocol mismatch with %s: theirs %d (%s), ours %d (%s). %s" % [
		PLUGIN_NAME, who, remote_protocol, remote_version, PROTOCOL_VERSION, PLUGIN_VERSION, details])
	if Engine.is_editor_hint():
		var toaster := EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(title, EditorToaster.SEVERITY_ERROR, details)


func _show_peer_notification_toast(
		sender_peer_id: String, sender_peer_name: String, data: Dictionary) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var kind := String(data.get("kind", "")).strip_edges()
	if kind.is_empty():
		return
	var payload: Dictionary = data.get("payload", {}) \
			if typeof(data.get("payload", {})) == TYPE_DICTIONARY else {}
	var who := _peer_display_name(sender_peer_id, sender_peer_name)

	var title := ""
	var details := ""
	match kind:
		"new_local_file":
			var files_value = payload.get("files", [])
			var files: Array = files_value if typeof(files_value) == TYPE_ARRAY else []
			var count := files.size()
			if count == 0:
				return
			var first := String(files[0])
			if count == 1:
				title = "%s added a new file" % who
				details = first
			else:
				title = "%s added %d new files" % [who, count]
				var preview: Array = []
				for i in range(min(3, count)):
					preview.append(String(files[i]))
				details = ", ".join(preview)
				if count > preview.size():
					details += " (+%d more)" % (count - preview.size())
		"deleted_local_file":
			var del_files_value = payload.get("files", [])
			var del_files: Array = del_files_value if typeof(del_files_value) == TYPE_ARRAY else []
			var del_count := del_files.size()
			if del_count == 0:
				return
			var del_first := String(del_files[0])
			if del_count == 1:
				title = "%s deleted a file" % who
				details = del_first
			else:
				title = "%s deleted %d files" % [who, del_count]
				var del_preview: Array = []
				for i in range(min(3, del_count)):
					del_preview.append(String(del_files[i]))
				details = ", ".join(del_preview)
				if del_count > del_preview.size():
					details += " (+%d more)" % (del_count - del_preview.size())
		"renamed_local_file":
			var renames_value = payload.get("renames", [])
			var renames: Array = renames_value if typeof(renames_value) == TYPE_ARRAY else []
			var ren_count := renames.size()
			if ren_count == 0:
				return
			var first_entry: Dictionary = renames[0] if typeof(renames[0]) == TYPE_DICTIONARY else {}
			var first_pair := "%s → %s" % [
				String(first_entry.get("from", "")),
				String(first_entry.get("to", "")),
			]
			if ren_count == 1:
				title = "%s renamed a file" % who
				details = first_pair
			else:
				title = "%s renamed %d files" % [who, ren_count]
				var ren_preview: Array = []
				for i in range(min(3, ren_count)):
					var entry_dict: Dictionary = renames[i] if typeof(renames[i]) == TYPE_DICTIONARY else {}
					ren_preview.append("%s → %s" % [
						String(entry_dict.get("from", "")),
						String(entry_dict.get("to", "")),
					])
				details = "\n".join(ren_preview)
				if ren_count > ren_preview.size():
					details += "\n(+%d more)" % (ren_count - ren_preview.size())
		"new_local_dir":
			var dirs_value = payload.get("dirs", [])
			var dirs: Array = dirs_value if typeof(dirs_value) == TYPE_ARRAY else []
			var dir_count := dirs.size()
			if dir_count == 0:
				return
			var dir_first := String(dirs[0])
			if dir_count == 1:
				title = "%s created a new directory" % who
				details = dir_first
			else:
				title = "%s created %d new directories" % [who, dir_count]
				var dir_preview: Array = []
				for i in range(min(3, dir_count)):
					dir_preview.append(String(dirs[i]))
				details = ", ".join(dir_preview)
				if dir_count > dir_preview.size():
					details += " (+%d more)" % (dir_count - dir_preview.size())
		_:
			title = "%s: %s" % [who, kind]
			var raw_text := String(payload.get("message", "")).strip_edges()
			details = raw_text

	if Engine.is_editor_hint():
		var toaster := EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(title, EditorToaster.SEVERITY_INFO, details)
