@tool
# No global class_name: loaded by path via _instantiate_addon_script; declaring a
# global class breaks the source-reload fallback on re-enable ("hides a global script class").
extends RefCounted
## Visual overlay that marks locked nodes in the SceneTree dock.
##
## Uses a periodic refresh driven by LockManager.locks_changed to
## add/remove a "🔒" suffix on locked node names and tint them to
## signal they are read-only to the local user.

const TAG := "LockOverlay"
const LOCK_SUFFIX := " 🔒"
## Xogot replaces the desktop SceneTree dock with a native SwiftUI hierarchy,
## so plugins cannot access a TreeItem to tint its background. Keep an explicit
## red marker in the actual node name as the native-tree fallback.
const XOGOT_LOCK_SUFFIX := " 🔴 LOCKED 🔒"
const LEGACY_XOGOT_LOCK_SUFFIX := " 🔴🔒"
const XOGOT_FALLBACK_SETTING := "godot_with_u/xogot_fallback"
const XOGOT_FALLBACK_ENV := "GODOT_WITH_U_XOGOT"
## Red warning background applied to locked nodes in the SceneTree dock.
const LOCK_TINT := Color(1.0, 0.12, 0.10, 0.34)
const LOCK_OVERLAY_TINT := Color(1.0, 0.08, 0.06, 0.28)


class LockHighlightOverlay:
	extends Control

	var source: RefCounted = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(true)

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if source and source.has_method("_draw_tree_lock_highlights"):
			source.call("_draw_tree_lock_highlights", self)

var _lock_manager: RefCounted   ## LockManager
var _editor_plugin: EditorPlugin
var _decorated_nodes: Dictionary = {}   ## node_path → original_name
var _scene_tree_widget: Tree = null    ## cached SceneTree dock Tree widget
var _highlight_overlay: Control = null
var _highlighted_paths: Array[String] = []
var _uses_native_xogot_tree: bool = false
var _active: bool = false


# ═════════════════════════════════════════════════════════════════════
#  Init / Teardown
# ═════════════════════════════════════════════════════════════════════

func init(plugin: EditorPlugin, lock_manager: RefCounted) -> void:
	_editor_plugin = plugin
	_lock_manager = lock_manager
	_uses_native_xogot_tree = _detect_xogot()
	_active = true
	_lock_manager.locks_changed.connect(_on_locks_changed)
	print("[%s] Overlay active%s." % [
		TAG,
		" (Xogot native-tree marker)" if _uses_native_xogot_tree else "",
	])


func teardown() -> void:
	_active = false
	# Restore all decorated node names
	_clear_all_decorations()
	_remove_highlight_overlay()
	if _lock_manager and _lock_manager.locks_changed.is_connected(_on_locks_changed):
		_lock_manager.locks_changed.disconnect(_on_locks_changed)
	print("[%s] Overlay removed." % TAG)


# ═════════════════════════════════════════════════════════════════════
#  Refresh
# ═════════════════════════════════════════════════════════════════════

func _on_locks_changed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_clear_all_decorations()
		return

	var locked_paths: Array = _lock_manager.get_all_locked_paths()
	_update_tree_backend(root)

	# Remove decorations from nodes that are no longer locked
	var to_remove: Array[String] = []
	for path in _decorated_nodes.keys():
		if path not in locked_paths:
			to_remove.append(path)

	for path in to_remove:
		_undecorate(root, path)

	# Add decorations to newly locked nodes
	for path in locked_paths:
		if path not in _decorated_nodes:
			_decorate(root, path)

	_refresh_tree_tints(locked_paths)
	call_deferred("_refresh_tree_tints_from_manager")


func _decorate(root: Node, node_path: String) -> void:
	var target := root.get_node_or_null(NodePath(node_path))
	if not target: return
	var current_name := str(target.name)
	if _has_lock_suffix(current_name):
		_decorated_nodes[node_path] = _strip_lock_suffix(current_name)
		_tint_tree_item(node_path, true)
		return

	var original_name: String = target.name
	_decorated_nodes[node_path] = original_name
	# We modify the editor display name by appending a lock icon.
	# Note: this changes the actual node name temporarily — it will
	# be restored on unlock via _undecorate().
	target.name = original_name + _active_lock_suffix()
	_tint_tree_item(node_path, true)
	var owner := String(_lock_manager.get_lock_owner(node_path))
	if _lock_manager.has_method("get_lock_owner_display_name"):
		owner = String(_lock_manager.get_lock_owner_display_name(node_path))
	print("[%s] Decorated: %s (locked by %s)" % [
		TAG, node_path, owner
	])


func _undecorate(root: Node, node_path: String) -> void:
	if not _decorated_nodes.has(node_path): return

	var original_name: String = _decorated_nodes[node_path]
	# The node might have been deleted or the path might have changed
	# because we renamed it — try finding by the decorated name.
	var target := root.get_node_or_null(NodePath(node_path))
	if not target:
		# Try every lock decoration supported by desktop and Xogot.
		for suffix in _lock_suffixes():
			var decorated_path := node_path.get_base_dir().path_join(original_name + suffix)
			target = root.get_node_or_null(NodePath(decorated_path))
			if target:
				break

	if target and _has_lock_suffix(str(target.name)):
		target.name = original_name

	_tint_tree_item(node_path, false)
	_decorated_nodes.erase(node_path)


func _clear_all_decorations() -> void:
	_highlighted_paths.clear()
	if _highlight_overlay and is_instance_valid(_highlight_overlay):
		_highlight_overlay.queue_redraw()

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		for path in _decorated_nodes.keys():
			_tint_tree_item(str(path), false)
		return

	for path in _decorated_nodes.keys():
		_undecorate(root, path)
	_decorated_nodes.clear()


# ═════════════════════════════════════════════════════════════════════
#  SceneTree dock tinting helpers
# ═════════════════════════════════════════════════════════════════════

## Apply or remove the red background tint on the TreeItem that corresponds
## to node_path in the SceneTree dock.
func _tint_tree_item(node_path: String, tint: bool) -> void:
	var tree := _get_scene_tree_widget()
	if not tree:
		return
	_ensure_highlight_overlay(tree)
	var root_item := tree.get_root()
	if not root_item:
		return
	var item := _find_tree_item_for_path(root_item, node_path)
	if not item:
		item = _find_tree_item_for_path(root_item, _decorated_path_for(node_path))
	if not item:
		return
	var column_count := tree.get_columns()
	if column_count < 1:
		column_count = 1
	for column in range(column_count):
		if tint:
			item.set_custom_bg_color(column, LOCK_TINT)
		else:
			item.clear_custom_bg_color(column)


func _refresh_tree_tints(locked_paths: Array) -> void:
	_highlighted_paths.clear()
	for path in locked_paths:
		_highlighted_paths.append(str(path))
	var tree := _get_scene_tree_widget()
	if tree:
		_ensure_highlight_overlay(tree)
	if _highlight_overlay and is_instance_valid(_highlight_overlay):
		_highlight_overlay.queue_redraw()
	for path in _highlighted_paths:
		_tint_tree_item(path, true)

	if _uses_native_xogot_tree and not locked_paths.is_empty():
		print("[%s] Xogot native tree uses 🔴 LOCKED 🔒 markers for: %s" % [
			TAG, locked_paths
		])


func _refresh_tree_tints_from_manager() -> void:
	if not _active or not _lock_manager:
		return
	var root := EditorInterface.get_edited_scene_root()
	if root:
		_update_tree_backend(root)
	_refresh_tree_tints(_lock_manager.get_all_locked_paths())


## Xogot on macOS reports the host OS as macOS, not iOS. Detect the actual
## editor backend as well: when the desktop SceneTreeEditor is absent, migrate
## existing lock decorations to the visible red native-tree marker.
func _update_tree_backend(root: Node) -> void:
	var use_native_marker := _detect_xogot()
	if not use_native_marker:
		use_native_marker = _get_scene_tree_widget() == null
	if use_native_marker == _uses_native_xogot_tree:
		return

	_uses_native_xogot_tree = use_native_marker
	if _uses_native_xogot_tree:
		_remove_highlight_overlay()

	for node_path in _decorated_nodes.keys():
		var original_name := String(_decorated_nodes[node_path])
		var target := _find_decorated_node(root, String(node_path), original_name)
		if target:
			target.name = original_name + _active_lock_suffix()

	print("[%s] Tree backend switched to %s." % [
		TAG,
		"Xogot native marker 🔴 LOCKED 🔒" if _uses_native_xogot_tree \
			else "desktop red overlay",
	])


func _find_decorated_node(root: Node, node_path: String,
		original_name: String) -> Node:
	var target := root.get_node_or_null(NodePath(node_path))
	if target:
		return target
	var base_dir := node_path.get_base_dir()
	for suffix in _lock_suffixes():
		var decorated_path := original_name + suffix
		if not base_dir.is_empty() and base_dir != ".":
			decorated_path = base_dir.path_join(decorated_path)
		target = root.get_node_or_null(NodePath(decorated_path))
		if target:
			return target
	return null


func _ensure_highlight_overlay(tree: Tree) -> void:
	if _highlight_overlay and is_instance_valid(_highlight_overlay):
		if _highlight_overlay.get_parent() == tree:
			_highlight_overlay.move_to_front()
			return
		_highlight_overlay.queue_free()

	var overlay := LockHighlightOverlay.new()
	overlay.name = "GodotWithULockHighlightOverlay"
	overlay.source = self
	_highlight_overlay = overlay
	tree.add_child(_highlight_overlay)
	_highlight_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_highlight_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_highlight_overlay.move_to_front()


func _remove_highlight_overlay() -> void:
	if _highlight_overlay and is_instance_valid(_highlight_overlay):
		_highlight_overlay.queue_free()
	_highlight_overlay = null


func _draw_tree_lock_highlights(overlay: Control) -> void:
	if not overlay or not is_instance_valid(overlay):
		return
	var tree := overlay.get_parent() as Tree
	if not tree:
		return
	var root_item := tree.get_root()
	if not root_item:
		return

	for path in _highlighted_paths:
		var item := _find_tree_item_for_path(root_item, path)
		if not item:
			item = _find_tree_item_for_path(root_item, _decorated_path_for(path))
		if not item:
			continue
		var rect := tree.get_item_area_rect(item, -1)
		if rect.size.y <= 0.0:
			rect = tree.get_item_area_rect(item, 0)
		if rect.size.y <= 0.0:
			continue
		rect.position.x = 0.0
		rect.size.x = overlay.size.x
		overlay.draw_rect(rect, LOCK_OVERLAY_TINT, true)


func _decorated_path_for(node_path: String) -> String:
	var clean_path := node_path.trim_prefix("/")
	if clean_path.is_empty() or clean_path == ".":
		return clean_path
	var base_dir := clean_path.get_base_dir()
	var name := clean_path.get_file()
	var decorated_name := name
	if not _has_lock_suffix(decorated_name):
		decorated_name += _active_lock_suffix()
	if base_dir.is_empty():
		return decorated_name
	return base_dir.path_join(decorated_name)


## Return (and cache) the Tree widget inside the SceneTreeEditor dock.
## Godot's SceneTreeEditor stores a NodePath as column-0 metadata on each TreeItem.
func _get_scene_tree_widget() -> Tree:
	if _scene_tree_widget and is_instance_valid(_scene_tree_widget):
		return _scene_tree_widget
	_scene_tree_widget = _find_scene_tree_in(EditorInterface.get_base_control())
	return _scene_tree_widget


## Recursively search for the Tree node that lives directly inside a
## SceneTreeEditor (Godot's internal scene-tree dock widget).
func _find_scene_tree_in(node: Node) -> Tree:
	if node is Tree:
		var tree := node as Tree
		if _is_scene_tree_widget(tree):
			return node as Tree
	for child in node.get_children():
		var result := _find_scene_tree_in(child)
		if result:
			return result
	return null


func _is_scene_tree_widget(tree: Tree) -> bool:
	# Only trust Godot's real desktop SceneTree dock. Xogot can expose other
	# Tree controls whose rows happen to contain node-like paths; accepting
	# those creates a false desktop classification and leaves only the plain
	# lock icon visible in its native hierarchy.
	var parent := tree.get_parent()
	while parent:
		var parent_class := parent.get_class()
		if parent_class == "SceneTreeEditor" or parent_class == "SceneTreeDock":
			return true
		parent = parent.get_parent()

	# Desktop-only heuristic fallback: identify the dock Tree by its content
	# when the parent-class walk fails (some docked/floating layouts). Skipped
	# under Xogot to avoid matching unrelated Tree controls in the native UI.
	if _uses_native_xogot_tree:
		return false
	var root_item := tree.get_root()
	if not root_item:
		return false
	for path in _highlighted_paths:
		if _find_tree_item_for_path(root_item, path):
			return true
		if _find_tree_item_for_path(root_item, _decorated_path_for(path)):
			return true
	for path in _decorated_nodes.keys():
		if _find_tree_item_for_path(root_item, str(path)):
			return true
		if _find_tree_item_for_path(root_item, _decorated_path_for(str(path))):
			return true
	return false


## Walk TreeItems depth-first and return the one whose NodePath metadata
## matches target_path (scene-relative, e.g. "Node2D/Sprite2D").
func _find_tree_item_for_path(item: TreeItem, target_path: String) -> TreeItem:
	return _find_tree_item_for_path_recursive(
		item,
		_normalize_tree_path(target_path),
		""
	)


func _find_tree_item_for_path_recursive(
		item: TreeItem,
		target_path: String,
		parent_path: String) -> TreeItem:
	if not item:
		return null
	var meta = item.get_metadata(0)
	if meta != null:
		var item_path := _normalize_tree_path(str(meta))
		if _tree_paths_match(item_path, target_path):
			return item

	var item_text := _strip_lock_suffix(str(item.get_text(0)))
	var display_path := item_text
	if not parent_path.is_empty() and not item_text.is_empty():
		display_path = parent_path.path_join(item_text)
	elif item_text.is_empty():
		display_path = parent_path
	display_path = _normalize_tree_path(display_path)
	if _tree_paths_match(display_path, target_path):
		return item

	var child := item.get_first_child()
	while child:
		var result := _find_tree_item_for_path_recursive(child, target_path, display_path)
		if result:
			return result
		child = child.get_next()
	return null


func _tree_paths_match(item_path: String, target_path: String) -> bool:
	if item_path.is_empty() or target_path.is_empty():
		return false
	return item_path == target_path or item_path.ends_with("/" + target_path)


func _normalize_tree_path(path: String) -> String:
	var normalized := str(path).strip_edges().trim_prefix("/")
	while normalized.ends_with("/") and normalized.length() > 1:
		normalized = normalized.trim_suffix("/")
	var parts := normalized.split("/")
	var cleaned: PackedStringArray = PackedStringArray()
	for part in parts:
		cleaned.append(_strip_lock_suffix(part))
	return "/".join(cleaned)


func _strip_lock_suffix(value: String) -> String:
	for suffix in _lock_suffixes():
		if value.ends_with(suffix):
			return value.substr(0, value.length() - suffix.length())
	return value


func _has_lock_suffix(value: String) -> bool:
	for suffix in _lock_suffixes():
		if value.ends_with(suffix):
			return true
	return false


func _active_lock_suffix() -> String:
	return XOGOT_LOCK_SUFFIX if _uses_native_xogot_tree else LOCK_SUFFIX


func _lock_suffixes() -> Array[String]:
	# Longest first so the Xogot marker is removed as one suffix.
	return [XOGOT_LOCK_SUFFIX, LEGACY_XOGOT_LOCK_SUFFIX, LOCK_SUFFIX]


func _detect_xogot() -> bool:
	if OS.has_environment(XOGOT_FALLBACK_ENV):
		return OS.get_environment(XOGOT_FALLBACK_ENV) == "1"
	if ProjectSettings.has_setting(XOGOT_FALLBACK_SETTING):
		return bool(ProjectSettings.get_setting(XOGOT_FALLBACK_SETTING))
	if OS.has_feature("xogot"):
		return true
	if OS.get_executable_path().to_lower().contains("xogot"):
		return true
	return OS.get_name() == "iOS"
