@tool
extends EditorPlugin
## GodotWithU v0.5.0 — Real-time collaborative workspace for Godot Editor.
##
## Dual-mode networking:
## - LOCAL: TCP relay on localhost (Host/Join, works on same machine)
## - P2P: BitChat mesh network (cross-machine, when available)
##
## IMPORTANT: After making changes to ANY plugin GDScript file, you MUST
## completely restart BOTH Godot Editor instances. The .godot/ script cache
## may keep the old version loaded in memory. Disable/re-enable the plugin
## or close and reopen both editors to ensure they run the same code.

# ── Preloads ─────────────────────────────────────────────────────────
const ActionInterceptorClass = preload("res://addons/godot_with_u/actions/action_interceptor.gd")
const ActionSerializerClass  = preload("res://addons/godot_with_u/actions/action_serializer.gd")
const LockManagerClass       = preload("res://addons/godot_with_u/locking/lock_manager.gd")
const LockOverlayClass       = preload("res://addons/godot_with_u/locking/lock_overlay.gd")
const ScriptInterceptorClass = preload("res://addons/godot_with_u/crdt/script_interceptor.gd")
const GhostCursorOverlayClass = preload("res://addons/godot_with_u/crdt/ghost_cursor_overlay.gd")
const DockClass              = preload("res://addons/godot_with_u/ui/godot_with_u_dock.gd")
const NetworkManagerClass    = preload("res://addons/godot_with_u/sync/network_manager.gd")

# ── Constants ────────────────────────────────────────────────────────
const PLUGIN_NAME    := "GodotWithU"
const PLUGIN_VERSION := "0.5.0"
const POLL_INTERVAL_SEC := 0.05
const SYNC_PENDING_TIMEOUT_SEC := 3.0

# ── State ────────────────────────────────────────────────────────────
var _network_manager: NetworkManager = null
var _poll_timer: Timer = null
var _interceptor: RefCounted = null
var _lock_manager: RefCounted = null
var _lock_overlay: RefCounted = null
var _script_sync: RefCounted = null
var _ghost_overlay: Control = null
var _dock: Control = null
var _local_peer_id: String = "peer_%s" % str(randi()).sha256_text().substr(0, 8)
var _mode: String = ""   # "host", "join", or ""

## Timestamp when _sync_pending was set; used for timeout fallback.
var _sync_pending_since: float = 0.0

## Maps ENet network peer IDs (int) to application-level peer IDs (String).
## Populated when receiving the first packet (handshake) from each peer.
var _net_id_to_peer_id: Dictionary = {}   ## int → String


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

	_lock_manager = LockManagerClass.new()
	_lock_overlay = LockOverlayClass.new()
	_lock_overlay.init(self, _lock_manager)

	_interceptor = ActionInterceptorClass.new()
	_interceptor.init(self)
	_interceptor.set_lock_manager(_lock_manager)
	_interceptor.action_captured.connect(_on_action_captured)

	_script_sync = ScriptInterceptorClass.new()
	_script_sync.init(self, _local_peer_id)
	_script_sync.crdt_op_generated.connect(_on_crdt_op)
	_script_sync.cursor_changed.connect(_on_cursor_changed)
	_script_sync.active_editor_changed.connect(_on_active_editor_changed)
	_script_sync.buffer_created.connect(_on_buffer_created)

	_ghost_overlay = GhostCursorOverlayClass.new()

	_init_dock()
	print("[%s] Ready — use the dock panel to Host or Join." % PLUGIN_NAME)


func _exit_tree() -> void:
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
	print("[%s] Plugin shut down." % PLUGIN_NAME)


# ═════════════════════════════════════════════════════════════════════
#  Host / Join / Stop — Pure GDScript NetworkManager
# ═════════════════════════════════════════════════════════════════════

func _do_host(port: int) -> void:
	if _mode != "": return

	_network_manager = NetworkManagerClass.new()
	var err: int = _network_manager.host(port)
	if err != OK:
		if _dock: _dock.set_disconnected()
		return

	_network_manager.peer_connected.connect(_on_peer_connected)
	_network_manager.peer_disconnected.connect(_on_peer_disconnected)
	_mode = "host"

	if _dock:
		_dock.set_connected("Hosting :%d" % port)
		_dock.update_info("v%s • %s • hosting" % [PLUGIN_VERSION, _local_peer_id])

	print("[%s] Hosting on port %d — peer_id: %s" % [PLUGIN_NAME, port, _local_peer_id])


func _do_join(ip: String, port: int) -> void:
	if _mode != "": return

	if ip.is_empty():
		ip = "127.0.0.1"

	# Clear stale local CRDT buffers and pause op generation until the
	# host sends its authoritative buffer state via crdt_sync.
	if _script_sync:
		_script_sync.clear_all_buffers()
		_script_sync.set_sync_pending(true)
		_sync_pending_since = Time.get_unix_time_from_system()

	_network_manager = NetworkManagerClass.new()
	var err: int = _network_manager.join(ip, port)
	if err != OK:
		if _dock: _dock.set_disconnected()
		_network_manager = null
		if _script_sync:
			_script_sync.set_sync_pending(false)
		return

	_network_manager.peer_connected.connect(_on_peer_connected)
	_network_manager.peer_disconnected.connect(_on_peer_disconnected)
	_mode = "join"

	if _dock:
		_dock.set_connected("Joined %s:%d" % [ip, port])
		_dock.update_info("v%s • %s • joined" % [PLUGIN_VERSION, _local_peer_id])

	print("[%s] Joined host at %s:%d — peer_id: %s" % [PLUGIN_NAME, ip, port, _local_peer_id])


func _do_stop() -> void:
	if _network_manager:
		_network_manager.stop()
		_network_manager = null
	_mode = ""
	_net_id_to_peer_id.clear()
	_sync_pending_since = 0.0
	if _script_sync:
		_script_sync.set_sync_pending(false)

	if _dock:
		_dock.set_disconnected()
		_dock.update_info("v%s" % PLUGIN_VERSION)


# ═════════════════════════════════════════════════════════════════════
#  Network Message Handling
# ═════════════════════════════════════════════════════════════════════

func _process_network_tick() -> void:
	if _network_manager and _network_manager.is_active():
		var packets = _network_manager.poll_messages()
		for entry in packets:
			var sender_net_id: int = entry[0]
			var packet: PackedByteArray = entry[1]
			_on_relay_message(sender_net_id, packet)

	# Timeout fallback: if no crdt_sync arrived within the timeout,
	# clear _sync_pending so the client can start editing normally.
	if _script_sync and _sync_pending_since > 0.0:
		var elapsed := Time.get_unix_time_from_system() - _sync_pending_since
		if elapsed >= SYNC_PENDING_TIMEOUT_SEC:
			_script_sync.set_sync_pending(false)
			_sync_pending_since = 0.0
			print("[%s] sync_pending timed out after %.1fs" % [PLUGIN_NAME, elapsed])

	# Periodically check for timed-out locks
	if _lock_manager:
		_lock_manager.check_timeouts()


func _send_packet(packet: PackedByteArray) -> void:
	if _network_manager and _mode != "":
		print("[%s] SEND: %d bytes" % [PLUGIN_NAME, packet.size()])
		_network_manager.broadcast_packet(packet)
	else:
		print("[%s] SEND SKIPPED: mode='%s' network_manager=%s" % [
			PLUGIN_NAME, _mode, _network_manager != null
		])


## Send a packet to a single specific peer (by ENet net_id).
func _send_packet_to(net_id: int, packet: PackedByteArray) -> void:
	if _network_manager and _mode != "":
		_network_manager.send_to_peer(net_id, packet)


func _on_relay_message(sender_net_id: int, data: PackedByteArray) -> void:
	print("[%s] RECV: %d bytes" % [PLUGIN_NAME, data.size()])
	var action: Dictionary = ActionSerializerClass.deserialize(data)
	if action.is_empty():
		print("[%s] RECV: deserialization failed!" % PLUGIN_NAME)
		return

	var action_type: String = action.get("type", "")
	var sender_peer_id: String = action.get("peer_id", "")

	print("[%s] RECV action: type=%s peer=%s (my_id=%s)" % [
		PLUGIN_NAME, action_type, sender_peer_id, _local_peer_id
	])

	# Skip own messages
	if sender_peer_id == _local_peer_id:
		print("[%s] RECV: skipped own message" % PLUGIN_NAME)
		return

	if action_type.is_empty():
		push_warning("[%s] RECV: missing action type" % PLUGIN_NAME)
		return

	# Map the ENet network ID to the application peer ID on first contact
	if not sender_peer_id.is_empty() and not _net_id_to_peer_id.has(sender_net_id):
		_net_id_to_peer_id[sender_net_id] = sender_peer_id
		if _dock: _dock.add_peer(sender_peer_id)
		print("[%s] Mapped net_id=%d → peer_id=%s" % [PLUGIN_NAME, sender_net_id, sender_peer_id])

	match action_type:
		"handshake":
			# Handshake is handled by the mapping logic above; nothing else to do
			print("[%s] Handshake received from %s" % [PLUGIN_NAME, sender_peer_id])
		"select", "property", "node_add", "node_delete":
			print("[%s] APPLYING: %s" % [PLUGIN_NAME, action.get("type")])
			if _interceptor:
				_interceptor.apply_remote_action(action)
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


func _on_peer_connected(peer_id: int) -> void:
	print("[%s] Peer connected (net_id=%d)" % [PLUGIN_NAME, peer_id])

	# Send a handshake so the remote peer can map our net_id → peer_id
	var handshake := {
		"type": "handshake",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
	}
	_send_packet(ActionSerializerClass.serialize(handshake))

	# When hosting, send the current scene state to the new joiner
	if _mode == "host":
		_send_initial_state(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	# Look up the application-level peer ID from the ENet network ID
	var app_peer_id: String = _net_id_to_peer_id.get(peer_id, "")
	if app_peer_id.is_empty():
		print("[%s] Peer disconnected (net_id=%d) — no handshake" % [
			PLUGIN_NAME, peer_id])
		return

	if _dock: _dock.remove_peer(app_peer_id)
	if _lock_manager: _lock_manager.release_all_for_peer(app_peer_id)
	if _ghost_overlay: _ghost_overlay.remove_peer(app_peer_id)
	_net_id_to_peer_id.erase(peer_id)
	print("[%s] Peer disconnected: %s (net_id=%d)" % [PLUGIN_NAME, app_peer_id, peer_id])


# ═════════════════════════════════════════════════════════════════════
#  Action / CRDT Handlers (local edits → broadcast)
# ═════════════════════════════════════════════════════════════════════

func _on_action_captured(action: Dictionary) -> void:
	action["peer_id"] = _local_peer_id
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_crdt_op(op: Dictionary, script_path: String) -> void:
	var action := {
		"type": "crdt",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": script_path,
		"data": op,
	}
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_buffer_created(script_path: String) -> void:
	if _mode == "":
		return   # Not connected, nothing to sync
	if not _script_sync:
		return
	var state: Dictionary = _script_sync.export_buffer(script_path)
	if state.is_empty():
		return
	var sync_action := {
		"type": "crdt_sync",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": script_path,
		"data": state,
	}
	_send_packet(ActionSerializerClass.serialize(sync_action))
	print("[%s] Broadcast crdt_sync for newly created buffer: %s" % [PLUGIN_NAME, script_path])



func _on_cursor_changed(data: Dictionary, script_path: String) -> void:
	var action := {
		"type": "cursor_update",
		"peer_id": _local_peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {
			"script_path": script_path,
			"line": data.get("line", 0),
			"column": data.get("column", 0),
		},
	}
	var packet: PackedByteArray = ActionSerializerClass.serialize(action)
	_send_packet(packet)


func _on_active_editor_changed(code_edit: CodeEdit, script_path: String) -> void:
	if _ghost_overlay:
		if _ghost_overlay.get_parent():
			_ghost_overlay.get_parent().remove_child(_ghost_overlay)
		code_edit.add_child(_ghost_overlay)
		_ghost_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_ghost_overlay.attach_to(code_edit, script_path)


# ═════════════════════════════════════════════════════════════════════
#  Initial State Sync — send current scene to newly joined peers
# ═════════════════════════════════════════════════════════════════════

## Called on the host when a new peer connects. Iterates the current
## edited scene root and sends node_add + property packets ONLY to the
## specified joiner (by ENet net_id) so existing peers are not affected.
func _send_initial_state(target_net_id: int) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		print("[%s] Initial sync skipped: no edited scene" % PLUGIN_NAME)
		return

	print("[%s] Sending initial scene state to net_id=%d..." % [PLUGIN_NAME, target_net_id])
	var nodes := _get_all_scene_nodes(root)
	var count := 0

	for node in nodes:
		if node == root:
			continue  # Don't send the root itself

		var rel_path := str(root.get_path_to(node))
		var parent := node.get_parent()
		var parent_rel := str(root.get_path_to(parent))

		# 1. Send node_add so the joiner creates any missing nodes
		var add_action := {
			"type": "node_add",
			"peer_id": _local_peer_id,
			"timestamp": Time.get_unix_time_from_system(),
			"node_path": rel_path,
			"data": {
				"parent_path": parent_rel,
				"node_type": node.get_class(),
				"node_name": str(node.name),
			},
		}
		_send_packet_to(target_net_id, ActionSerializerClass.serialize(add_action))

		# 2. Send key properties (transform, visibility, etc.)
		var props_to_sync := _get_sync_properties(node)
		for prop_name in props_to_sync:
			var value: Variant = node.get(prop_name)
			var prop_action := {
				"type": "property",
				"peer_id": _local_peer_id,
				"timestamp": Time.get_unix_time_from_system(),
				"node_path": rel_path,
				"data": {
					"property": prop_name,
					"value": value,
				},
			}
			_send_packet_to(target_net_id, ActionSerializerClass.serialize(prop_action))

		# 3. If node has a script attached, send script_attach
		var node_script = node.get_script()
		if node_script and node_script is Script:
			var script_attach_action := {
				"type": "script_attach",
				"peer_id": _local_peer_id,
				"timestamp": Time.get_unix_time_from_system(),
				"node_path": rel_path,
				"data": {
					"script_path": node_script.resource_path,
					"script_content": node_script.source_code,
				},
			}
			_send_packet_to(target_net_id, ActionSerializerClass.serialize(script_attach_action))

		count += 1

	print("[%s] Initial sync sent: %d nodes" % [PLUGIN_NAME, count])

	# Sync CRDT script buffer states so the joiner gets current script content
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

	if node is Node3D:
		props.append_array(["position", "rotation", "scale", "visible"])
	elif node is Node2D:
		props.append_array(["position", "rotation", "scale", "visible"])

	# Add common properties that exist on the node
	for p in ["modulate", "self_modulate"]:
		if node.get(p) != null:
			props.append(p)

	return props


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
	_dock = DockClass.new()
	_dock.host_requested.connect(_do_host)
	_dock.join_requested.connect(_do_join)
	_dock.stop_requested.connect(_do_stop)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)


func _teardown_dock() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
