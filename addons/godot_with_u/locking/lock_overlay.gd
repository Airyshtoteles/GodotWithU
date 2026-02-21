@tool
class_name LockOverlay
extends RefCounted
## Visual overlay that marks locked nodes in the SceneTree dock.
##
## Uses a periodic refresh driven by LockManager.locks_changed to
## add/remove a "🔒" suffix on locked node names and tint them to
## signal they are read-only to the local user.

const TAG := "LockOverlay"
const LOCK_SUFFIX := " 🔒"

var _lock_manager: RefCounted   ## LockManager
var _editor_plugin: EditorPlugin
var _decorated_nodes: Dictionary = {}   ## node_path → original_name


# ═════════════════════════════════════════════════════════════════════
#  Init / Teardown
# ═════════════════════════════════════════════════════════════════════

func init(plugin: EditorPlugin, lock_manager: RefCounted) -> void:
	_editor_plugin = plugin
	_lock_manager = lock_manager
	_lock_manager.locks_changed.connect(_on_locks_changed)
	print("[%s] Overlay active." % TAG)


func teardown() -> void:
	# Restore all decorated node names
	_clear_all_decorations()
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


func _decorate(root: Node, node_path: String) -> void:
	var target := root.get_node_or_null(NodePath(node_path))
	if not target: return
	if str(target.name).ends_with(LOCK_SUFFIX): return  # already decorated

	var original_name: String = target.name
	_decorated_nodes[node_path] = original_name
	# We modify the editor display name by appending a lock icon.
	# Note: this changes the actual node name temporarily — it will
	# be restored on unlock via _undecorate().
	target.name = original_name + LOCK_SUFFIX
	print("[%s] Decorated: %s (locked by %s)" % [
		TAG, node_path, _lock_manager.get_lock_owner(node_path)
	])


func _undecorate(root: Node, node_path: String) -> void:
	if not _decorated_nodes.has(node_path): return

	var original_name: String = _decorated_nodes[node_path]
	# The node might have been deleted or the path might have changed
	# because we renamed it — try finding by the decorated name.
	var target := root.get_node_or_null(NodePath(node_path))
	if not target:
		# Try with the lock suffix appended to the last component
		var decorated_path := node_path.get_base_dir().path_join(original_name + LOCK_SUFFIX)
		target = root.get_node_or_null(NodePath(decorated_path))

	if target and str(target.name).ends_with(LOCK_SUFFIX):
		target.name = original_name

	_decorated_nodes.erase(node_path)


func _clear_all_decorations() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root: return

	for path in _decorated_nodes.keys():
		_undecorate(root, path)
	_decorated_nodes.clear()
