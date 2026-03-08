@tool
class_name ActionInterceptor
extends RefCounted

## Hooks into Godot Editor signals to detect user actions and emit them
## as serializable Dictionary packets via the `action_captured` signal.
##
## All node_path values use SCENE-RELATIVE paths (relative to the edited
## scene root), not absolute editor tree paths. This ensures paths are
## portable between different Godot instances.
##
## IMPORTANT: After making changes to this file, completely restart BOTH
## Godot Editor instances. The .godot/ script cache may keep the old
## version of this file loaded in memory until a full restart.

signal action_captured(action: Dictionary)

const TAG := "ActionInterceptor"
const LOCK_SUFFIX := " 🔒"
const TRANSFORM_POLL_SEC := 0.1

## Allowed base classes for remote node instantiation. Only types that
## inherit from one of these will be accepted from the network.
const SAFE_NODE_BASES: Array[String] = [
	"Node", "Node2D", "Node3D", "Control", "Camera2D", "Camera3D",
	"Light2D", "Light3D", "MeshInstance3D", "MeshInstance2D",
	"CollisionShape2D", "CollisionShape3D", "CollisionObject2D", "CollisionObject3D",
	"StaticBody2D", "StaticBody3D", "RigidBody2D", "RigidBody3D",
	"CharacterBody2D", "CharacterBody3D", "Area2D", "Area3D",
	"Sprite2D", "Sprite3D", "AnimatedSprite2D", "AnimatedSprite3D",
	"AnimationPlayer", "AnimationTree", "Timer", "AudioStreamPlayer",
	"AudioStreamPlayer2D", "AudioStreamPlayer3D", "GPUParticles2D", "GPUParticles3D",
	"CPUParticles2D", "CPUParticles3D", "RayCast2D", "RayCast3D",
	"Path2D", "Path3D", "PathFollow2D", "PathFollow3D",
	"CanvasLayer", "SubViewport", "SubViewportContainer",
	"Label", "Button", "LineEdit", "TextEdit", "Panel",
	"HBoxContainer", "VBoxContainer", "GridContainer", "MarginContainer",
	"CSGBox3D", "CSGSphere3D", "CSGCylinder3D", "CSGMesh3D", "CSGCombiner3D",
	"DirectionalLight3D", "OmniLight3D", "SpotLight3D",
	"WorldEnvironment", "NavigationRegion2D", "NavigationRegion3D",
]

# ── References ───────────────────────────────────────────────────────
var _editor_plugin: EditorPlugin
var _editor_selection: EditorSelection
var _scene_tree: SceneTree
var _lock_manager: RefCounted = null
var _undo_redo: EditorUndoRedoManager = null

# ── Echo suppression ────────────────────────────────────────────────
var _suppress: bool = false
var _peer_id: String = "local"

# ── Remote-change echo suppression for transform poller ─────────────
## Paths of nodes whose transforms were just set by a remote action.
## The next _poll_transforms cycle will update the cache for these
## without re-emitting them, then clear the set.
var _remote_changed_paths: Dictionary = {}   ## rel_path → true

# ── Transform polling (viewport drag detection) ─────────────────────
var _transform_cache: Dictionary = {}   ## rel_path → Transform3D or Transform2D
var _poll_timer: Timer = null

# ── Script polling (detect script attachment changes) ────────────────
var _script_cache: Dictionary = {}   ## rel_path → script_resource_path (or "")


# ═════════════════════════════════════════════════════════════════════
#  Init / Teardown
# ═════════════════════════════════════════════════════════════════════

func init(plugin: EditorPlugin) -> void:
	_editor_plugin   = plugin
	_editor_selection = EditorInterface.get_selection()
	_scene_tree       = plugin.get_tree()
	_undo_redo        = plugin.get_undo_redo()

	_editor_selection.selection_changed.connect(_on_selection_changed)
	_scene_tree.node_added.connect(_on_node_added)
	_scene_tree.node_removed.connect(_on_node_removed)
	_editor_plugin.add_undo_redo_inspector_hook_callback(_on_inspector_property_changed)

	# Transform poller for viewport drag/gizmo changes
	_poll_timer = Timer.new()
	_poll_timer.wait_time = TRANSFORM_POLL_SEC
	_poll_timer.one_shot = false
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_poll_transforms)
	plugin.add_child(_poll_timer)

	print("[%s] Hooks connected." % TAG)


func set_lock_manager(lm: RefCounted) -> void:
	_lock_manager = lm


func teardown() -> void:
	if _editor_selection:
		if _editor_selection.selection_changed.is_connected(_on_selection_changed):
			_editor_selection.selection_changed.disconnect(_on_selection_changed)

	if _scene_tree:
		if _scene_tree.node_added.is_connected(_on_node_added):
			_scene_tree.node_added.disconnect(_on_node_added)
		if _scene_tree.node_removed.is_connected(_on_node_removed):
			_scene_tree.node_removed.disconnect(_on_node_removed)

	if _editor_plugin:
		_editor_plugin.remove_undo_redo_inspector_hook_callback(_on_inspector_property_changed)

	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null

	_undo_redo = null
	print("[%s] Hooks disconnected." % TAG)


# ═════════════════════════════════════════════════════════════════════
#  Path Sanitization — strip lock decoration from outgoing paths
# ═════════════════════════════════════════════════════════════════════

## Strip the LockOverlay's " 🔒" suffix from every segment of a
## scene-relative path so we always broadcast CLEAN paths over the
## network. For example "CSGSphere3D3 🔒" → "CSGSphere3D3".
static func _clean_path(rel_path: String) -> String:
	if LOCK_SUFFIX.is_empty():
		return rel_path
	if rel_path.find(LOCK_SUFFIX) == -1:
		return rel_path  # fast path: no suffix present
	var parts := rel_path.split("/")
	var cleaned: PackedStringArray = PackedStringArray()
	for part in parts:
		if part.ends_with(LOCK_SUFFIX):
			cleaned.append(part.substr(0, part.length() - LOCK_SUFFIX.length()))
		else:
			cleaned.append(part)
	return "/".join(cleaned)


# ═════════════════════════════════════════════════════════════════════
#  Event Handlers → emit action_captured
# ═════════════════════════════════════════════════════════════════════

func _on_selection_changed() -> void:
	if _suppress: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	var selected := _editor_selection.get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		if node == root or node.owner == root:
			paths.append(_clean_path(str(root.get_path_to(node))))

	var action := {
		"type": "select",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": { "paths": paths },
	}
	_emit(action)


func _on_node_added(node: Node) -> void:
	if _suppress: return

	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	# node.owner is NOT set yet when this signal fires. So we check
	# the PARENT instead — its owner IS already correct.
	var parent := node.get_parent()
	if not parent: return
	if parent != root and parent.owner != root: return

	var rel_path := _clean_path(str(root.get_path_to(node)))
	var parent_rel := _clean_path(str(root.get_path_to(parent)))

	var action := {
		"type": "node_add",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": {
			"parent_path": parent_rel,
			"node_type": node.get_class(),
			"node_name": _clean_path(str(node.name)),
		},
	}
	print("[%s] NODE_ADD: %s (%s) parent=%s" % [TAG, node.name, node.get_class(), parent_rel])
	_emit(action)


func _on_node_removed(node: Node) -> void:
	if _suppress: return
	if not _is_edited_scene_node(node): return

	var root := EditorInterface.get_edited_scene_root()
	var rel_path := _clean_path(str(root.get_path_to(node)))

	# Lock check — if the node is locked by a remote peer, undo the
	# deletion on the next frame so the editor state stays consistent.
	if _lock_manager and _lock_manager.is_locked(rel_path):
		var lock_owner: String = _lock_manager.get_lock_owner(rel_path)
		push_warning("[%s] BLOCKED delete: '%s' locked by '%s'" % [
			TAG, node.name, lock_owner])
		if _undo_redo and root:
			# Defer the undo to the next frame to avoid re-entrancy.
			# The last UndoRedo action in the scene history is the delete
			# we want to reverse.
			_suppress = true
			var scene_root := root
			var ur := _undo_redo
			(func():
				if is_instance_valid(scene_root):
					var history_id := ur.get_object_history_id(scene_root)
					var history_ur: UndoRedo = ur.get_history_undo_redo(history_id)
					history_ur.undo()
				_suppress = false
			).call_deferred()
		return

	var action := {
		"type": "node_delete",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": { "node_name": _clean_path(str(node.name)) },
	}
	_emit(action)


func _on_inspector_property_changed(_undo_redo: Object, modified_object: Object,
		property: String, new_value: Variant) -> bool:
	if _suppress: return false
	if not (modified_object is Node): return false

	var node: Node = modified_object as Node
	if not _is_edited_scene_node(node): return false

	var root := EditorInterface.get_edited_scene_root()
	var rel_path := _clean_path(str(root.get_path_to(node)))

	# Lock check
	if _lock_manager and _lock_manager.is_locked(rel_path):
		var lock_owner: String = _lock_manager.get_lock_owner(rel_path)
		push_warning("[%s] BLOCKED: '%s' locked by '%s'" % [TAG, node.name, lock_owner])
		return true

	# Intercept script attachment: serialize as script_attach/script_detach
	# instead of generic property (Resource objects can't be serialized
	# portably via var_to_bytes).
	if property == "script":
		_handle_script_property_change(node, rel_path, new_value)
		return false

	var action := {
		"type": "property",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": {
			"property": property,
			"value": new_value,
		},
	}
	_emit(action)
	return false


## Emit a script_attach or script_detach action when the "script"
## property is changed in the Inspector.
func _handle_script_property_change(node: Node, rel_path: String, new_value: Variant) -> void:
	if new_value == null:
		var old_script_path: String = ""
		var old_script = node.get_script()
		if old_script and old_script is Script:
			old_script_path = old_script.resource_path
		var action := {
			"type": "script_detach",
			"peer_id": _peer_id,
			"timestamp": Time.get_unix_time_from_system(),
			"node_path": rel_path,
			"data": { "script_path": old_script_path },
		}
		_emit(action)
		return

	if not (new_value is Script):
		return

	var script_res: Script = new_value as Script
	var script_path: String = script_res.resource_path
	var script_content: String = script_res.source_code

	var action := {
		"type": "script_attach",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": {
			"script_path": script_path,
			"script_content": script_content,
		},
	}
	print("[%s] SCRIPT_ATTACH: %s -> %s" % [TAG, rel_path, script_path])
	_emit(action)


# ═════════════════════════════════════════════════════════════════════
#  Apply Remote Actions
# ═════════════════════════════════════════════════════════════════════

func apply_remote_action(action: Dictionary) -> void:
	_suppress = true

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_suppress = false
		return

	match action.get("type", ""):
		"select":
			_apply_select(action, root)
		"property":
			_apply_property(action, root)
		"node_add":
			_apply_node_add(action, root)
		"node_delete":
			_apply_node_delete(action, root)
		"script_attach":
			_apply_script_attach(action, root)
		"script_detach":
			_apply_script_detach(action, root)

	_suppress = false


func _apply_select(action: Dictionary, _root: Node) -> void:
	var paths: Array = action.get("data", {}).get("paths", [])
	var peer_id: String = action.get("peer_id", "")

	if _lock_manager and not peer_id.is_empty():
		_lock_manager.update_peer_selection(peer_id, paths)

	print("[%s] Remote '%s' selected: %s" % [TAG, peer_id, paths])


## Apply a remote property change via EditorUndoRedoManager so the
## editor viewport, inspector, and scene-unsaved indicator all update.
func _apply_property(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	var data: Dictionary = action.get("data", {})
	if rel_path.is_empty() or data.is_empty(): return

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		# Print diagnostic info to help debug path resolution failures
		var children_names: Array[String] = []
		for child in root.get_children():
			children_names.append(str(child.name))
		push_warning("[%s] Property target not found: '%s' — root=%s children=%s" % [
			TAG, rel_path, root.name, children_names
		])
		return

	var prop: String = data.get("property", "")
	var value: Variant = data.get("value")
	if prop.is_empty(): return

	var old_value: Variant = target.get(prop)

	# Use EditorUndoRedoManager to apply the change so the editor UI
	# (viewport, inspector, scene unsaved indicator) updates properly.
	if _undo_redo:
		_undo_redo.create_action(
			"Remote: %s.%s" % [rel_path, prop],
			UndoRedo.MERGE_DISABLE,
			target
		)
		_undo_redo.add_do_property(target, prop, value)
		_undo_redo.add_undo_property(target, prop, old_value)
		_undo_redo.commit_action(true)
	else:
		# Fallback if UndoRedo is not available (should not happen)
		target.set(prop, value)
		target.notify_property_list_changed()

	# Mark this path so the transform poller does NOT re-broadcast
	# the change as if it were a local edit (prevents echo loop).
	var clean_path := _clean_path(rel_path)
	_remote_changed_paths[clean_path] = true

	print("[%s] Applied: %s.%s = %s" % [TAG, rel_path, prop, value])


func _apply_node_add(action: Dictionary, root: Node) -> void:
	var data: Dictionary = action.get("data", {})
	var parent_rel: String = data.get("parent_path", "")
	var node_type: String = data.get("node_type", "Node")
	var node_name: String = data.get("node_name", "NewNode")

	# Find parent: empty or "." = root
	var parent: Node = _resolve_node(root, parent_rel)
	if not parent:
		push_warning("[%s] Parent not found: '%s'" % [TAG, parent_rel])
		return

	# Check if node already exists (avoid duplicates)
	if parent.has_node(NodePath(node_name)):
		return

	# Validate node type against whitelist
	if not _is_safe_node_type(node_type):
		push_warning("[%s] Blocked unsafe node type from network: %s" % [TAG, node_type])
		return

	var new_node: Node = ClassDB.instantiate(StringName(node_type))
	if not new_node:
		push_warning("[%s] Cannot instantiate: %s" % [TAG, node_type])
		return

	new_node.name = node_name

	# Use UndoRedo so the editor knows about the new node
	if _undo_redo:
		_undo_redo.create_action(
			"Remote: Add %s" % node_name,
			UndoRedo.MERGE_DISABLE,
			parent
		)
		_undo_redo.add_do_method(parent, "add_child", new_node, true)
		_undo_redo.add_do_method(new_node, "set_owner", root)
		_undo_redo.add_do_reference(new_node)
		_undo_redo.add_undo_method(parent, "remove_child", new_node)
		_undo_redo.commit_action(true)
	else:
		parent.add_child(new_node)
		new_node.owner = root

	print("[%s] Added: %s/%s (%s)" % [TAG, parent_rel, node_name, node_type])


func _apply_node_delete(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	if rel_path.is_empty() or rel_path == ".": return  # don't delete root

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		return  # already deleted, no warning

	if _undo_redo:
		var parent := target.get_parent()
		_undo_redo.create_action(
			"Remote: Delete %s" % target.name,
			UndoRedo.MERGE_DISABLE,
			target
		)
		_undo_redo.add_do_method(parent, "remove_child", target)
		_undo_redo.add_undo_method(parent, "add_child", target, true)
		_undo_redo.add_undo_method(target, "set_owner", root)
		_undo_redo.add_undo_reference(target)
		_undo_redo.commit_action(true)
	else:
		target.queue_free()

	print("[%s] Deleted: %s" % [TAG, rel_path])


func _apply_script_attach(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	var data: Dictionary = action.get("data", {})
	var script_path: String = data.get("script_path", "")
	var script_content: String = data.get("script_content", "")

	if rel_path.is_empty() or script_path.is_empty():
		return

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		push_warning("[%s] Script attach target not found: '%s'" % [TAG, rel_path])
		return

	# Write the script file to disk so the peer has a local copy
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		push_warning("[%s] Cannot write script file: '%s' (err %d)" % [
			TAG, script_path, FileAccess.get_open_error()])
		return
	file.store_string(script_content)
	file.close()

	# Tell Godot's resource filesystem about the new/changed file
	# BEFORE calling load(). Without this, load() may return null
	# or crash because EditorFileSystem hasn't indexed the file yet.
	EditorInterface.get_resource_filesystem().update_file(script_path)

	# Use CACHE_MODE_REPLACE to force reading from disk, bypassing
	# any stale cached version (update_file is async and may not have
	# finished scanning by the time we call load).
	var script_res := ResourceLoader.load(
		script_path, "Script",
		ResourceLoader.CACHE_MODE_REPLACE) as Script
	if script_res:
		target.set_script(script_res)
		target.notify_property_list_changed()

	# Mark for echo suppression
	var clean_path := _clean_path(rel_path)
	_remote_changed_paths[clean_path + "::script"] = true
	_script_cache[clean_path] = script_path

	print("[%s] Script attached: %s -> %s" % [TAG, rel_path, script_path])


func _apply_script_detach(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	if rel_path.is_empty():
		return

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		return

	target.set_script(null)
	target.notify_property_list_changed()

	var clean_path := _clean_path(rel_path)
	_remote_changed_paths[clean_path + "::script"] = true
	_script_cache[clean_path] = ""

	print("[%s] Script detached: %s" % [TAG, rel_path])


# ═════════════════════════════════════════════════════════════════════
#  Robust Node Path Resolution
# ═════════════════════════════════════════════════════════════════════

## Resolve a scene-relative path to a Node, accounting for the
## LockOverlay's 🔒 suffix decoration on node names.
## Handles BOTH directions:
##   - Path "CSGSphere3D3" → node named "CSGSphere3D3 🔒" (add suffix)
##   - Path "CSGSphere3D3 🔒" → node named "CSGSphere3D3" (strip suffix)
func _resolve_node(root: Node, rel_path: String) -> Node:
	# "." or empty = root itself
	if rel_path.is_empty() or rel_path == ".":
		return root

	# 1. Direct lookup — the happy path
	var target: Node = root.get_node_or_null(NodePath(rel_path))
	if target:
		return target

	# 2. Try with a cleaned path (strip lock suffix from all segments)
	var cleaned := _clean_path(rel_path)
	if cleaned != rel_path:
		target = root.get_node_or_null(NodePath(cleaned))
		if target:
			return target

	# 3. Walk segment by segment, trying each with/without suffix
	var parts := cleaned.split("/")
	var current: Node = root
	for part in parts:
		var child := current.get_node_or_null(NodePath(part))
		if not child:
			# Try with the lock decoration suffix
			child = current.get_node_or_null(NodePath(part + LOCK_SUFFIX))
		if not child:
			return null
		current = child
	return current


# ═════════════════════════════════════════════════════════════════════
#  Helpers
# ═════════════════════════════════════════════════════════════════════

func _is_edited_scene_node(node: Node) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	if not root: return false
	return node == root or node.owner == root


func _emit(action: Dictionary) -> void:
	action_captured.emit(action)


# ═════════════════════════════════════════════════════════════════════
#  Transform Polling (catches viewport drag / gizmo changes)
# ═════════════════════════════════════════════════════════════════════

func _poll_transforms() -> void:
	if _suppress: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	var nodes := _get_all_scene_nodes(root)
	var new_cache: Dictionary = {}

	for node in nodes:
		# Always use the CLEAN path (no lock suffix) for both the
		# cache key and the outgoing action, so all peers agree on
		# the same canonical names.
		var rel_path := _clean_path(str(root.get_path_to(node)))

		# ── Poll script attachment changes ──────────────────────
		var current_script_path: String = ""
		var node_script = node.get_script()
		if node_script and node_script is Script:
			current_script_path = node_script.resource_path

		var cached_script: String = _script_cache.get(rel_path, "")
		if current_script_path != cached_script:
			if not _remote_changed_paths.has(rel_path + "::script"):
				if current_script_path.is_empty():
					_emit({
						"type": "script_detach",
						"peer_id": _peer_id,
						"timestamp": Time.get_unix_time_from_system(),
						"node_path": rel_path,
						"data": { "script_path": cached_script },
					})
				else:
					_emit({
						"type": "script_attach",
						"peer_id": _peer_id,
						"timestamp": Time.get_unix_time_from_system(),
						"node_path": rel_path,
						"data": {
							"script_path": current_script_path,
							"script_content": node_script.source_code,
						},
					})
			_script_cache[rel_path] = current_script_path

		# ── Poll transform changes ──────────────────────────────
		if node is Node3D:
			var n3d: Node3D = node as Node3D
			var current_t := n3d.transform
			new_cache[rel_path] = current_t

			# If this node was just moved by a remote action, update
			# the cache silently (no re-emit) to prevent echo.
			if _remote_changed_paths.has(rel_path):
				continue

			if _transform_cache.has(rel_path):
				var old_t: Transform3D = _transform_cache[rel_path]
				if not old_t.is_equal_approx(current_t):
					# Position changed
					if not old_t.origin.is_equal_approx(current_t.origin):
						_emit_property(rel_path, "position", n3d.position)
					# Rotation changed
					if not old_t.basis.is_equal_approx(current_t.basis):
						_emit_property(rel_path, "rotation", n3d.rotation)
						_emit_property(rel_path, "scale", n3d.scale)

		elif node is Node2D:
			var n2d: Node2D = node as Node2D
			var current_t := n2d.transform
			new_cache[rel_path] = current_t

			if _remote_changed_paths.has(rel_path):
				continue

			if _transform_cache.has(rel_path):
				var old_t: Transform2D = _transform_cache[rel_path]
				if not old_t.is_equal_approx(current_t):
					_emit_property(rel_path, "position", n2d.position)
					_emit_property(rel_path, "rotation", n2d.rotation)
					_emit_property(rel_path, "scale", n2d.scale)

	_transform_cache = new_cache
	# Clear the remote-changed set after one poll cycle
	_remote_changed_paths.clear()


func _emit_property(rel_path: String, prop: String, value: Variant) -> void:
	var action := {
		"type": "property",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": {
			"property": prop,
			"value": value,
		},
	}
	_emit(action)


func _get_all_scene_nodes(root: Node) -> Array[Node]:
	var result: Array[Node] = [root]
	for child in root.get_children():
		if child.owner == root:
			result.append(child)
			_collect_children(child, root, result)
	return result


func _collect_children(node: Node, root: Node, result: Array[Node]) -> void:
	for child in node.get_children():
		if child.owner == root:
			result.append(child)
			_collect_children(child, root, result)


## Check if a node type is safe to instantiate from a remote request.
## Returns true if the type is in the whitelist or inherits from a whitelisted class.
static func _is_safe_node_type(type_name: String) -> bool:
	if not ClassDB.class_exists(StringName(type_name)):
		return false
	for safe_base in SAFE_NODE_BASES:
		var sn := StringName(type_name)
		var sb := StringName(safe_base)
		if type_name == safe_base or ClassDB.is_parent_class(sn, sb):
			return true
	return false
