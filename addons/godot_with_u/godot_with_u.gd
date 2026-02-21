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
const DockClass              = preload("res://addons/godot_with_u/ui/godot_with_u_dock.gd")
const NetworkManagerClass    = preload("res://addons/godot_with_u/sync/network_manager.gd")

# ── Constants ────────────────────────────────────────────────────────
const PLUGIN_NAME    := "GodotWithU"
const PLUGIN_VERSION := "0.5.0"
const POLL_INTERVAL_SEC := 0.05

# ── State ────────────────────────────────────────────────────────────
var _network_manager: NetworkManager = null
var _poll_timer: Timer = null
var _interceptor: RefCounted = null
var _lock_manager: RefCounted = null
var _lock_overlay: RefCounted = null
var _script_sync: RefCounted = null
var _dock: Control = null
var _local_peer_id: String = "peer_%d" % (randi() % 9999)
var _mode: String = ""   # "host", "join", or ""


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
		_script_sync.teardown()
		_script_sync = null

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


func _do_join(port: int) -> void:
	if _mode != "": return

	_network_manager = NetworkManagerClass.new()
	var err: int = _network_manager.join("127.0.0.1", port)
	if err != OK:
		if _dock: _dock.set_disconnected()
		_network_manager = null
		return

	_network_manager.peer_connected.connect(_on_peer_connected)
	_network_manager.peer_disconnected.connect(_on_peer_disconnected)
	_mode = "join"

	if _dock:
		_dock.set_connected("Joined :%d" % port)
		_dock.update_info("v%s • %s • joined" % [PLUGIN_VERSION, _local_peer_id])

	print("[%s] Joined host on port %d — peer_id: %s" % [PLUGIN_NAME, port, _local_peer_id])


func _do_stop() -> void:
	if _network_manager:
		_network_manager.stop()
		_network_manager = null
	_mode = ""

	if _dock:
		_dock.set_disconnected()
		_dock.update_info("v%s" % PLUGIN_VERSION)


# ═════════════════════════════════════════════════════════════════════
#  Network Message Handling
# ═════════════════════════════════════════════════════════════════════

func _process_network_tick() -> void:
	if _network_manager and _network_manager.is_active():
		var packets = _network_manager.poll_messages()
		for packet in packets:
			_on_relay_message(packet)


func _send_packet(packet: PackedByteArray) -> void:
	if _network_manager and _mode != "":
		print("[%s] SEND: %d bytes" % [PLUGIN_NAME, packet.size()])
		_network_manager.broadcast_packet(packet)
	else:
		print("[%s] SEND SKIPPED: mode='%s' network_manager=%s" % [PLUGIN_NAME, _mode, _network_manager != null])


func _on_relay_message(data: PackedByteArray) -> void:
	print("[%s] RECV: %d bytes" % [PLUGIN_NAME, data.size()])
	var action: Dictionary = ActionSerializerClass.deserialize(data)
	if action.is_empty():
		print("[%s] RECV: deserialization failed!" % PLUGIN_NAME)
		return

	print("[%s] RECV action: type=%s peer=%s (my_id=%s)" % [
		PLUGIN_NAME, action.get("type"), action.get("peer_id"), _local_peer_id
	])

	# Skip own messages
	if action.get("peer_id", "") == _local_peer_id:
		print("[%s] RECV: skipped own message" % PLUGIN_NAME)
		return

	match action.get("type", ""):
		"select", "property", "node_add", "node_delete":
			print("[%s] APPLYING: %s" % [PLUGIN_NAME, action.get("type")])
			if _interceptor:
				_interceptor.apply_remote_action(action)
		"crdt":
			if _script_sync:
				_script_sync.apply_remote_op(
					action.get("data", {}),
					action.get("node_path", "")
				)


func _on_peer_connected(peer_id: int) -> void:
	var peer_str := str(peer_id)
	if _dock: _dock.add_peer(peer_str)
	print("[%s] Peer connected: %s" % [PLUGIN_NAME, peer_str])

	# When hosting, send the current scene state to the new joiner
	if _mode == "host":
		_send_initial_state()


func _on_peer_disconnected(peer_id: int) -> void:
	var peer_str := str(peer_id)
	if _dock: _dock.remove_peer(peer_str)
	if _lock_manager: _lock_manager.release_all_for_peer(peer_str)
	print("[%s] Peer disconnected: %s" % [PLUGIN_NAME, peer_str])


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



# ═════════════════════════════════════════════════════════════════════
#  Initial State Sync — send current scene to newly joined peers
# ═════════════════════════════════════════════════════════════════════

## Called on the host when a new peer connects. Iterates the current
## edited scene root and broadcasts node_add + property packets so the
## joiner's scene tree matches the host's live state.
func _send_initial_state() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		print("[%s] Initial sync skipped: no edited scene" % PLUGIN_NAME)
		return

	print("[%s] Sending initial scene state..." % PLUGIN_NAME)
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
		_send_packet(ActionSerializerClass.serialize(add_action))

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
			_send_packet(ActionSerializerClass.serialize(prop_action))

		count += 1

	print("[%s] Initial sync sent: %d nodes" % [PLUGIN_NAME, count])


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
