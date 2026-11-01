@tool
# No global class_name: loaded by path via _instantiate_addon_script; declaring a
# global class breaks the source-reload fallback on re-enable ("hides a global script class").
extends RefCounted
## Tracks which Nodes are locked by which remote peer.
##
## A "lock" is created when a remote peer selects a Node. While locked,
## the local user cannot modify that Node (the ActionInterceptor checks
## is_locked() before allowing inspector, transform, group, signal,
## context-menu and scene-tree actions).
##
## Locks are automatically released when:
## - The remote peer sends a new selection (old nodes are unlocked)
## - The remote peer disconnects
## - The lock times out after LOCK_TIMEOUT_SEC seconds without renewal

signal node_locked(node_path: String, peer_id: String)
signal node_unlocked(node_path: String, peer_id: String)
signal locks_changed()

const TAG := "LockManager"
const LOCK_TIMEOUT_SEC := 10.0

## peer_id → Array[String] of locked node paths
var _peer_locks: Dictionary = {}

## node_path → peer_id (reverse lookup for fast is_locked checks)
var _path_to_peer: Dictionary = {}

## peer_id → last activity timestamp (for timeout detection)
var _peer_last_seen: Dictionary = {}

## peer_id → human-readable pseudo received with selection packets
var _peer_display_names: Dictionary = {}


# ═════════════════════════════════════════════════════════════════════
#  Public API
# ═════════════════════════════════════════════════════════════════════

## Check if a node path is locked by ANY remote peer.
func is_locked(node_path: String) -> bool:
	return _path_to_peer.has(node_path)


## Get which peer locked this node (empty string if not locked).
func get_lock_owner(node_path: String) -> String:
	return _path_to_peer.get(node_path, "")


## Get the lock owner's pseudo, falling back to the technical peer ID.
func get_lock_owner_display_name(node_path: String) -> String:
	var peer_id := get_lock_owner(node_path)
	if peer_id.is_empty():
		return ""
	var peer_name := String(_peer_display_names.get(peer_id, "")).strip_edges()
	return peer_name if not peer_name.is_empty() else peer_id


## Update locks for a peer based on their latest selection.
## Old locks from this peer are released; new paths are locked.
func update_peer_selection(peer_id: String, selected_paths: Array,
		peer_name: String = "") -> void:
	# Record activity for timeout tracking
	_peer_last_seen[peer_id] = Time.get_unix_time_from_system()
	var clean_peer_name := peer_name.strip_edges()
	if not clean_peer_name.is_empty():
		_peer_display_names[peer_id] = clean_peer_name

	# Normalize and pre-filter the requested lease before touching existing
	# locks. An unchanged selection is the common heartbeat path: only refresh
	# the timestamp, without unlock/relock signals or overlay churn.
	var paths: Array[String] = []
	for p in selected_paths:
		var path_str := str(p)
		if path_str.is_empty() or paths.has(path_str):
			continue
		# Skip paths already locked by a different peer (first-come wins)
		if _path_to_peer.has(path_str) and _path_to_peer[path_str] != peer_id:
			print("[%s] Skipped lock '%s': already held by '%s'" % [
				TAG, path_str, _path_to_peer[path_str]])
			continue
		paths.append(path_str)

	var old_paths: Array = _peer_locks.get(peer_id, [])
	if _same_path_set(old_paths, paths):
		return

	# Selection genuinely changed: replace the old lease.
	_release_peer_locks(peer_id)

	# Acquire new locks.
	for path_str in paths:
		_path_to_peer[path_str] = peer_id
		node_locked.emit(path_str, peer_id)

	if not paths.is_empty():
		_peer_locks[peer_id] = paths
		print("[%s] Peer '%s' locked: %s" % [
			TAG,
			String(_peer_display_names.get(peer_id, peer_id)),
			paths,
		])

	locks_changed.emit()


func _same_path_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for path in a:
		if not b.has(str(path)):
			return false
	return true


## Release all locks held by a specific peer (e.g., on disconnect).
func release_all_for_peer(peer_id: String) -> void:
	_release_peer_locks(peer_id)
	_peer_last_seen.erase(peer_id)
	_peer_display_names.erase(peer_id)
	locks_changed.emit()


## Check for timed-out peer locks and release them.
## Should be called periodically (e.g., from the plugin's poll timer).
func check_timeouts() -> void:
	var now := Time.get_unix_time_from_system()
	var timed_out_peers: Array[String] = []

	for peer_id in _peer_last_seen:
		var last_seen: float = _peer_last_seen[peer_id]
		if now - last_seen > LOCK_TIMEOUT_SEC:
			timed_out_peers.append(peer_id)

	for peer_id in timed_out_peers:
		print(
			"[%s] Lock timeout for peer '%s' (no activity for %.0fs)"
			% [TAG, peer_id, LOCK_TIMEOUT_SEC]
		)
		_release_peer_locks(peer_id)
		_peer_last_seen.erase(peer_id)
		_peer_display_names.erase(peer_id)

	if not timed_out_peers.is_empty():
		locks_changed.emit()


## Get a list of all currently locked node paths.
func get_all_locked_paths() -> Array[String]:
	var result: Array[String] = []
	for path in _path_to_peer.keys():
		result.append(path)
	return result


## Get peer IDs that currently hold locks.
func get_locking_peers() -> Array[String]:
	var result: Array[String] = []
	for peer_id in _peer_locks.keys():
		result.append(str(peer_id))
	return result


# ═════════════════════════════════════════════════════════════════════
#  Internal
# ═════════════════════════════════════════════════════════════════════

func _release_peer_locks(peer_id: String) -> void:
	if not _peer_locks.has(peer_id):
		return

	var old_paths: Array = _peer_locks[peer_id]
	for path in old_paths:
		_path_to_peer.erase(path)
		node_unlocked.emit(path, peer_id)

	_peer_locks.erase(peer_id)
	print("[%s] Released locks for peer '%s'." % [TAG, peer_id])
