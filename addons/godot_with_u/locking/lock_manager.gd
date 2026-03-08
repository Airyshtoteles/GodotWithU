@tool
class_name LockManager
extends RefCounted
## Tracks which Nodes are locked by which remote peer.
##
## A "lock" is created when a remote peer selects a Node. While locked,
## the local user cannot modify that Node (the ActionInterceptor checks
## is_locked() before allowing property / delete actions).
##
## Locks are automatically released when:
## - The remote peer sends a new selection (old nodes are unlocked)
## - The remote peer disconnects
## - The lock times out after LOCK_TIMEOUT_SEC seconds without renewal

signal node_locked(node_path: String, peer_id: String)
signal node_unlocked(node_path: String, peer_id: String)
signal locks_changed()

const TAG := "LockManager"
const LOCK_TIMEOUT_SEC := 30.0

## peer_id → Array[String] of locked node paths
var _peer_locks: Dictionary = {}

## node_path → peer_id (reverse lookup for fast is_locked checks)
var _path_to_peer: Dictionary = {}

## peer_id → last activity timestamp (for timeout detection)
var _peer_last_seen: Dictionary = {}


# ═════════════════════════════════════════════════════════════════════
#  Public API
# ═════════════════════════════════════════════════════════════════════

## Check if a node path is locked by ANY remote peer.
func is_locked(node_path: String) -> bool:
	return _path_to_peer.has(node_path)


## Get which peer locked this node (empty string if not locked).
func get_lock_owner(node_path: String) -> String:
	return _path_to_peer.get(node_path, "")


## Update locks for a peer based on their latest selection.
## Old locks from this peer are released; new paths are locked.
func update_peer_selection(peer_id: String, selected_paths: Array) -> void:
	# Record activity for timeout tracking
	_peer_last_seen[peer_id] = Time.get_unix_time_from_system()

	# Release old locks for this peer
	_release_peer_locks(peer_id)

	# Acquire new locks
	var paths: Array[String] = []
	for p in selected_paths:
		var path_str := str(p)
		# Skip paths already locked by a different peer (first-come wins)
		if _path_to_peer.has(path_str) and _path_to_peer[path_str] != peer_id:
			print("[%s] Skipped lock '%s': already held by '%s'" % [
				TAG, path_str, _path_to_peer[path_str]])
			continue
		paths.append(path_str)
		_path_to_peer[path_str] = peer_id
		node_locked.emit(path_str, peer_id)

	if not paths.is_empty():
		_peer_locks[peer_id] = paths
		print("[%s] Peer '%s' locked: %s" % [TAG, peer_id, paths])

	locks_changed.emit()


## Release all locks held by a specific peer (e.g., on disconnect).
func release_all_for_peer(peer_id: String) -> void:
	_release_peer_locks(peer_id)
	_peer_last_seen.erase(peer_id)
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

	if not timed_out_peers.is_empty():
		locks_changed.emit()


## Get a list of all currently locked node paths.
func get_all_locked_paths() -> Array[String]:
	var result: Array[String] = []
	for path in _path_to_peer.keys():
		result.append(path)
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
