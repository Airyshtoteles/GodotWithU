# gdlint:disable=max-file-lines
@tool
# No global class_name: loaded by path via _instantiate_addon_script; declaring a
# global class breaks the source-reload fallback on re-enable ("hides a global script class").
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

const ActionSerializerClass = preload("action_serializer.gd")
const TAG := "ActionInterceptor"
## Print one line per node added and per remote property applied (debugging only).
const VERBOSE_LOG := false
const LOCK_SUFFIX := " 🔒"
## Xogot's native SceneTree dock cannot tint a TreeItem, so locked nodes are
## marked directly in the node name (see LockOverlay). Strip these too when
## sanitizing outgoing paths so the network only ever sees clean node names.
const XOGOT_LOCK_SUFFIX := " 🔴 LOCKED 🔒"
const LEGACY_XOGOT_LOCK_SUFFIX := " 🔴🔒"
const LOCK_SUFFIXES: Array[String] = [
	XOGOT_LOCK_SUFFIX,
	LEGACY_XOGOT_LOCK_SUFFIX,
	LOCK_SUFFIX,
]
## Upper bound (frames) for deferring an editor-selection restore while the user
## holds a mouse button. Stops a stuck button from stranding the lock guard.
const SELECTION_RESTORE_MAX_FRAMES := 600
const TRANSFORM_POLL_SEC := 0.1
const META_VERTICAL_GUIDES := "_edit_vertical_guides_"
const META_HORIZONTAL_GUIDES := "_edit_horizontal_guides_"
const LOCK_WARNING_COOLDOWN_SEC := 1.0
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

## Sentinel for a polled property not observed yet. A dedicated value avoids
## colliding with a real null (e.g. a MeshInstance2D whose mesh is genuinely null).
const PROP_CACHE_UNSET := "__prop_cache_unset__"
## Xogot generic fallback polling (see the Xogot section below).
const XOGOT_FALLBACK_SETTING := "godot_with_u/xogot_fallback"
const XOGOT_FALLBACK_ENV := "GODOT_WITH_U_XOGOT"
const GENERIC_POLL_EVERY_N_TICKS := 3   ## ~0.3 s at the 0.1 s transform tick
## Properties already synced by dedicated mechanisms (transform poll, curated
## resource poll, name/script signals). Never diffed generically — that would
## double-emit and break apply-ordering guarantees (e.g. layout_mode vs size).
const GENERIC_ALWAYS_SKIP: Dictionary = {
	"owner": true, "name": true, "script": true, "multiplayer": true,
	"scene_file_path": true, "unique_name_in_owner": true, "process_mode": true,
	"position": true, "rotation": true, "rotation_degrees": true, "scale": true,
	"transform": true, "skew": true, "rotation_edit_mode": true, "rotation_order": true,
	"global_position": true, "global_rotation": true, "global_rotation_degrees": true,
	"global_scale": true, "global_transform": true, "global_basis": true,
	"global_skew": true, "quaternion": true, "basis": true, "top_level": true,
}
## Deferred retry queue limits (see _pending_actions).
const PENDING_MAX_RETRIES := 8   ## ~0.4 s at 50 ms poll interval
const PENDING_RESOURCE_MAX_RETRIES := 120   ## ~6 s for freshly imported files
## Scene-sync guard length (see _scene_sync_ticks_remaining).
const SCENE_SYNC_GUARD_TICKS := 40  ## ~2 s at 50 ms per tick

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

# ── Child order polling (detect scene-tree reorders) ─────────────────
## Maps rel_path → last-seen child index (get_index()) for every scene node.
## Populated on the first poll cycle; subsequent cycles detect changes.
var _child_order_cache: Dictionary = {}   ## rel_path → int

# ── Transform polling (viewport drag detection) ─────────────────────
var _transform_cache: Dictionary = {}   ## rel_path → Transform3D, Transform2D, or Array (Control)
var _locked_transform_restore_pending: Dictionary = {}  ## rel_path → generation
var _locked_transform_restore_generation: int = 0
var _poll_timer: Timer = null

# ── Script polling (detect script attachment changes) ────────────────
var _script_cache: Dictionary = {}   ## rel_path → script_resource_path (or "")

# ── Resource / misc property polling ──────────────────────────────
## Stores the last-seen encoded cache token for each polled property:
## key = "rel_path::prop", value = resource_path string (resources)
##                                  or raw Variant for primitives.
## A missing key (or PROP_CACHE_UNSET) means "not yet observed".
var _resource_prop_cache: Dictionary = {}
var _resource_prop_value_cache: Dictionary = {}   ## "rel_path::prop" → last Variant

# ── Xogot generic fallback polling ──────────────────────────────────
## Xogot is the Godot editor running on iOS/iPadOS, where parts of the
## inspector and scene UI are rehosted in native iOS views. The desktop
## inspector hook (add_undo_redo_inspector_hook_callback) can therefore
## never fire, so arbitrary (non-curated) property edits would not sync,
## and node add/remove via the native UI MIGHT bypass the SceneTree
## signals. When this flag is on we additionally:
##   • diff every storage property the curated pollers don't already cover
##   • detect node add/remove by presence (instance_id) as a safety net.
## Auto-enabled on iOS; force it on from desktop for testing via the
## GODOT_WITH_U_XOGOT=1 env var, the `godot_with_u/xogot_fallback`
## project setting, or set_xogot_fallback().
var _xogot_fallback: bool = false
var _generic_prop_cache: Dictionary = {}   ## "rel_path::prop" → last token
var _generic_prop_value_cache: Dictionary = {}  ## "rel_path::prop" → last allowed value
var _presence_cache: Dictionary = {}        ## instance_id(int) → rel_path
var _presence_seeded: bool = false
var _presence_root_id: int = 0
var _generic_poll_tick: int = 0

# ── Scene guide polling ─────────────────────────────────────────────
var _scene_guides_cache: Dictionary = {}
var _remote_scene_guides_changed: bool = false

# ── Node name (rename) polling ─────────────────────────────────────
var _name_cache: Dictionary = {}   ## instance_id(int) → {name: String, rel_path: String}
## instance_id(int) → {parent_path: String, child_index: int, rel_path: String}
var _parent_cache: Dictionary = {}

# ── Locked-node rollback snapshots ─────────────────────────────────
var _group_cache: Dictionary = {}              ## rel_path → sorted Array[String]
var _signal_connection_cache: Dictionary = {}  ## rel_path → Array[Dictionary]
var _lock_warning_last: Dictionary = {}        ## "path::change" → timestamp
var _selection_guard_active: bool = false
var _last_allowed_selection_paths: Array[String] = []

# ── Deferred retry queue ─────────────────────────────────────────────
## Actions targeting a node that wasn't found are held here and retried
## each poll tick until the node appears or the retry limit is reached.
var _pending_actions: Array[Dictionary] = []

# ── Scene-sync guard ──────────────────────────────────────────────────
## When > 0, local emission (polls + signal handlers) is suppressed so
## the re-opening peer doesn't overwrite the authoritative state being
## sent by peers who already had this file open. Decremented every tick;
## also cleared immediately when the first remote node_add/property
## arrives (remote state is here — safe to start emitting again).
var _scene_sync_ticks_remaining: int = 0

## Called by the plugin when the local peer opens a scene that at least
## one connected peer already has open (they are the source of truth).
func set_scene_sync_guard() -> void:
	_scene_sync_ticks_remaining = SCENE_SYNC_GUARD_TICKS
	_scene_guides_cache.clear()
	_remote_scene_guides_changed = false
	print("[%s] Scene sync guard active (%d ticks)" % [TAG, SCENE_SYNC_GUARD_TICKS])


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
	_scene_tree.node_renamed.connect(_on_node_renamed)
	_editor_plugin.add_undo_redo_inspector_hook_callback(_on_inspector_property_changed)

	_xogot_fallback = _detect_xogot()

	# Transform poller for viewport drag/gizmo changes
	_poll_timer = Timer.new()
	_poll_timer.wait_time = TRANSFORM_POLL_SEC
	_poll_timer.one_shot = false
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_poll_transforms)
	# Xogot fallback runs AFTER transforms but BEFORE the resource poll so it
	# can still read _remote_changed_paths (cleared at the end of the resource
	# poll). No-op unless _xogot_fallback is on.
	_poll_timer.timeout.connect(_poll_generic_fallback)
	_poll_timer.timeout.connect(_poll_resource_properties)
	_poll_timer.timeout.connect(_poll_scene_guides)
	plugin.add_child(_poll_timer)

	print("[%s] Hooks connected.%s" % [TAG, " (Xogot fallback ON)" if _xogot_fallback else ""])


func set_lock_manager(lm: RefCounted) -> void:
	if _lock_manager and _lock_manager.locks_changed.is_connected(_on_locks_changed):
		_lock_manager.locks_changed.disconnect(_on_locks_changed)
	_lock_manager = lm
	if _lock_manager:
		_lock_manager.locks_changed.connect(_on_locks_changed)


func teardown() -> void:
	if _editor_selection:
		if _editor_selection.selection_changed.is_connected(_on_selection_changed):
			_editor_selection.selection_changed.disconnect(_on_selection_changed)

	if _scene_tree:
		if _scene_tree.node_added.is_connected(_on_node_added):
			_scene_tree.node_added.disconnect(_on_node_added)
		if _scene_tree.node_removed.is_connected(_on_node_removed):
			_scene_tree.node_removed.disconnect(_on_node_removed)
		if _scene_tree.node_renamed.is_connected(_on_node_renamed):
			_scene_tree.node_renamed.disconnect(_on_node_renamed)

	if _editor_plugin:
		_editor_plugin.remove_undo_redo_inspector_hook_callback(_on_inspector_property_changed)

	if _lock_manager and _lock_manager.locks_changed.is_connected(_on_locks_changed):
		_lock_manager.locks_changed.disconnect(_on_locks_changed)

	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null

	_undo_redo = null
	_locked_transform_restore_pending.clear()
	_generic_prop_cache.clear()
	_generic_prop_value_cache.clear()
	_presence_cache.clear()
	_presence_seeded = false
	print("[%s] Hooks disconnected." % TAG)


# ═════════════════════════════════════════════════════════════════════
#  Path Sanitization — strip lock decoration from outgoing paths
# ═════════════════════════════════════════════════════════════════════

## Strip the LockOverlay's desktop or Xogot suffix from every segment of a
## scene-relative path so we always broadcast CLEAN paths over the
## network. For example "CSGSphere3D3 🔴 LOCKED 🔒" → "CSGSphere3D3".
static func _clean_path(rel_path: String) -> String:
	# All lock decorations end with the padlock emoji — fast-path skip when none.
	if rel_path.find("🔒") == -1:
		return rel_path
	var parts := rel_path.split("/")
	var cleaned: PackedStringArray = PackedStringArray()
	for part in parts:
		var clean_part := String(part)
		for suffix in LOCK_SUFFIXES:
			if clean_part.ends_with(suffix):
				clean_part = clean_part.substr(0, clean_part.length() - suffix.length())
				break
		cleaned.append(clean_part)
	return "/".join(cleaned)


## Compute a stable, content-based cache token for a Resource.
## Saved resources are usually identified by their path (fast, stable across
## ticks). Mutable editor resources that sync by snapshot, plus inline and scene
## sub-resources, use encoded content so edits inside nested data
## (SpriteFrames animations/frames, Animation tracks/keys,
## mesh radius, etc.)
## are detected even when the object instance stays the same.
static func _resource_token(resource: Resource) -> String:
	var rpath := String(resource.resource_path)
	if not rpath.is_empty() and not ("::" in rpath) \
			and not ActionSerializerClass.should_send_resource_snapshot(resource):
		return "path:" + rpath
	var encoded := ActionSerializerClass.encode_property_value(resource)
	if not bool(encoded.get("ok", false)):
		return "resource:" + resource.get_class()
	return "content:" + var_to_str(encoded.get("value"))


# ═════════════════════════════════════════════════════════════════════
#  Locked-node guards
# ═════════════════════════════════════════════════════════════════════

func _on_locks_changed() -> void:
	_cancel_unlocked_transform_restores()
	_seed_lock_state_for_current_scene()
	_enforce_locked_selection_guard()


func _seed_lock_state_for_current_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return
	for node in _get_all_scene_nodes(root):
		_seed_node_lock_state(root, node)


func _seed_node_lock_state(root: Node, node: Node) -> void:
	if not is_instance_valid(node):
		return
	var rel_path := _clean_path(str(root.get_path_to(node)))
	_group_cache[rel_path] = _snapshot_node_groups(node)
	_signal_connection_cache[rel_path] = _snapshot_signal_connections(root, node)

	var node_script = node.get_script()
	if node_script and node_script is Script:
		_script_cache[rel_path] = (node_script as Script).resource_path
	else:
		_script_cache[rel_path] = ""

	if node != root:
		var parent := node.get_parent()
		if parent:
			var parent_rel := _clean_path(str(root.get_path_to(parent)))
			_child_order_cache[rel_path] = node.get_index()
			_parent_cache[node.get_instance_id()] = {
				"parent_path": parent_rel,
				"child_index": node.get_index(),
				"rel_path": rel_path,
			}

	if _xogot_fallback:
		_presence_cache[node.get_instance_id()] = rel_path
		for prop_info in node.get_property_list():
			var usage := int(prop_info.get("usage", 0))
			if usage & PROPERTY_USAGE_STORAGE == 0:
				continue
			if usage & PROPERTY_USAGE_EDITOR == 0:
				continue
			if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY \
					| PROPERTY_USAGE_SUBGROUP) != 0:
				continue
			var prop_name := String(prop_info.get("name", ""))
			if prop_name.is_empty():
				continue
			var prop_value: Variant = node.get(prop_name)
			if prop_value is Object or prop_value is PackedByteArray:
				continue
			var generic_key := rel_path + "::" + prop_name
			_generic_prop_cache[generic_key] = _generic_token(prop_value)
			_generic_prop_value_cache[generic_key] = \
				_snapshot_property_value(prop_value)

	if node is Node3D:
		_transform_cache[rel_path] = (node as Node3D).transform
	elif node is Node2D:
		_transform_cache[rel_path] = (node as Node2D).transform
	elif node is Control:
		_transform_cache[rel_path] = _snapshot_control_transform(node as Control)

	for prop in _get_polled_resource_props(node):
		var key := rel_path + "::" + prop
		var current_val: Variant = node.get(prop)
		_resource_prop_cache[key] = _property_cache_token(current_val)
		_resource_prop_value_cache[key] = _snapshot_property_value(current_val)


func _property_cache_token(value: Variant) -> Variant:
	if value is Resource:
		return _resource_token(value as Resource)
	return value


func _snapshot_control_transform(ctrl: Control) -> Array:
	return [
		ctrl.anchor_left, ctrl.anchor_right, ctrl.anchor_top, ctrl.anchor_bottom,
		ctrl.offset_left, ctrl.offset_right, ctrl.offset_top, ctrl.offset_bottom,
		ctrl.rotation, ctrl.scale.x, ctrl.scale.y, ctrl.pivot_offset.x, ctrl.pivot_offset.y
	]


func _get_locked_path(rel_path: String, include_ancestors: bool = false) -> String:
	if not _lock_manager:
		return ""
	var clean_path := _clean_path(rel_path)
	if clean_path.is_empty():
		clean_path = "."

	if _lock_manager.is_locked(clean_path):
		return clean_path

	if not include_ancestors:
		return ""

	var current := clean_path
	while current != "." and not current.is_empty():
		current = _parent_path_from_rel_path(current)
		if _lock_manager.is_locked(current):
			return current
	return ""


func _is_locked(rel_path: String, include_ancestors: bool = false) -> bool:
	return not _get_locked_path(rel_path, include_ancestors).is_empty()


func _parent_path_from_rel_path(rel_path: String) -> String:
	var clean_path := _clean_path(rel_path)
	if clean_path.is_empty() or clean_path == "." or clean_path.find("/") == -1:
		return "."
	return clean_path.get_base_dir()


func _get_selected_locked_path() -> String:
	if not _editor_selection:
		return ""
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return ""
	for node in _editor_selection.get_selected_nodes():
		if not is_instance_valid(node):
			continue
		if node != root and node.owner != root:
			continue
		var rel_path := _clean_path(str(root.get_path_to(node)))
		var locked_path := _get_locked_path(rel_path)
		if not locked_path.is_empty():
			return locked_path
	return ""


func _enforce_locked_selection_guard() -> void:
	if _selection_guard_active or not _editor_selection:
		return
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return

	var allowed_paths: Array[String] = []
	var blocked_locked_path := ""
	for node in _editor_selection.get_selected_nodes():
		if not is_instance_valid(node):
			continue
		if node != root and node.owner != root:
			continue
		var rel_path := _clean_path(str(root.get_path_to(node)))
		var locked_path := _get_locked_path(rel_path)
		if not locked_path.is_empty():
			blocked_locked_path = locked_path
		else:
			allowed_paths.append(rel_path)

	if not blocked_locked_path.is_empty():
		_reject_locked_selection(blocked_locked_path, allowed_paths)


func _reject_locked_selection(locked_path: String, allowed_paths: Array[String]) -> void:
	var restore_paths := allowed_paths.duplicate()
	if restore_paths.is_empty():
		restore_paths = _last_allowed_selection_paths.duplicate()
	_notify_lock_blocked(locked_path, "selection")
	_selection_guard_active = true
	_restore_editor_selection_when_idle(restore_paths)


## Clearing + re-adding nodes in the editor selection while the user is holding
## a mouse button mutates the 2D/3D viewport editor's cached drag selection
## mid-drag, which crashes the engine (SIGSEGV in
## CanvasItemEditor::_gui_input_move). Always yield at least one frame (never
## touch the selection inside the selection_changed signal), then keep waiting
## while a drag is in progress before restoring. Bounded so a stuck button can't
## strand the guard forever.
func _restore_editor_selection_when_idle(paths: Array[String]) -> void:
	if not _scene_tree:
		_restore_editor_selection(paths)
		return
	await _scene_tree.process_frame
	var frames := 0
	while _is_pointer_dragging() and frames < SELECTION_RESTORE_MAX_FRAMES:
		frames += 1
		await _scene_tree.process_frame
	_restore_editor_selection(paths)


## True while any mouse button is held — a proxy for "the user is mid-drag in a
## viewport", during which the editor must not have its selection mutated.
func _is_pointer_dragging() -> bool:
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


func _cancel_unlocked_transform_restores() -> void:
	for rel_path in _locked_transform_restore_pending.keys():
		if not _is_locked(String(rel_path)):
			_locked_transform_restore_pending.erase(rel_path)


func _queue_locked_transform_restore(rel_path: String, snapshot: Variant) -> void:
	if _locked_transform_restore_pending.has(rel_path):
		return
	_locked_transform_restore_generation += 1
	var generation := _locked_transform_restore_generation
	_locked_transform_restore_pending[rel_path] = generation
	_restore_locked_transform_when_idle(rel_path, snapshot, generation)


## Transform setters can invalidate the viewport's active drag state just like
## selection changes can. Wait for mouse release, then snap the locked node back
## to the last authoritative transform.
func _restore_locked_transform_when_idle(rel_path: String, snapshot: Variant,
		generation: int) -> void:
	if not _scene_tree:
		_locked_transform_restore_pending.erase(rel_path)
		return
	await _scene_tree.process_frame
	var frames := 0
	while _is_pointer_dragging() and frames < SELECTION_RESTORE_MAX_FRAMES:
		frames += 1
		await _scene_tree.process_frame

	if int(_locked_transform_restore_pending.get(rel_path, -1)) != generation:
		return
	_locked_transform_restore_pending.erase(rel_path)
	if not _is_locked(rel_path):
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return
	var node := _resolve_node(root, rel_path)
	if not is_instance_valid(node):
		return

	var was_suppress := _suppress
	_suppress = true
	if node is Node3D and snapshot is Transform3D:
		(node as Node3D).transform = snapshot
	elif node is Node2D and snapshot is Transform2D:
		(node as Node2D).transform = snapshot
	elif node is Control and snapshot is Array:
		_restore_control_transform(node as Control, snapshot as Array)
	_suppress = was_suppress
	_transform_cache[rel_path] = snapshot


func _restore_editor_selection(paths: Array[String]) -> void:
	if not _editor_selection:
		_end_selection_guard()
		return
	var root := EditorInterface.get_edited_scene_root()
	_editor_selection.clear()

	var restored_paths: Array[String] = []
	if root:
		for path in paths:
			var rel_path := _clean_path(str(path))
			if not _get_locked_path(rel_path).is_empty():
				continue
			var node := _get_scene_node_by_rel_path(root, rel_path)
			if node:
				_editor_selection.add_node(node)
				restored_paths.append(rel_path)

	_last_allowed_selection_paths = restored_paths
	call_deferred("_end_selection_guard")


func _end_selection_guard() -> void:
	_selection_guard_active = false


func _get_scene_node_by_rel_path(root: Node, rel_path: String) -> Node:
	if rel_path.is_empty() or rel_path == ".":
		return root
	var node := root.get_node_or_null(NodePath(rel_path))
	if node:
		return node
	var base_dir := rel_path.get_base_dir()
	for suffix in LOCK_SUFFIXES:
		var last_decorated := rel_path.get_file() + suffix
		if not base_dir.is_empty():
			last_decorated = base_dir.path_join(last_decorated)
		node = root.get_node_or_null(NodePath(last_decorated))
		if node:
			return node
	var parts := rel_path.split("/")
	for i in range(parts.size()):
		for suffix in LOCK_SUFFIXES:
			var mixed_parts := parts.duplicate()
			mixed_parts[i] = str(mixed_parts[i]) + suffix
			node = root.get_node_or_null(NodePath("/".join(mixed_parts)))
			if node:
				return node
	for suffix in LOCK_SUFFIXES:
		var decorated_parts: PackedStringArray = PackedStringArray()
		for part in parts:
			decorated_parts.append(part + suffix)
		node = root.get_node_or_null(NodePath("/".join(decorated_parts)))
		if node:
			return node
	return null


func _notify_lock_blocked(locked_path: String, change: String) -> void:
	if locked_path.is_empty():
		return
	var owner: String = ""
	if _lock_manager:
		if _lock_manager.has_method("get_lock_owner_display_name"):
			owner = String(_lock_manager.get_lock_owner_display_name(locked_path))
		else:
			owner = String(_lock_manager.get_lock_owner(locked_path))
	var key := locked_path + "::" + change
	var now := Time.get_unix_time_from_system()
	if _lock_warning_last.has(key) \
			and now - float(_lock_warning_last[key]) < LOCK_WARNING_COOLDOWN_SEC:
		return
	_lock_warning_last[key] = now
	push_warning("[%s] BLOCKED %s: '%s' locked by '%s'" % [
		TAG, change, locked_path, owner
	])
	if Engine.is_editor_hint():
		var toaster := EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(
				"Node locked by %s" % (owner if not owner.is_empty() else "peer"),
				EditorToaster.SEVERITY_WARNING,
				"Modification blocked while the peer holds the lock on %s." % locked_path
			)


func _block_if_locked(rel_path: String, change: String,
		include_ancestors: bool = false) -> bool:
	var locked_path := _get_locked_path(rel_path, include_ancestors)
	if locked_path.is_empty():
		return false
	_notify_lock_blocked(locked_path, change)
	return true


func _block_child_mutation_if_locked(parent_rel: String, change: String) -> bool:
	var locked_path := _get_locked_path(parent_rel)
	if locked_path.is_empty():
		return false
	_notify_lock_blocked(locked_path, change)
	return true


# ═════════════════════════════════════════════════════════════════════
#  Event Handlers → emit action_captured
# ═════════════════════════════════════════════════════════════════════

func _on_selection_changed() -> void:
	if _suppress: return
	if _selection_guard_active: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	var selected := _editor_selection.get_selected_nodes()
	var paths: Array[String] = []
	var blocked_locked_path := ""
	for node in selected:
		if node == root or node.owner == root:
			var rel_path := _clean_path(str(root.get_path_to(node)))
			var locked_path := _get_locked_path(rel_path)
			if not locked_path.is_empty():
				blocked_locked_path = locked_path
			else:
				paths.append(rel_path)

	if not blocked_locked_path.is_empty():
		_reject_locked_selection(blocked_locked_path, paths)
		return

	_last_allowed_selection_paths = paths.duplicate()

	var action := {
		"type": "select",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": { "paths": paths },
	}
	_emit(action)


## Re-broadcast the current selection even when it has not changed. Remote lock
## managers use this as a lease renewal so a user can keep editing the same node
## for longer than LOCK_TIMEOUT_SEC without re-selecting it.
func emit_selection_heartbeat() -> void:
	if _suppress or _selection_guard_active or not _editor_selection:
		return
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return

	var paths: Array[String] = []
	for node in _editor_selection.get_selected_nodes():
		if not is_instance_valid(node):
			continue
		if node != root and node.owner != root:
			continue
		var rel_path := _clean_path(str(root.get_path_to(node)))
		if _get_locked_path(rel_path).is_empty():
			paths.append(rel_path)

	_emit({
		"type": "select",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"data": {
			"paths": paths,
			"heartbeat": true,
		},
	})


func _on_node_added(node: Node) -> void:
	# The remote is the source of truth while the scene-sync guard is active.
	if _suppress or _scene_sync_ticks_remaining > 0: return

	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	# node.owner is NOT set yet when this signal fires. So we check
	# the PARENT instead — its owner IS already correct.
	var parent := node.get_parent()
	if not parent or (parent != root and parent.owner != root): return
	# Nodes that belong to an instanced sub-scene are replicated as part of
	# that instance's PackedScene (see "scene_instance" below) — never as
	# standalone node_add packets, or we would duplicate the instance content.
	if _is_instance_internal(parent, root): return

	var rel_path := _clean_path(str(root.get_path_to(node)))
	var parent_rel := _clean_path(str(root.get_path_to(parent)))

	var locked_parent := _get_locked_path(parent_rel)
	var locked_selection := _get_selected_locked_path()
	if not locked_parent.is_empty() or not locked_selection.is_empty():
		_notify_lock_blocked(
			locked_parent if not locked_parent.is_empty() else locked_selection,
			"node add/context action"
		)
		_revert_added_node(node, root)
		return

	var add_data := {
		"parent_path": parent_rel,
		"node_type": node.get_class(),
		"node_name": _clean_path(str(node.name)),
		"child_index": node.get_index(),
	}
	# Instanced sub-scene root: carry the PackedScene path so the receiver
	# re-instantiates the whole sub-scene (internal children, scripts and
	# overrides included) instead of creating a bare node of the base class.
	var instance_scene := str(node.scene_file_path)
	if not instance_scene.is_empty():
		add_data["scene_instance"] = instance_scene

	var action := {
		"type": "node_add",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": add_data,
	}
	if VERBOSE_LOG:
		print("[%s] NODE_ADD: %s (%s) parent=%s idx=%d%s" % [
			TAG, node.name, node.get_class(), parent_rel, node.get_index(),
			(" instance=%s" % instance_scene) if not instance_scene.is_empty() else "",
		])
	_emit(action)

	# Seed the name cache immediately so _on_node_renamed has a valid
	# previous entry even if the node is renamed before the first poll.
	var iid := node.get_instance_id()
	_name_cache[iid] = {"name": _clean_path(str(node.name)), "rel_path": rel_path}
	_parent_cache[iid] = {
		"parent_path": parent_rel,
		"child_index": node.get_index(),
		"rel_path": rel_path,
	}
	# Record presence so the Xogot fallback poll does NOT re-emit this add
	# (the SceneTree signal already handled it).
	if _xogot_fallback:
		_presence_cache[iid] = rel_path
	_group_cache[rel_path] = _snapshot_node_groups(node)
	_signal_connection_cache[rel_path] = _snapshot_signal_connections(root, node)

	# Seed the script cache so the poll doesn't false-emit script_attach
	# on its first observation of this node (every node starts unscripted
	# from the perspective of the poll until seeded here).
	var node_script_seed = node.get_script()
	if node_script_seed and node_script_seed is Script:
		_script_cache[rel_path] = (node_script_seed as Script).resource_path
	else:
		_script_cache[rel_path] = ""

	# The added node may already carry meaningful initial state
	# (for example a Sprite2D texture after duplicate/paste). Emit its
	# syncable properties on the next idle frame once the node is stable.
	call_deferred("_emit_initial_properties_for_added_node", node)


func _on_node_renamed(node: Node) -> void:
	if _suppress or _scene_sync_ticks_remaining > 0 or not _is_edited_scene_node(node): return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	var iid := node.get_instance_id()
	var new_name := str(node.name)
	var prev_entry: Dictionary = _name_cache.get(iid, {})
	var old_name: String = prev_entry.get("name", "")
	var old_path: String = prev_entry.get("rel_path", "")
	var clean_new_name := _clean_path(new_name)
	var clean_old_name := _clean_path(old_name)

	# Reconstruct old_path from old_name if cache was seeded but the
	# path segment hasn't been updated yet (handles the edge-case where
	# node was just added in the same frame).
	if old_path.is_empty() and not old_name.is_empty():
		var parent := node.get_parent()
		if parent:
			var parent_rel := _clean_path(str(root.get_path_to(parent)))
			old_path = (parent_rel + "/" + old_name) if parent_rel != "." else old_name

	# Update the cache immediately so the poll loop doesn't re-emit
	var new_rel_path := _clean_path(str(root.get_path_to(node)))
	_name_cache[iid] = {"name": clean_new_name, "rel_path": new_rel_path}

	if old_name.is_empty() or clean_old_name == clean_new_name:
		return  # first observation or no real change
	if _remote_changed_paths.has(old_path + "::name"):
		return  # this rename was applied by us from the network

	var rename_locked_path := _get_locked_path(old_path)
	if not rename_locked_path.is_empty():
		_notify_lock_blocked(rename_locked_path, "rename")
		# Revert the rename on next frame to keep editor state consistent.
		var restore_name := clean_old_name
		var node_ref := node
		_suppress = true
		(func():
			if is_instance_valid(node_ref):
				node_ref.name = restore_name
				# Restore cache to old name
				_name_cache[iid] = {"name": restore_name, "rel_path": old_path}
			_suppress = false
		).call_deferred()
		return

	_emit({
		"type": "node_rename",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": old_path,
		"data": {"new_name": clean_new_name},
	})


func _on_node_removed(node: Node) -> void:
	if _suppress: return
	if _scene_sync_ticks_remaining > 0: return
	if not _is_edited_scene_node(node): return

	var root := EditorInterface.get_edited_scene_root()
	var cached_parent: Dictionary = _parent_cache.get(node.get_instance_id(), {})
	var rel_path := String(cached_parent.get("rel_path", ""))
	if rel_path.is_empty():
		rel_path = _clean_path(str(root.get_path_to(node)))
	var parent_rel := String(cached_parent.get("parent_path", _parent_path_from_rel_path(rel_path)))

	var locked_delete_path := _get_locked_path(rel_path)
	if locked_delete_path.is_empty():
		locked_delete_path = _get_locked_path(parent_rel)
	if not locked_delete_path.is_empty():
		_notify_lock_blocked(locked_delete_path, "delete/context action")
		if _undo_redo and root:
			_defer_undo_last_scene_action(root)
		return

	var action := {
		"type": "node_delete",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": { "node_name": _clean_path(str(node.name)) },
	}
	_emit(action)
	# The SceneTree signal handled this delete; forget the node so the Xogot
	# fallback poll does not also emit a (duplicate) node_delete for it.
	if _xogot_fallback:
		_presence_cache.erase(node.get_instance_id())


func _on_inspector_property_changed(_undo_redo: Object, modified_object: Object,
		property: String, new_value: Variant) -> bool:
	if _suppress or _scene_sync_ticks_remaining > 0: return false

	if not (modified_object is Node):
		return _on_inspector_resource_property_changed(modified_object, property)

	var node: Node = modified_object as Node
	if not _is_edited_scene_node(node): return false

	var root := EditorInterface.get_edited_scene_root()
	var rel_path := _clean_path(str(root.get_path_to(node)))
	var old_node_value: Variant = node.get(property)

	if _block_if_locked(rel_path, "inspector property"):
		call_deferred("_restore_locked_node_property", rel_path, property, old_node_value)
		return true

	# Intercept script attachment: serialize as script_attach/script_detach
	# instead of generic property (Resource objects can't be serialized
	# portably via var_to_bytes).
	if property == "script":
		_handle_script_property_change(node, rel_path, new_value)
		return false

	var encoded := ActionSerializerClass.encode_property_value(new_value)
	if bool(encoded.get("ok", false)):
		_emit({
			"type": "property",
			"peer_id": _peer_id,
			"timestamp": Time.get_unix_time_from_system(),
			"node_path": rel_path,
			"data": {
				"property": property,
				"value": encoded.get("value"),
			},
		})
	return false


## Sub-resource edited in the Inspector (e.g. changing SphereMesh.radius).
## modified_object is the Resource, not the owning Node.  We schedule a
## deferred emit so the post-commit value is captured.
func _on_inspector_resource_property_changed(modified_object: Object, property: String) -> bool:
	if not (modified_object is Resource):
		return false
	var old_resource_value: Variant = (modified_object as Resource).get(property)
	var owner_path := _find_scene_node_path_owning_resource(modified_object as Resource)
	if not owner_path.is_empty() and _block_if_locked(owner_path, "resource property"):
		call_deferred(
			"_restore_locked_resource_property",
			modified_object,
			property,
			old_resource_value,
			owner_path
		)
		return true
	_schedule_inline_resource_emit(modified_object as Resource)
	return false


## When a Resource's own property is changed in the sub-inspector (e.g.
## SphereMesh.radius), walk the scene to find which Node/property references
## this resource and schedule a deferred re-emit of that property so the
## post-commit value is captured.
func _schedule_inline_resource_emit(resource: Resource) -> void:
	if _suppress: return
	if _scene_sync_ticks_remaining > 0: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return
	for node in _get_all_scene_nodes(root):
		if not _is_edited_scene_node(node): continue
		var rel_path := _clean_path(str(root.get_path_to(node)))
		for prop in _get_polled_resource_props(node):
			if _resource_contains(node.get(prop), resource):
				if _block_if_locked(rel_path, "resource property"):
					return
				# Defer so the UndoRedo commit has run before we encode.
				call_deferred("_emit_inline_resource_prop", rel_path, prop)
				return


## Emitted deferred (after UndoRedo commit) when an inline resource property
## is modified in the sub-inspector.
func _emit_inline_resource_prop(rel_path: String, prop: String) -> void:
	if _suppress: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return
	var node := _resolve_node(root, rel_path)
	if not is_instance_valid(node): return
	if _block_if_locked(rel_path, "resource property"):
		return
	var current_val: Variant = node.get(prop)
	var encoded := ActionSerializerClass.encode_property_value(current_val)
	if not bool(encoded.get("ok", false)): return
	# Update cache so the poller doesn't double-emit on the next tick.
	_resource_prop_cache[rel_path + "::" + prop] = \
		_resource_token(current_val as Resource) if current_val is Resource else current_val
	_resource_prop_value_cache[rel_path + "::" + prop] = _snapshot_property_value(current_val)
	var action := {
		"type": "property",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": {
			"property": prop,
			"value": encoded.get("value"),
		},
	}
	_emit(action)
	print("[%s] INLINE_RESOURCE: %s.%s changed" % [TAG, rel_path, prop])


## Returns the properties polled for a given node. Single source of truth for
## _poll_resource_properties, _seed_node_lock_state and the Xogot fallback — a
## property missing here has no cached baseline, so a locked-node edit could
## not be rolled back.
func _get_polled_resource_props(node: Node) -> Array[String]:
	var props: Array[String] = []
	if node is Sprite2D or node is Sprite3D:
		props.append("texture")
	if node is AnimatedSprite2D or node is AnimatedSprite3D:
		props.append_array(_get_animated_sprite_sync_props(node))
	if node is TextureRect and _has_property(node, "texture"):
		props.append("texture")
	if node is MeshInstance2D:
		props.append_array(["mesh", "texture"])
	if node is MeshInstance3D:
		props.append("mesh")
	if node is MultiMeshInstance2D or node is MultiMeshInstance3D:
		props.append("multimesh")
	if node is PointLight2D:
		props.append("texture")
	if _has_property(node, "stream"):
		props.append("stream")
	props.append_array(_get_material_resource_props(node))
	if node is CollisionShape2D or node is CollisionShape3D:
		props.append("shape")
	# PhysicsBody2D / PhysicsBody3D (incl. PhysicalBone2D/3D, RigidBody*, StaticBody*,
	# CharacterBody*) expose physics_material_override → PhysicsMaterial. Sub-inspector
	# edits (friction / rough / bounce / absorbent) need this to be polled.
	if _has_property(node, "physics_material_override"):
		props.append("physics_material_override")
	if node is AnimationPlayer:
		props.append_array(_get_animation_player_sync_props(node as AnimationPlayer))
		props.append_array(_get_animation_library_props(node as AnimationPlayer))
	for prop_name in ["visible", "modulate", "self_modulate"]:
		if _has_property(node, prop_name):
			props.append(prop_name)
	if node is Label or node is RichTextLabel or node is Button \
			or node is LineEdit or node is TextEdit:
		if _has_property(node, "text"):
			props.append("text")
	if node is ColorRect:
		props.append("color")
	if node is Range:
		props.append("value")
	if node is BoxContainer:
		props.append_array(["vertical", "alignment"])
	if node is Control:
		props.append_array([
			"layout_mode", "custom_minimum_size",
			"size_flags_horizontal", "size_flags_vertical",
			"grow_horizontal", "grow_vertical",
		])

	var unique_props: Array[String] = []
	for prop_name in props:
		if not unique_props.has(prop_name):
			unique_props.append(prop_name)
	return unique_props


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


func _get_material_resource_props(node: Node) -> Array[String]:
	# Same list get_property_list() would give, without building it: that list
	# has hundreds of entries for a Control and the pollers call this for every
	# node, ten times a second.
	var props: Array[String] = []
	if node is MeshInstance3D:
		for i in (node as MeshInstance3D).get_surface_override_material_count():
			props.append("surface_material_override/%d" % i)
	for prop_name in ["material", "material_override", "material_overlay", "process_material"]:
		if prop_name in node:
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


func _select_autoplay_animation_if_present(node: Node, value: Variant,
		rel_path: String) -> void:
	var animation_name := String(value).strip_edges()
	if animation_name.is_empty():
		return
	var clean_path := _clean_path(rel_path)
	if node is AnimationPlayer:
		var player := node as AnimationPlayer
		if player.has_animation(animation_name) \
				and String(player.current_animation) != animation_name:
			player.current_animation = animation_name
			_remote_changed_paths[clean_path + "::current_animation"] = true
	elif node is AnimatedSprite2D or node is AnimatedSprite3D:
		var sprite_frames := node.get("sprite_frames") as SpriteFrames
		if sprite_frames and sprite_frames.has_animation(animation_name) \
				and String(node.get("animation")) != animation_name:
			node.set("animation", StringName(animation_name))
			_remote_changed_paths[clean_path + "::animation"] = true


func _resource_contains(candidate: Variant, target: Resource, depth: int = 0) -> bool:
	if candidate == target:
		return true
	if depth >= ActionSerializerClass.MAX_INLINE_DEPTH:
		return false
	if candidate is Resource:
		var resource := candidate as Resource
		for prop in resource.get_property_list():
			var usage: int = int(prop.get("usage", 0))
			if usage & PROPERTY_USAGE_STORAGE == 0:
				continue
			var prop_name := String(prop.get("name", ""))
			if prop_name in ["script", "resource_path", "resource_name"]:
				continue
			if _resource_contains(resource.get(prop_name), target, depth + 1):
				return true
	elif candidate is Array:
		for item in candidate:
			if _resource_contains(item, target, depth + 1):
				return true
	elif candidate is Dictionary:
		for key in candidate:
			if _resource_contains(candidate[key], target, depth + 1):
				return true
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
		_script_cache[rel_path] = ""  # suppress poll double-emit
		_emit(action)
		return

	if not (new_value is Script):
		return

	var script_res: Script = new_value as Script
	var script_path: String = script_res.resource_path
	var script_content: String = script_res.source_code

	# For a brand-new script the source_code field may not yet be populated
	# in the resource cache. Fall back to reading the file from disk.
	if script_content.is_empty() and not script_path.is_empty():
		var f := FileAccess.open(script_path, FileAccess.READ)
		if f:
			script_content = f.get_as_text()
			f.close()

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
	_script_cache[rel_path] = script_path  # suppress poll double-emit
	_emit(action)


# ═════════════════════════════════════════════════════════════════════
#  Apply Remote Actions
# ═════════════════════════════════════════════════════════════════════

func apply_remote_action(action: Dictionary) -> void:
	_suppress = true

	# First remote state packet (node_add or property) from a peer who
	# already had the scene open → we've received authoritative data,
	# clear the sync guard so local polling can resume immediately.
	var action_type_for_guard: String = action.get("type", "")
	if _scene_sync_ticks_remaining > 0 \
			and action_type_for_guard in ["node_add", "property", "scene_guides", "scene_state"]:
		_scene_sync_ticks_remaining = 0
		print("[%s] Scene sync guard cleared by remote %s" % [TAG, action_type_for_guard])

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
		"node_rename":
			_apply_node_rename(action, root)
		"node_reorder":
			_apply_node_reorder(action, root)
		"script_attach":
			_apply_script_attach(action, root)
		"script_detach":
			_apply_script_detach(action, root)
		"scene_guides":
			_apply_scene_guides(action, root)
		"scene_state":
			_apply_scene_state(action, root)

	_suppress = false


## Applies a scene_state packet (initial state of many nodes, see
## _send_initial_state in the plugin): the missing nodes first, then every
## property in a single undo action, then the scripts.
func _apply_scene_state(action: Dictionary, root: Node) -> void:
	var entries: Array = action.get("data", {}).get("nodes", [])
	var base := {
		"peer_id": action.get("peer_id", ""),
		"peer_name": action.get("peer_name", ""),
		"timestamp": action.get("timestamp", 0.0),
		"scene_path": action.get("scene_path", ""),
	}
	# The sender walks the tree depth first, so parents come before children.
	for entry in entries:
		if entry.has("add"):
			var add_action := base.duplicate()
			add_action["type"] = "node_add"
			add_action["node_path"] = entry.get("node_path", "")
			add_action["data"] = entry["add"]
			_apply_node_add(add_action, root)

	var changes: Array = []
	for entry in entries:
		var props: Dictionary = entry.get("props", {})
		for prop in props:
			var prop_action := base.duplicate()
			prop_action["type"] = "property"
			prop_action["node_path"] = entry.get("node_path", "")
			prop_action["data"] = {"property": prop, "value": props[prop]}
			var change := _prepare_property(prop_action, root)
			if not change.is_empty():
				changes.append(change)
	_commit_property_changes(changes, "Remote: scene state (%d properties)" % changes.size())

	for entry in entries:
		if entry.has("script"):
			var script_action := base.duplicate()
			script_action["type"] = "script_attach"
			script_action["node_path"] = entry.get("node_path", "")
			script_action["data"] = entry["script"]
			_apply_script_attach(script_action, root)


func _apply_select(action: Dictionary, _root: Node) -> void:
	var paths: Array = action.get("data", {}).get("paths", [])
	var is_heartbeat := bool(action.get("data", {}).get("heartbeat", false))
	var peer_id: String = action.get("peer_id", "")
	var peer_name: String = String(action.get("peer_name", "")).strip_edges()
	var who := peer_name if not peer_name.is_empty() else peer_id

	if _lock_manager and not peer_id.is_empty():
		_lock_manager.update_peer_selection(peer_id, paths, peer_name)

	if not is_heartbeat:
		print("[%s] Remote '%s' selected: %s" % [TAG, who, paths])


## Apply a remote property change via EditorUndoRedoManager so the
## editor viewport, inspector, and scene-unsaved indicator all update.
func _apply_property(action: Dictionary, root: Node) -> void:
	var change := _prepare_property(action, root)
	if change.is_empty():
		return
	_commit_property_changes([change], "Remote: %s.%s" % [change["rel_path"], change["prop"]])


## Resolves and decodes one remote property change. Returns
## {target, prop, value, old_value, rel_path}, or {} when the change was
## queued for a retry or skipped.
func _prepare_property(action: Dictionary, root: Node) -> Dictionary:
	var rel_path: String = action.get("node_path", "")
	var data: Dictionary = action.get("data", {})
	if rel_path.is_empty() or data.is_empty(): return {}

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		# Node not found yet — could be a UndoRedo one-frame lag after node_add.
		# Queue for retry instead of silently dropping.
		_queue_pending(action)
		return {}

	var prop: String = data.get("property", "")
	if prop.is_empty(): return {}
	var decoded := ActionSerializerClass.decode_property_value(data.get("value"))
	if not bool(decoded.get("ok", false)):
		var reason := String(decoded.get("reason", "decode failed"))
		if reason == "resource load failed":
			action["_pending_max_retries"] = PENDING_RESOURCE_MAX_RETRIES
			var retries_before := int(action.get("_retry_count", 0))
			_queue_pending(action)
			if retries_before == 0:
				print("[%s] Waiting for resource before applying %s.%s: %s" % [
					TAG,
					rel_path,
					prop,
					String(decoded.get("resource_path", "")),
				])
			return {}
		push_warning("[%s] Skipped property sync for '%s.%s': %s" % [
			TAG, rel_path, prop, reason])
		return {}
	var value: Variant = decoded.get("value")
	return {
		"target": target,
		"prop": prop,
		"value": value,
		"old_value": target.get(prop),
		"rel_path": rel_path,
	}


## Applies prepared property changes as one undo action.
func _commit_property_changes(changes: Array, label: String) -> void:
	if changes.is_empty():
		return
	# Use EditorUndoRedoManager to apply the change so the editor UI
	# (viewport, inspector, scene unsaved indicator) updates properly.
	if _undo_redo:
		_undo_redo.create_action(label, UndoRedo.MERGE_DISABLE, changes[0]["target"])
		for change in changes:
			_undo_redo.add_do_property(change["target"], change["prop"], change["value"])
			_undo_redo.add_undo_property(change["target"], change["prop"], change["old_value"])
		_undo_redo.commit_action(true)
	else:
		# Fallback if UndoRedo is not available (should not happen)
		for change in changes:
			change["target"].set(change["prop"], change["value"])
			change["target"].notify_property_list_changed()
	for change in changes:
		_after_property_applied(change["target"], change["prop"], change["value"], change["rel_path"])


func _after_property_applied(target: Node, prop: String, value: Variant, rel_path: String) -> void:
	if target is AnimationPlayer and prop.begins_with("libraries/"):
		target.notify_property_list_changed()
	if target is AnimationPlayer \
			and prop in _get_animation_player_sync_props(target as AnimationPlayer):
		if prop == "autoplay":
			_select_autoplay_animation_if_present(target, value, rel_path)
		target.notify_property_list_changed()
	if (target is AnimatedSprite2D or target is AnimatedSprite3D) \
			and prop in _get_animated_sprite_sync_props(target):
		if prop == "autoplay":
			_select_autoplay_animation_if_present(target, value, rel_path)
		if prop == "sprite_frames" and value is Resource:
			(value as Resource).emit_changed()
		target.notify_property_list_changed()
	if (target is AudioStreamPlayer or target is AudioStreamPlayer2D \
			or target is AudioStreamPlayer3D) and prop == "stream":
		target.notify_property_list_changed()
	if prop in _get_material_resource_props(target):
		target.notify_property_list_changed()

	# Mark this path so the transform poller does NOT re-broadcast
	# the change as if it were a local edit (prevents echo loop).
	var clean_path := _clean_path(rel_path)
	_remote_changed_paths[clean_path] = true
	# Also suppress the resource-property poller for this specific prop
	_remote_changed_paths[clean_path + "::" + prop] = true
	# Echo guard for the (throttled) Xogot generic poller: record the applied
	# value so a poll cycle that runs after _remote_changed_paths was cleared
	# still sees an up-to-date cache and does not re-broadcast the change.
	if _xogot_fallback and not (value is Object):
		var generic_key := clean_path + "::" + prop
		_generic_prop_cache[generic_key] = _generic_token(value)
		_generic_prop_value_cache[generic_key] = _snapshot_property_value(value)

	if VERBOSE_LOG:
		print("[%s] Applied: %s.%s = %s" % [TAG, rel_path, prop, value])


func _emit_initial_properties_for_added_node(node: Node) -> void:
	if _suppress:
		return
	# If a scene sync guard is active this node was loaded from disk as part
	# of a scene open — remote peers are the source of truth, don't overwrite
	# their authoritative state with stale file-position data.
	if _scene_sync_ticks_remaining > 0:
		return
	if not is_instance_valid(node):
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return
	if not _is_edited_scene_node(node):
		return

	var rel_path := _clean_path(str(root.get_path_to(node)))
	if _is_locked(rel_path) or _is_locked(_parent_path_from_rel_path(rel_path)):
		return
	for prop_name in _get_sync_properties(node):
		var encoded := ActionSerializerClass.encode_property_value(node.get(prop_name))
		if not bool(encoded.get("ok", false)):
			continue
		_emit_property(rel_path, prop_name, encoded.get("value"))


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


func _has_property(node: Node, property_name: String) -> bool:
	return property_name in node


func _apply_node_add(action: Dictionary, root: Node) -> void:
	var data: Dictionary = action.get("data", {})
	var parent_rel: String = data.get("parent_path", "")
	var node_type: String = data.get("node_type", "Node")
	var node_name: String = data.get("node_name", "NewNode")

	# Find parent: empty or "." = root
	var parent: Node = _resolve_node(root, parent_rel)
	if not parent:
		# Parent not found yet — queue for retry (may arrive after a node_add chain)
		_queue_pending(action)
		return

	# Check if node already exists — use _resolve_node so a node renamed to
	# "ok 🔒" by the lock overlay is still found when the incoming name is "ok".
	var expected_rel: String = (parent_rel + "/" + node_name) \
			if (parent_rel != "" and parent_rel != ".") else node_name
	if _resolve_node(root, expected_rel) != null:
		return

	var new_node: Node = null
	var instance_scene: String = data.get("scene_instance", "")
	if not instance_scene.is_empty():
		# Replicate an instanced sub-scene from its PackedScene file. Returns
		# null when the .tscn is not yet available locally (queued for retry,
		# giving file-sync time to deliver it) or when it is rejected.
		new_node = _instantiate_scene_instance(instance_scene, action)
		if not new_node:
			return
	else:
		# Validate node type against whitelist
		if not _is_safe_node_type(node_type):
			push_warning("[%s] Blocked unsafe node type from network: %s" % [TAG, node_type])
			return
		new_node = ClassDB.instantiate(StringName(node_type))
		if not new_node:
			push_warning("[%s] Cannot instantiate: %s" % [TAG, node_type])
			return

	new_node.name = node_name

	var child_index: int = data.get("child_index", -1)

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

	# Reposition the node at the sender's child index so scene tree order matches.
	if child_index >= 0 and child_index < parent.get_child_count():
		parent.move_child(new_node, child_index)
		_child_order_cache[expected_rel] = child_index

	# Record presence so the Xogot fallback poll treats this remotely-added node
	# as known and never echoes it back as a local node_add.
	if _xogot_fallback:
		_presence_cache[new_node.get_instance_id()] = expected_rel

	if VERBOSE_LOG:
		print("[%s] Added: %s/%s (%s) idx=%d" % [TAG, parent_rel, node_name, node_type, child_index])


## Instantiate the PackedScene referenced by an incoming node_add and return
## its root, ready to be parented as an editor instance. Returns null when:
##   • the path is unsafe (not res:// or contains ".."),
##   • the .tscn is not yet present locally — the action is re-queued with the
##     longer resource retry budget so file-sync can deliver it first,
##   • the scene's root type is not in the node whitelist.
func _instantiate_scene_instance(scene_path: String, action: Dictionary) -> Node:
	if not scene_path.begins_with("res://") or ".." in scene_path:
		push_warning("[%s] Rejected scene instance with unsafe path: '%s'" % [TAG, scene_path])
		return null

	if not ResourceLoader.exists(scene_path):
		# Not synced yet — wait for the file_create to arrive.
		action["_pending_max_retries"] = PENDING_RESOURCE_MAX_RETRIES
		_queue_pending(action)
		return null

	var packed := ResourceLoader.load(
		scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) as PackedScene
	if not packed:
		action["_pending_max_retries"] = PENDING_RESOURCE_MAX_RETRIES
		_queue_pending(action)
		return null

	# Validate the instance's root type against the same whitelist as raw nodes.
	var state := packed.get_state()
	if state and state.get_node_count() > 0:
		var root_type := String(state.get_node_type(0))
		if not root_type.is_empty() and not _is_safe_node_type(root_type):
			push_warning("[%s] Blocked unsafe scene instance root type: %s (%s)" % [
				TAG, root_type, scene_path])
			return null

	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if not instance:
		push_warning("[%s] Failed to instantiate scene: %s" % [TAG, scene_path])
		return null
	print("[%s] Instantiated scene: %s" % [TAG, scene_path])
	return instance


func _apply_node_delete(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	if rel_path.is_empty() or rel_path == ".": return  # don't delete root

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		return  # already deleted, no warning

	# Forget the node before removing it so the Xogot fallback poll does not
	# re-emit a local node_delete for this remotely-driven deletion.
	if _xogot_fallback:
		_presence_cache.erase(target.get_instance_id())

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


func _apply_node_rename(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	var new_name: String = action.get("data", {}).get("new_name", "")
	if rel_path.is_empty() or new_name.is_empty():
		return
	var target: Node = _resolve_node(root, rel_path)
	if not target:
		_queue_pending(action)
		return
	var old_name := str(target.name)
	if old_name == new_name:
		return
	if _undo_redo:
		_undo_redo.create_action(
			"Remote: Rename %s → %s" % [old_name, new_name],
			UndoRedo.MERGE_DISABLE,
			target
		)
		_undo_redo.add_do_property(target, "name", new_name)
		_undo_redo.add_undo_property(target, "name", old_name)
		_undo_redo.commit_action(true)
	else:
		target.name = new_name
	var clean_path := _clean_path(rel_path)
	_remote_changed_paths[clean_path + "::name"] = true
	print("[%s] Renamed: %s → %s" % [TAG, rel_path, new_name])


func _apply_node_reorder(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	var child_index: int = action.get("data", {}).get("child_index", -1)
	if rel_path.is_empty() or child_index < 0:
		return

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		_queue_pending(action)
		return

	var parent := target.get_parent()
	if not parent:
		return

	var current_idx: int = target.get_index()
	if current_idx == child_index:
		return

	# Clamp to valid range.
	var max_idx: int = parent.get_child_count() - 1
	var clamped_idx: int = clampi(child_index, 0, max_idx)

	parent.move_child(target, clamped_idx)

	# Update order cache so the next poll cycle doesn't re-emit this change.
	_child_order_cache[rel_path] = clamped_idx
	print("[%s] Reordered: %s to idx=%d" % [TAG, rel_path, clamped_idx])


func _apply_script_attach(action: Dictionary, root: Node) -> void:
	var rel_path: String = action.get("node_path", "")
	var data: Dictionary = action.get("data", {})
	var script_path: String = data.get("script_path", "")
	var script_content: String = data.get("script_content", "")

	if rel_path.is_empty() or script_path.is_empty():
		return

	var target: Node = _resolve_node(root, rel_path)
	if not target:
		_queue_pending(action)
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


func _apply_scene_guides(action: Dictionary, root: Node) -> void:
	var data: Dictionary = action.get("data", {})
	if data.is_empty():
		return

	var old_guides := _get_scene_guides(root)
	var new_guides := _normalize_scene_guides(data)
	if _guides_equal(old_guides, new_guides):
		_scene_guides_cache = new_guides.duplicate(true)
		return

	if _undo_redo:
		_undo_redo.create_action(
			"Remote: Scene Guides",
			UndoRedo.MERGE_DISABLE,
			root
		)
		_undo_redo.add_do_method(self, "_set_scene_guides", root, new_guides)
		_undo_redo.add_undo_method(self, "_set_scene_guides", root, old_guides)
		_undo_redo.commit_action(true)
	else:
		_set_scene_guides(root, new_guides)

	_scene_guides_cache = new_guides.duplicate(true)
	_remote_scene_guides_changed = true
	print("[%s] Applied scene guides: vertical=%d horizontal=%d" % [
		TAG,
		new_guides.get("vertical", []).size(),
		new_guides.get("horizontal", []).size(),
	])


# ═════════════════════════════════════════════════════════════════════
#  Robust Node Path Resolution
# ═════════════════════════════════════════════════════════════════════

## Resolve a scene-relative path to a Node, accounting for the
## LockOverlay's 🔒 suffix decoration on node names.
## Handles BOTH directions:
##   - Path "CSGSphere3D3" → node named "CSGSphere3D3 🔒" (add suffix)
##   - Path "CSGSphere3D3 🔒" → node named "CSGSphere3D3" (strip suffix)
## Park an action for deferred retry (node not yet in scene tree).
func _queue_pending(action: Dictionary) -> void:
	var retries: int = action.get("_retry_count", 0)
	var max_retries: int = int(action.get("_pending_max_retries", PENDING_MAX_RETRIES))
	if retries >= max_retries:
		push_warning("[%s] Dropped pending %s for '%s' after %d retries" % [
			TAG,
			String(action.get("type", "?")),
			String(action.get("node_path", "?")),
			retries,
		])
		return
	action["_retry_count"] = retries + 1
	_pending_actions.append(action)


## Called every poll tick from the plugin. Re-applies queued actions
## whose target node has since appeared in the scene tree.
func retry_pending() -> void:
	# Tick down the scene-sync guard (fallback timeout).
	if _scene_sync_ticks_remaining > 0:
		_scene_sync_ticks_remaining -= 1
		if _scene_sync_ticks_remaining == 0:
			print("[%s] Scene sync guard expired (timeout)" % TAG)

	if _pending_actions.is_empty():
		return
	var pending := _pending_actions
	_pending_actions = []
	for action in pending:
		var root := EditorInterface.get_edited_scene_root()
		if not root:
			_queue_pending(action)
			continue
		var atype: String = action.get("type", "")
		var rel_path: String = action.get("node_path", "")
		# node_add creates a node that does NOT exist yet, so we cannot gate the
		# retry on resolving node_path (it would never resolve). Re-apply it
		# unconditionally — _apply_node_add is idempotent and re-queues itself
		# while its parent (or instanced .tscn) is still missing. Every other
		# action targets an existing node, so wait until node_path resolves.
		var ready: bool = (atype == "node_add") or (_resolve_node(root, rel_path) != null)
		if ready:
			print("[%s] Retry %s for '%s' (attempt %d)" % [
				TAG, atype, rel_path, action.get("_retry_count", 1)])
			apply_remote_action(action)
		else:
			_queue_pending(action)   # will increment counter and drop if over limit


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

	# 3. Walk segment by segment, trying each desktop/Xogot suffix.
	var parts := cleaned.split("/")
	var current: Node = root
	for part in parts:
		var child := current.get_node_or_null(NodePath(part))
		if not child:
			# Try with each lock decoration suffix (desktop + Xogot markers).
			for suffix in LOCK_SUFFIXES:
				child = current.get_node_or_null(NodePath(part + suffix))
				if child:
					break
		if not child:
			return null
		current = child
	return current


# ═════════════════════════════════════════════════════════════════════
#  Helpers
# ═════════════════════════════════════════════════════════════════════

func _defer_undo_last_scene_action(root: Node) -> void:
	if not _undo_redo:
		return
	var was_suppress := _suppress
	_suppress = true
	var scene_root := root
	var ur := _undo_redo
	(func():
		if is_instance_valid(scene_root):
			var history_id := ur.get_object_history_id(scene_root)
			var history_ur: UndoRedo = ur.get_history_undo_redo(history_id)
			history_ur.undo()
		_suppress = was_suppress
	).call_deferred()


func _revert_added_node(node: Node, root: Node) -> void:
	if _undo_redo and root:
		_defer_undo_last_scene_action(root)
		return
	var was_suppress := _suppress
	_suppress = true
	var node_ref := node
	(func():
		if is_instance_valid(node_ref):
			var parent := node_ref.get_parent()
			if parent:
				parent.remove_child(node_ref)
			node_ref.queue_free()
		_suppress = was_suppress
	).call_deferred()


func _restore_node_parent(root: Node, node: Node,
		parent_rel: String, child_index: int) -> void:
	var target_parent := _resolve_node(root, parent_rel)
	if not target_parent or not is_instance_valid(node):
		return
	var was_suppress := _suppress
	_suppress = true
	var current_parent := node.get_parent()
	if current_parent and current_parent != target_parent:
		current_parent.remove_child(node)
	if node.get_parent() == null:
		target_parent.add_child(node, true)
		node.owner = root
	if node.get_parent() == target_parent:
		var max_idx := maxi(target_parent.get_child_count() - 1, 0)
		target_parent.move_child(node, clampi(child_index, 0, max_idx))
	_suppress = was_suppress


func _restore_node_property(node: Node, prop: String, value: Variant) -> void:
	if not is_instance_valid(node):
		return
	var was_suppress := _suppress
	_suppress = true
	if prop == "script":
		node.set_script(value)
	else:
		node.set(prop, value)
	node.notify_property_list_changed()
	_suppress = was_suppress


func _restore_locked_node_property(rel_path: String, prop: String, value: Variant) -> void:
	if not _is_locked(rel_path):
		return
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return
	var node := _resolve_node(root, rel_path)
	if not node:
		return
	_restore_node_property(node, prop, value)
	var key := _clean_path(rel_path) + "::" + prop
	_resource_prop_cache[key] = _property_cache_token(value)
	_resource_prop_value_cache[key] = _snapshot_property_value(value)
	_generic_prop_cache[key] = _generic_token(value)
	_generic_prop_value_cache[key] = _snapshot_property_value(value)


func _restore_locked_resource_property(resource: Resource, prop: String,
		value: Variant, owner_path: String) -> void:
	if not is_instance_valid(resource) or not _is_locked(owner_path):
		return
	var was_suppress := _suppress
	_suppress = true
	resource.set(prop, value)
	resource.emit_changed()
	_suppress = was_suppress


func _restore_control_transform(ctrl: Control, state: Array) -> void:
	if not is_instance_valid(ctrl) or state.size() != 13:
		return
	var was_suppress := _suppress
	_suppress = true
	ctrl.anchor_left = state[0]
	ctrl.anchor_right = state[1]
	ctrl.anchor_top = state[2]
	ctrl.anchor_bottom = state[3]
	ctrl.offset_left = state[4]
	ctrl.offset_right = state[5]
	ctrl.offset_top = state[6]
	ctrl.offset_bottom = state[7]
	ctrl.rotation = state[8]
	ctrl.scale = Vector2(state[9], state[10])
	ctrl.pivot_offset = Vector2(state[11], state[12])
	_suppress = was_suppress


func _restore_script_path(node: Node, script_path: String) -> void:
	if script_path.is_empty():
		_restore_node_property(node, "script", null)
		return
	var script_res := ResourceLoader.load(
		script_path, "Script", ResourceLoader.CACHE_MODE_REUSE) as Script
	if script_res:
		_restore_node_property(node, "script", script_res)


func _snapshot_node_groups(node: Node) -> Array[String]:
	var groups: Array[String] = []
	for group in node.get_groups():
		var group_name := String(group)
		if group_name.begins_with("_"):
			continue
		groups.append(group_name)
	groups.sort()
	return groups


func _restore_node_groups(node: Node, desired_groups: Array) -> void:
	var was_suppress := _suppress
	_suppress = true
	var current_groups := _snapshot_node_groups(node)
	for group in current_groups:
		if group not in desired_groups:
			node.remove_from_group(StringName(group))
	for group in desired_groups:
		var group_name := String(group)
		if not node.is_in_group(StringName(group_name)):
			node.add_to_group(StringName(group_name), true)
	_suppress = was_suppress


func _snapshot_signal_connections(root: Node, node: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for signal_info in node.get_signal_list():
		var signal_name := String(signal_info.get("name", ""))
		if signal_name.is_empty():
			continue
		for connection in node.get_signal_connection_list(StringName(signal_name)):
			var callable: Callable = connection.get("callable", Callable())
			var target_obj := callable.get_object()
			if not (target_obj is Node):
				continue
			var target_node := target_obj as Node
			if not _is_edited_scene_node(target_node):
				continue
			result.append({
				"signal": signal_name,
				"target_path": _clean_path(str(root.get_path_to(target_node))),
				"method": String(callable.get_method()),
				"flags": int(connection.get("flags", 0)),
				"binds": callable.get_bound_arguments(),
			})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _connection_key(a) < _connection_key(b)
	)
	return result


func _restore_signal_connections(root: Node, node: Node,
		desired_connections: Array) -> void:
	var was_suppress := _suppress
	_suppress = true

	var desired_keys: Dictionary = {}
	for entry in desired_connections:
		desired_keys[_connection_key(entry)] = entry

	var current := _snapshot_signal_connections(root, node)
	var current_keys: Dictionary = {}
	for entry in current:
		var key := _connection_key(entry)
		current_keys[key] = true
		if desired_keys.has(key):
			continue
		var callable := _callable_from_connection_snapshot(root, entry)
		if is_instance_valid(callable.get_object()) \
				and node.is_connected(StringName(entry.get("signal", "")), callable):
			node.disconnect(StringName(entry.get("signal", "")), callable)

	for key in desired_keys.keys():
		if current_keys.has(key):
			continue
		var entry: Dictionary = desired_keys[key]
		var callable := _callable_from_connection_snapshot(root, entry)
		if not is_instance_valid(callable.get_object()):
			continue
		var signal_name := StringName(entry.get("signal", ""))
		if not node.is_connected(signal_name, callable):
			node.connect(signal_name, callable, int(entry.get("flags", 0)))

	_suppress = was_suppress


func _callable_from_connection_snapshot(root: Node, entry: Dictionary) -> Callable:
	var target_path := String(entry.get("target_path", ""))
	var target := _resolve_node(root, target_path)
	if not target:
		return Callable()
	var callable := Callable(target, StringName(entry.get("method", "")))
	var binds: Array = entry.get("binds", [])
	for bind_value in binds:
		callable = callable.bind(bind_value)
	return callable


func _connection_key(entry: Dictionary) -> String:
	return "%s|%s|%s|%d|%s" % [
		String(entry.get("signal", "")),
		String(entry.get("target_path", "")),
		String(entry.get("method", "")),
		int(entry.get("flags", 0)),
		var_to_str(entry.get("binds", [])),
	]


func _find_scene_node_path_owning_resource(resource: Resource) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return ""
	for node in _get_all_scene_nodes(root):
		if not _is_edited_scene_node(node):
			continue
		for prop in _get_polled_resource_props(node):
			if _resource_contains(node.get(prop), resource):
				return _clean_path(str(root.get_path_to(node)))
	return ""


func _is_edited_scene_node(node: Node) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	if not root: return false
	return node == root or node.owner == root


## True when `parent` lies inside an instanced sub-scene, i.e. a node added
## under it belongs to that instance rather than to the edited scene. Used at
## `node_added` time, where `node.owner` is not yet populated, so we reason
## about the parent (whose owner / scene_file_path ARE valid).
##
## Cases:
##   • parent == root            → editable scene node, not internal.
##   • parent.scene_file_path set → parent is an instance root; its direct
##                                  children are instance internals.
##   • parent.owner != root       → parent is itself an instance internal, so
##                                  anything below it is internal too.
func _is_instance_internal(parent: Node, root: Node) -> bool:
	if parent == root:
		return false
	if not str(parent.scene_file_path).is_empty():
		return true
	if parent.owner != root:
		return true
	return false


func _should_block_outgoing_action(action: Dictionary) -> bool:
	var action_type := String(action.get("type", ""))
	var rel_path := String(action.get("node_path", ""))
	match action_type:
		"property", "script_attach", "script_detach":
			return _block_if_locked(rel_path, action_type)
		"node_delete", "node_rename", "node_reorder":
			return _block_if_locked(rel_path, action_type)
		"node_add":
			var data: Dictionary = action.get("data", {})
			var parent_rel := String(data.get("parent_path", ""))
			if _block_child_mutation_if_locked(parent_rel, "node_add"):
				return true
			var selected_locked := _get_selected_locked_path()
			if not selected_locked.is_empty():
				_notify_lock_blocked(selected_locked, "node_add/context action")
				return true
		"scene_guides":
			return _block_if_locked(".", "scene guides")
	return false


func _emit(action: Dictionary) -> void:
	if _should_block_outgoing_action(action):
		return
	action_captured.emit(action)


# ═════════════════════════════════════════════════════════════════════
#  Transform Polling (catches viewport drag / gizmo changes)
# ═════════════════════════════════════════════════════════════════════

func _poll_transforms() -> void:
	if _suppress: return
	if _scene_sync_ticks_remaining > 0: return  # waiting for remote authoritative state
	# Guard against mid-hot-reload invocation: instance vars can be transiently nil
	# when a script file is rewritten on disk (e.g. pulled from commons) and Godot
	# begins recompiling the script before the timer stops firing.
	if not _child_order_cache is Dictionary: return
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	var nodes := _get_all_scene_nodes(root)
	var new_cache: Dictionary = {}
	var new_name_cache: Dictionary = {}
	var new_parent_cache: Dictionary = {}

	for node in nodes:
		# Always use the CLEAN path (no lock suffix) for both the
		# cache key and the outgoing action, so all peers agree on
		# the same canonical names.
		var rel_path := _clean_path(str(root.get_path_to(node)))
		var iid := node.get_instance_id()

		# ── Block reparenting while the moved node or either parent is locked ──
		var parent_rel := "."
		var current_idx := 0
		if node != root:
			var parent := node.get_parent()
			if parent:
				parent_rel = _clean_path(str(root.get_path_to(parent)))
				current_idx = node.get_index()
			var old_parent_entry: Dictionary = _parent_cache.get(iid, {})
			if not old_parent_entry.is_empty():
				var old_parent_rel := String(old_parent_entry.get("parent_path", parent_rel))
				var old_rel_path := String(old_parent_entry.get("rel_path", rel_path))
				var old_child_idx := int(old_parent_entry.get("child_index", current_idx))
				if parent_rel != old_parent_rel:
					var locked_reparent_path := _get_locked_path(old_rel_path)
					if locked_reparent_path.is_empty():
						locked_reparent_path = _get_locked_path(old_parent_rel)
					if locked_reparent_path.is_empty():
						locked_reparent_path = _get_locked_path(parent_rel)
					if not locked_reparent_path.is_empty():
						_notify_lock_blocked(locked_reparent_path, "reparent/context action")
						_restore_node_parent(root, node, old_parent_rel, old_child_idx)
						rel_path = _clean_path(str(root.get_path_to(node)))
						parent_rel = old_parent_rel
						current_idx = node.get_index()
			new_parent_cache[iid] = {
				"parent_path": parent_rel,
				"child_index": current_idx,
				"rel_path": rel_path,
			}

		# ── Poll node name changes ─────────────────────────────────
		# Keep the name cache current so _on_node_renamed has the previous
		# name available. Emission is handled by the signal, not here.
		var current_name := _clean_path(str(node.name))
		new_name_cache[iid] = {"name": current_name, "rel_path": rel_path}

		# ── Poll script attachment changes ──────────────────────
		var current_script_path: String = ""
		var node_script = node.get_script()
		if node_script and node_script is Script:
			current_script_path = node_script.resource_path

		var cached_script: String = _script_cache.get(rel_path, "")
		if current_script_path != cached_script:
			if not _remote_changed_paths.has(rel_path + "::script"):
				if _block_if_locked(rel_path, "script attach/detach"):
					_restore_script_path(node, cached_script)
					current_script_path = cached_script
				elif current_script_path.is_empty():
					_emit({
						"type": "script_detach",
						"peer_id": _peer_id,
						"timestamp": Time.get_unix_time_from_system(),
						"node_path": rel_path,
						"data": { "script_path": cached_script },
					})
				else:
					var poll_content: String = node_script.source_code
					# New scripts may not yet have source_code populated in the resource.
					# Read from disk as fallback so the receiver gets the actual code.
					if poll_content.is_empty() and not current_script_path.is_empty():
						var f := FileAccess.open(current_script_path, FileAccess.READ)
						if f:
							poll_content = f.get_as_text()
							f.close()
					_emit({
						"type": "script_attach",
						"peer_id": _peer_id,
						"timestamp": Time.get_unix_time_from_system(),
						"node_path": rel_path,
						"data": {
							"script_path": current_script_path,
							"script_content": poll_content,
						},
					})
			_script_cache[rel_path] = current_script_path

		# ── Poll groups and signal connections from the Node dock ─────
		var current_groups := _snapshot_node_groups(node)
		if _group_cache.has(rel_path):
			var cached_groups: Array = _group_cache[rel_path]
			if var_to_str(current_groups) != var_to_str(cached_groups):
				if _block_if_locked(rel_path, "groups"):
					_restore_node_groups(node, cached_groups)
					current_groups = cached_groups.duplicate()
		_group_cache[rel_path] = current_groups

		var current_connections := _snapshot_signal_connections(root, node)
		if _signal_connection_cache.has(rel_path):
			var cached_connections: Array = _signal_connection_cache[rel_path]
			if var_to_str(current_connections) != var_to_str(cached_connections):
				if _block_if_locked(rel_path, "signals"):
					_restore_signal_connections(root, node, cached_connections)
					current_connections = cached_connections.duplicate(true)
		_signal_connection_cache[rel_path] = current_connections

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
					if _block_if_locked(rel_path, "viewport transform"):
						new_cache[rel_path] = old_t
						_queue_locked_transform_restore(rel_path, old_t)
						continue
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
					if _block_if_locked(rel_path, "viewport transform"):
						new_cache[rel_path] = old_t
						_queue_locked_transform_restore(rel_path, old_t)
						continue
					_emit_property(rel_path, "position", n2d.position)
					_emit_property(rel_path, "rotation", n2d.rotation)
					_emit_property(rel_path, "scale", n2d.scale)

		elif node is Control:
			var ctrl: Control = node as Control
			# Cache as [anchor_left, anchor_right, anchor_top, anchor_bottom,     [0-3]
			#            offset_left, offset_right, offset_top, offset_bottom,    [4-7]
			#            rotation, scale.x, scale.y, pivot_offset.x, pivot_offset.y] [8-12]
			var cur_state: Array = [
				ctrl.anchor_left, ctrl.anchor_right, ctrl.anchor_top, ctrl.anchor_bottom,
				ctrl.offset_left, ctrl.offset_right, ctrl.offset_top, ctrl.offset_bottom,
				ctrl.rotation, ctrl.scale.x, ctrl.scale.y, ctrl.pivot_offset.x, ctrl.pivot_offset.y
			]
			new_cache[rel_path] = cur_state

			if _remote_changed_paths.has(rel_path):
				continue

			var old_state: Array = _transform_cache.get(rel_path, [])
			if old_state.size() == 13:
				var control_changed: bool = cur_state[0] != old_state[0] or cur_state[1] != old_state[1] \
						or cur_state[2] != old_state[2] or cur_state[3] != old_state[3] \
						or cur_state[4] != old_state[4] or cur_state[5] != old_state[5] \
						or cur_state[6] != old_state[6] or cur_state[7] != old_state[7] \
						or cur_state[8] != old_state[8] \
						or cur_state[9] != old_state[9] or cur_state[10] != old_state[10] \
						or cur_state[11] != old_state[11] or cur_state[12] != old_state[12]
				if control_changed and _block_if_locked(rel_path, "viewport/layout transform"):
					new_cache[rel_path] = old_state
					_queue_locked_transform_restore(rel_path, old_state.duplicate())
					continue
				if cur_state[0] != old_state[0] or cur_state[1] != old_state[1] \
						or cur_state[2] != old_state[2] or cur_state[3] != old_state[3]:
					_emit_property(rel_path, "anchor_left", ctrl.anchor_left)
					_emit_property(rel_path, "anchor_right", ctrl.anchor_right)
					_emit_property(rel_path, "anchor_top", ctrl.anchor_top)
					_emit_property(rel_path, "anchor_bottom", ctrl.anchor_bottom)
				if cur_state[4] != old_state[4] or cur_state[5] != old_state[5] \
						or cur_state[6] != old_state[6] or cur_state[7] != old_state[7]:
					_emit_property(rel_path, "offset_left", ctrl.offset_left)
					_emit_property(rel_path, "offset_right", ctrl.offset_right)
					_emit_property(rel_path, "offset_top", ctrl.offset_top)
					_emit_property(rel_path, "offset_bottom", ctrl.offset_bottom)
				if cur_state[8] != old_state[8]:
					_emit_property(rel_path, "rotation", ctrl.rotation)
				if cur_state[9] != old_state[9] or cur_state[10] != old_state[10]:
					_emit_property(rel_path, "scale", ctrl.scale)
				if cur_state[11] != old_state[11] or cur_state[12] != old_state[12]:
					_emit_property(rel_path, "pivot_offset", ctrl.pivot_offset)

		# ── Poll child order (scene-tree position among siblings) ──────
		# Skip the root — it has no siblings that can be reordered.
		if node != root:
			current_idx = node.get_index()
			if _child_order_cache.has(rel_path):
				var old_idx: int = _child_order_cache[rel_path]
				if current_idx != old_idx:
					var locked_reorder_path := _get_locked_path(rel_path)
					if locked_reorder_path.is_empty():
						locked_reorder_path = _get_locked_path(parent_rel)
					if not locked_reorder_path.is_empty():
						_notify_lock_blocked(locked_reorder_path, "reorder/context action")
						_restore_node_parent(root, node, parent_rel, old_idx)
						_child_order_cache[rel_path] = old_idx
						new_parent_cache[iid] = {
							"parent_path": parent_rel,
							"child_index": old_idx,
							"rel_path": rel_path,
						}
						continue
					_emit({
						"type": "node_reorder",
						"peer_id": _peer_id,
						"timestamp": Time.get_unix_time_from_system(),
						"node_path": rel_path,
						"data": { "child_index": current_idx },
					})
					print("[%s] REORDER: %s moved to idx=%d (was %d)" % [TAG, rel_path, current_idx, old_idx])
			_child_order_cache[rel_path] = current_idx

	_transform_cache = new_cache
	_name_cache = new_name_cache
	_parent_cache = new_parent_cache
	# Prune _child_order_cache entries for nodes that no longer exist.
	var live_paths: Dictionary = {}
	for _n in nodes:
		if _n != root:
			live_paths[_clean_path(str(root.get_path_to(_n)))] = true
		else:
			live_paths["."] = true
	for _p in _child_order_cache.keys().duplicate():
		if not live_paths.has(_p):
			_child_order_cache.erase(_p)
	for _p in _group_cache.keys().duplicate():
		if not live_paths.has(_p):
			_group_cache.erase(_p)
	for _p in _signal_connection_cache.keys().duplicate():
		if not live_paths.has(_p):
			_signal_connection_cache.erase(_p)
	# NOTE: _remote_changed_paths is cleared at the end of _poll_resource_properties
	# so it remains valid for the resource/name pollers running in the same tick.


## Poll non-transform, non-script properties (texture, sprite_frames, visible,
## modulate, text, color, value) that the inspector hook can miss when changed
## via drag-drop in the viewport or through other non-inspector pathways.
func _poll_resource_properties() -> void:
	if _scene_sync_ticks_remaining > 0: return  # waiting for remote authoritative state
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return
	for node in _get_all_scene_nodes(root):
		var rel_path := _clean_path(str(root.get_path_to(node)))

		# This same list seeds lock snapshots in _seed_node_lock_state.
		var extra_props := _get_polled_resource_props(node)
		for prop in extra_props:
			var suppress_key := rel_path + "::" + prop
			var current_val: Variant = node.get(prop)

			# Compute a comparable cache token.
			# For saved resources use their path (stable string).
			# For inline (unsaved) resources use a content string so that
			# in-place edits (e.g. changing SphereMesh.radius) are detected
			# even when the object instance does not change.
			var token: Variant = _property_cache_token(current_val)

			var cache_key := rel_path + "::" + prop
			var was_cached := _resource_prop_cache.has(cache_key)
			var cached_token: Variant = _resource_prop_cache.get(cache_key)
			var cached_value: Variant = _resource_prop_value_cache.get(cache_key, null)

			# Not yet observed — seed silently, except resources that commonly
			# appear through editor drag/drop without an inspector hook.
			if not was_cached:
				_resource_prop_cache[cache_key] = token
				_resource_prop_value_cache[cache_key] = _snapshot_property_value(current_val)
				var animation_library_added := node is AnimationPlayer \
					and prop.begins_with("libraries/") \
					and not _remote_changed_paths.has(suppress_key)
				var stream_dropped := prop == "stream" \
					and current_val != null \
					and not _remote_changed_paths.has(suppress_key)
				var material_added := prop in _get_material_resource_props(node) \
					and current_val != null \
					and not _remote_changed_paths.has(suppress_key)
				var sprite_frames_added := prop == "sprite_frames" \
					and current_val != null \
					and not _remote_changed_paths.has(suppress_key)
				var autoplay_observed := prop == "autoplay" \
					and (node is AnimatedSprite2D or node is AnimatedSprite3D \
						or node is AnimationPlayer) \
					and not _remote_changed_paths.has(suppress_key)
				if animation_library_added or stream_dropped or material_added \
						or sprite_frames_added or autoplay_observed:
					var initial_encoded := ActionSerializerClass.encode_property_value(current_val)
					if bool(initial_encoded.get("ok", false)):
						_emit_property(rel_path, prop, initial_encoded.get("value"))
						print("[%s] POLL: %s.%s added" % [TAG, rel_path, prop])
				continue

			# Remote-change echo guard: the property was just set from a remote
			# packet; don't broadcast it back. Cache it as the new baseline.
			if _remote_changed_paths.has(suppress_key):
				_resource_prop_cache[cache_key] = token
				_resource_prop_value_cache[cache_key] = _snapshot_property_value(current_val)
				continue

			# Guard against GDScript type-mismatch error (e.g. String vs Object)
			# that arises when a property transitions between a cached raw-Object
			# value and a Resource token string (or vice versa after node_rename).
			if typeof(token) == typeof(cached_token) and token == cached_token:
				continue

			if _block_if_locked(rel_path, "property %s" % prop):
				_restore_node_property(node, prop, cached_value)
				_resource_prop_cache[cache_key] = cached_token
				_resource_prop_value_cache[cache_key] = cached_value
				continue

			# Value changed — encode and emit
			var encoded := ActionSerializerClass.encode_property_value(current_val)
			if not bool(encoded.get("ok", false)):
				continue
			_resource_prop_cache[cache_key] = token
			_resource_prop_value_cache[cache_key] = _snapshot_property_value(current_val)
			var action := {
				"type": "property",
				"peer_id": _peer_id,
				"timestamp": Time.get_unix_time_from_system(),
				"node_path": rel_path,
				"data": {
					"property": prop,
					"value": encoded.get("value"),
				},
			}
			_emit(action)
			print("[%s] POLL: %s.%s changed" % [TAG, rel_path, prop])
	# Clear remote-change suppression — all pollers have now run for this tick.
	_remote_changed_paths.clear()


func _emit_property(rel_path: String, prop: String, value: Variant) -> bool:
	if _block_if_locked(rel_path, "property %s" % prop):
		return false
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
	return true


# ═════════════════════════════════════════════════════════════════════
#  Scene Guide Polling
# ═════════════════════════════════════════════════════════════════════

func _poll_scene_guides() -> void:
	if _suppress: return
	if _scene_sync_ticks_remaining > 0: return
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return

	var current_guides := _get_scene_guides(root)
	if _scene_guides_cache.is_empty():
		_scene_guides_cache = current_guides.duplicate(true)
		return

	if _remote_scene_guides_changed:
		_scene_guides_cache = current_guides.duplicate(true)
		_remote_scene_guides_changed = false
		return

	if _guides_equal(_scene_guides_cache, current_guides):
		return

	_scene_guides_cache = current_guides.duplicate(true)
	_emit({
		"type": "scene_guides",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": ".",
		"data": current_guides,
	})
	print("[%s] GUIDES: vertical=%d horizontal=%d" % [
		TAG,
		current_guides.get("vertical", []).size(),
		current_guides.get("horizontal", []).size(),
	])


func _get_scene_guides(root: Node) -> Dictionary:
	return _normalize_scene_guides({
		"vertical": root.get_meta(META_VERTICAL_GUIDES, []),
		"horizontal": root.get_meta(META_HORIZONTAL_GUIDES, []),
	})


func _set_scene_guides(root: Node, guides: Dictionary) -> void:
	var normalized := _normalize_scene_guides(guides)
	root.set_meta(META_VERTICAL_GUIDES, normalized.get("vertical", []))
	root.set_meta(META_HORIZONTAL_GUIDES, normalized.get("horizontal", []))
	root.notify_property_list_changed()


static func _normalize_scene_guides(guides: Dictionary) -> Dictionary:
	return {
		"vertical": _normalize_guides_array(guides.get("vertical", [])),
		"horizontal": _normalize_guides_array(guides.get("horizontal", [])),
	}


static func _normalize_guides_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for item in value:
			if typeof(item) == TYPE_INT or typeof(item) == TYPE_FLOAT:
				result.append(float(item))
	return result


static func _guides_equal(a: Dictionary, b: Dictionary) -> bool:
	var vertical_a: Array = _normalize_guides_array(a.get("vertical", []))
	var vertical_b: Array = _normalize_guides_array(b.get("vertical", []))
	var horizontal_a: Array = _normalize_guides_array(a.get("horizontal", []))
	var horizontal_b: Array = _normalize_guides_array(b.get("horizontal", []))
	return _guide_arrays_equal(vertical_a, vertical_b) \
		and _guide_arrays_equal(horizontal_a, horizontal_b)


static func _guide_arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not is_equal_approx(float(a[i]), float(b[i])):
			return false
	return true


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


# ═════════════════════════════════════════════════════════════════════
#  Xogot Generic Fallback (inspector-hook / signal independent)
# ═════════════════════════════════════════════════════════════════════

## Force the Xogot fallback on or off at runtime (e.g. from the dock for
## testing on desktop). Clears caches when disabling so it re-seeds cleanly
## if turned back on.
func set_xogot_fallback(enabled: bool) -> void:
	if _xogot_fallback == enabled:
		return
	_xogot_fallback = enabled
	if not enabled:
		_generic_prop_cache.clear()
		_generic_prop_value_cache.clear()
		_presence_cache.clear()
		_presence_seeded = false
		_presence_root_id = 0
	print("[%s] Xogot fallback %s" % [TAG, "ON" if enabled else "OFF"])


func _detect_xogot() -> bool:
	# Explicit overrides win, so desktop can force-enable for testing and iOS
	# can opt out if ever needed.
	if OS.has_environment(XOGOT_FALLBACK_ENV):
		return OS.get_environment(XOGOT_FALLBACK_ENV) == "1"
	if ProjectSettings.has_setting(XOGOT_FALLBACK_SETTING):
		return bool(ProjectSettings.get_setting(XOGOT_FALLBACK_SETTING))
	if OS.has_feature("xogot"):
		return true
	if OS.get_executable_path().to_lower().contains("xogot"):
		return true
	# Xogot can run on iOS/iPadOS and macOS. The executable/feature checks above
	# identify its macOS build; stock Godot never runs as an iOS editor.
	return OS.get_name() == "iOS"


## Containers compare structurally (their reference identity is not a reliable
## change signal); primitives compare by value. Kept consistent between the
## poll diff and the _apply_property echo guard.
static func _generic_token(value: Variant) -> Variant:
	if value is Array or value is Dictionary:
		return var_to_str(value)
	return value


## Snapshot a property value so a later restore (for a locked node) does not
## share mutable state with the live Inspector value. Containers and inline
## resources are duplicated.
func _snapshot_property_value(value: Variant) -> Variant:
	if value is Resource:
		var resource := value as Resource
		var resource_path := String(resource.resource_path)
		if not resource_path.is_empty() and not ("::" in resource_path):
			return resource
		var duplicated := resource.duplicate(true)
		return duplicated if duplicated else value
	if value is Array:
		return (value as Array).duplicate(true)
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return value


## Fallback poll for Xogot. Detects node add/remove by presence (instance_id)
## and diffs every storage property the curated pollers don't already cover —
## the changes that flow through the native iOS inspector instead of the
## desktop EditorInspector hook. Connected to the same timer as the transform
## poll; a no-op unless _xogot_fallback is on.
func _poll_generic_fallback() -> void:
	if not _xogot_fallback: return
	if _suppress: return
	if _scene_sync_ticks_remaining > 0: return     # remote is source of truth
	# Mid-hot-reload guard (instance vars can be transiently nil while the
	# script recompiles), mirroring _poll_transforms.
	if not _generic_prop_cache is Dictionary: return

	_generic_poll_tick += 1
	if _generic_poll_tick % GENERIC_POLL_EVERY_N_TICKS != 0:
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_generic_prop_cache.clear()
		_generic_prop_value_cache.clear()
		_presence_cache.clear()
		_presence_seeded = false
		_presence_root_id = 0
		return

	# Reset caches when the edited scene changes — diffing across two different
	# scenes would emit a storm of bogus property/add/delete actions.
	var root_id := root.get_instance_id()
	if root_id != _presence_root_id:
		_presence_root_id = root_id
		_generic_prop_cache.clear()
		_generic_prop_value_cache.clear()
		_presence_cache.clear()
		_presence_seeded = false

	var nodes := _get_all_scene_nodes(root)
	var live: Dictionary = {}   ## instance_id → rel_path

	for node in nodes:
		var iid := node.get_instance_id()
		var rel_path := _clean_path(str(root.get_path_to(node)))
		live[iid] = rel_path

		# Node present that we never recorded → it was added without a
		# SceneTree.node_added signal (Xogot native add). Route it through the
		# normal handler so lock checks, instance-internal handling, cache
		# seeding and emission behave exactly like a desktop add. (Only after
		# the first seeded pass, so scene-open doesn't emit a wave of adds.)
		if _presence_seeded and node != root and not _presence_cache.has(iid):
			_on_node_added(node)
		# A known node whose path changed was renamed (or reparented) in the
		# native UI, where SceneTree.node_renamed never fires. Without this the
		# peer keeps the stale node name and drops every later property update
		# aimed at the new name (the "Dropped pending property" symptom).
		elif _presence_seeded and node != root and String(_presence_cache.get(iid, "")) != rel_path:
			_detect_xogot_rename(node, String(_presence_cache[iid]), rel_path)

		_diff_generic_node_properties(node, rel_path)

	# Nodes we knew about that are gone now → deleted without a node_removed
	# signal (Xogot native delete).
	if _presence_seeded:
		for old_iid in _presence_cache:
			if not live.has(old_iid):
				_emit_node_delete_fallback(String(_presence_cache[old_iid]))

	_presence_cache = live
	_presence_seeded = true


## Diff the storage properties of one node that aren't already synced by a
## dedicated mechanism, emitting a `property` action for each genuine change.
func _diff_generic_node_properties(node: Node, rel_path: String) -> void:
	# Properties handled elsewhere for THIS node (curated sync + resource poll).
	var handled: Dictionary = {}
	for p in _get_sync_properties(node):
		handled[p] = true
	for p in _get_polled_resource_props(node):
		handled[p] = true

	for prop_info in node.get_property_list():
		var usage := int(prop_info.get("usage", 0))
		if usage & PROPERTY_USAGE_STORAGE == 0: continue
		if usage & PROPERTY_USAGE_EDITOR == 0: continue
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP) != 0:
			continue

		var pname := String(prop_info.get("name", ""))
		if pname.is_empty(): continue
		if GENERIC_ALWAYS_SKIP.has(pname): continue
		if handled.has(pname): continue

		var current: Variant = node.get(pname)
		# Resources are handled by the curated resource poll; raw Objects and
		# large byte blobs are not portably serialisable through this path.
		if current is Object: continue
		if current is PackedByteArray: continue

		var key := rel_path + "::" + pname
		var token: Variant = _generic_token(current)
		var was_cached := _generic_prop_cache.has(key)
		var cached_token: Variant = _generic_prop_cache.get(key)

		if not was_cached:
			_generic_prop_cache[key] = token
			_generic_prop_value_cache[key] = _snapshot_property_value(current)
			continue
		if _remote_changed_paths.has(key):
			_generic_prop_cache[key] = token
			_generic_prop_value_cache[key] = _snapshot_property_value(current)
			continue
		if typeof(token) == typeof(cached_token) and token == cached_token: continue
		if _block_if_locked(rel_path, "inspector property (xogot)"):
			if _generic_prop_value_cache.has(key):
				call_deferred(
					"_restore_locked_node_property",
					rel_path,
					pname,
					_generic_prop_value_cache[key]
				)
			continue

		var encoded := ActionSerializerClass.encode_property_value(current)
		if not bool(encoded.get("ok", false)): continue
		_generic_prop_cache[key] = token
		_generic_prop_value_cache[key] = _snapshot_property_value(current)
		_emit_property(rel_path, pname, encoded.get("value"))
		print("[%s] XOGOT POLL: %s.%s changed" % [TAG, rel_path, pname])


## Emit a node_delete for a node the presence poll found missing. Mirrors the
## lock semantics of _on_node_removed (we can't revert here — the node is
## already gone — so a locked node's deletion simply isn't propagated).
func _emit_node_delete_fallback(rel_path: String) -> void:
	if rel_path.is_empty() or rel_path == ".":
		return
	var locked_path := _get_locked_path(rel_path)
	if not locked_path.is_empty():
		_notify_lock_blocked(locked_path, "delete (xogot)")
		return
	_emit({
		"type": "node_delete",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": rel_path,
		"data": { "node_name": rel_path.get_file() },
	})
	print("[%s] XOGOT POLL: node deleted %s" % [TAG, rel_path])


## Xogot has no reliable SceneTree.node_renamed signal, so the generic poll
## detects a rename by comparing a known node's cached path against its current
## one. Emits a node_rename only for a *pure* rename (same parent, new leaf
## name) so the peer updates the node name instead of orphaning every later
## property update that targets the new name. A changed parent path (reparent,
## or an ancestor that was itself renamed) is left alone — the ancestor's own
## rename packet already moves the whole subtree on the peer.
func _detect_xogot_rename(node: Node, old_path: String, new_path: String) -> void:
	if _parent_path_from_rel_path(old_path) != _parent_path_from_rel_path(new_path):
		return
	var old_name := old_path.get_file()
	var new_name := new_path.get_file()
	if old_name.is_empty() or new_name.is_empty() or old_name == new_name:
		return

	var iid := node.get_instance_id()
	var prev_cache: Dictionary = _name_cache.get(iid, {})
	# Already reflected — a node_renamed signal did fire, or we applied this
	# rename from the network. Refresh the cache and don't re-emit.
	if _remote_changed_paths.has(old_path + "::name") \
			or String(prev_cache.get("name", "")) == new_name:
		_name_cache[iid] = {"name": new_name, "rel_path": new_path}
		return

	# A node locked by a remote peer must not be renamed locally → don't
	# propagate (mirrors the lock semantics of _on_node_removed/_emit_*_fallback).
	if _block_if_locked(old_path, "rename (xogot)"):
		_name_cache[iid] = {"name": new_name, "rel_path": new_path}
		return

	_name_cache[iid] = {"name": new_name, "rel_path": new_path}
	_emit({
		"type": "node_rename",
		"peer_id": _peer_id,
		"timestamp": Time.get_unix_time_from_system(),
		"node_path": old_path,
		"data": {"new_name": new_name},
	})
	print("[%s] XOGOT POLL: renamed %s → %s" % [TAG, old_path, new_name])
