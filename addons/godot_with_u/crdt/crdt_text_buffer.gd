@tool
class_name CRDTTextBuffer
extends RefCounted
## A Logoot-style CRDT text buffer using fractional indexing.
##
## Every character is assigned a unique, mathematically sortable ID
## composed of (position: Array[int], site_id: String, clock: int).
## Concurrent inserts at the same location are resolved deterministically
## by comparing site_id, guaranteeing convergence without coordination.
##
## Operations:
##   local_insert(index, char) → CRDTOp   (for local edits)
##   local_delete(index)       → CRDTOp   (for local edits)
##   remote_insert(op)                      (from network)
##   remote_delete(op)                      (from network)
##   get_text() → String                    (reconstruct document)

const TAG := "CRDTTextBuffer"

## Boundary positions — all real characters live between these.
const POS_BEGIN := [0]
const POS_END   := [2147483647]   # INT32_MAX
const BASE      := 65536          # 16-bit allocation space per level

# ── Character atom: the unit stored in the buffer ────────────────────
# Each atom is a Dictionary:  { "pos": Array[int], "site": String, "clock": int, "char": String }

var _atoms: Array = []        ## Sorted list of character atoms
var _site_id: String = ""     ## This peer's unique identifier
var _clock: int = 0           ## Monotonically increasing logical clock

## O(1) existence check for atoms by (site, clock) pair.
## Key: "site:clock" → value: true.
## Used for duplicate detection on remote_insert and fast lookup on remote_delete.
var _atom_index: Dictionary = {}


# ═════════════════════════════════════════════════════════════════════
#  Initialization
# ═════════════════════════════════════════════════════════════════════

func init(site_id: String) -> void:
	_site_id = site_id
	_atoms.clear()
	_atom_index.clear()
	_clock = 0


# ═════════════════════════════════════════════════════════════════════
#  Local Operations → generate CRDT ops to broadcast
# ═════════════════════════════════════════════════════════════════════

## Insert a character at document index `idx`. Returns the CRDT op dict.
func local_insert(idx: int, ch: String) -> Dictionary:
	# Clamp index to valid range
	idx = clampi(idx, 0, _atoms.size())

	# Get bounding positions
	var pos_before: Array = POS_BEGIN if idx == 0 else _atoms[idx - 1]["pos"]
	var pos_after: Array = POS_END if idx >= _atoms.size() else _atoms[idx]["pos"]

	# Generate a unique position between the two bounds
	var new_pos := _alloc_position_between(pos_before, pos_after)
	_clock += 1

	var atom := {
		"pos": new_pos,
		"site": _site_id,
		"clock": _clock,
		"char": ch,
	}

	# Insert into sorted position and add to index
	_atoms.insert(idx, atom)
	_atom_index["%s:%d" % [_site_id, _clock]] = true

	return {
		"op": "insert",
		"pos": new_pos,
		"site": _site_id,
		"clock": _clock,
		"char": ch,
	}


## Delete the character at document index `idx`. Returns the CRDT op dict.
func local_delete(idx: int) -> Dictionary:
	if idx < 0 or idx >= _atoms.size():
		return {}

	var atom: Dictionary = _atoms[idx]
	_atom_index.erase("%s:%d" % [atom["site"], atom["clock"]])
	_atoms.remove_at(idx)

	return {
		"op": "delete",
		"pos": atom["pos"],
		"site": atom["site"],
		"clock": atom["clock"],
	}


# ═════════════════════════════════════════════════════════════════════
#  Remote Operations → apply incoming ops from other peers
# ═════════════════════════════════════════════════════════════════════

## Apply a remote insert. Returns the document index where it was placed,
## or -1 if it was a duplicate (already exists).
func remote_insert(op: Dictionary) -> int:
	# Validate required fields
	if not op.has("pos") or not op.has("site") or not op.has("clock") or not op.has("char"):
		push_warning("[%s] Invalid remote insert op: missing fields" % TAG)
		return -1
	if not (op["pos"] is Array) or not (op["site"] is String) or not (op["char"] is String):
		push_warning("[%s] Invalid remote insert op: wrong field types" % TAG)
		return -1

	# Advance local clock to stay ahead of all observed clocks
	var remote_clock: int = op["clock"]
	if remote_clock >= _clock:
		_clock = remote_clock + 1

	# Check for duplicate via hash index
	var key := "%s:%d" % [op["site"], op["clock"]]
	if _atom_index.has(key):
		return -1   # duplicate, ignore

	var new_atom := {
		"pos": op["pos"],
		"site": op["site"],
		"clock": op["clock"],
		"char": op["char"],
	}

	# Find the correct sorted insertion point using binary search.
	var insert_idx := _find_insert_index(new_atom)

	_atoms.insert(insert_idx, new_atom)
	_atom_index[key] = true
	return insert_idx


## Apply a remote delete. Returns the document index that was removed,
## or -1 if the atom was not found (already deleted / out of sync).
func remote_delete(op: Dictionary) -> int:
	# Validate required fields
	if not op.has("site") or not op.has("clock"):
		push_warning("[%s] Invalid remote delete op: missing fields" % TAG)
		return -1

	# Advance local clock to stay ahead of all observed clocks
	var remote_clock: int = op.get("clock", 0)
	if remote_clock >= _clock:
		_clock = remote_clock + 1

	# O(1) existence check
	var key := "%s:%d" % [op["site"], op["clock"]]
	if not _atom_index.has(key):
		return -1

	_atom_index.erase(key)

	# Binary search for the atom's position in _atoms using its sort key
	var target_atom := {
		"pos": op.get("pos", []),
		"site": op["site"],
		"clock": op["clock"],
	}
	var idx := _find_insert_index(target_atom)

	# Verify we found the right atom (the one at idx or idx-1 should match)
	if idx < _atoms.size() and _atom_equals(_atoms[idx], target_atom):
		_atoms.remove_at(idx)
		return idx
	if idx > 0 and _atom_equals(_atoms[idx - 1], target_atom):
		_atoms.remove_at(idx - 1)
		return idx - 1

	# Fallback: linear scan (should rarely happen)
	for i in range(_atoms.size()):
		if _atom_equals(_atoms[i], target_atom):
			_atoms.remove_at(i)
			return i
	return -1


# ═════════════════════════════════════════════════════════════════════
#  Document Reconstruction
# ═════════════════════════════════════════════════════════════════════

func get_text() -> String:
	var result := PackedStringArray()
	for atom in _atoms:
		result.append(atom["char"])
	return "".join(result)


func get_length() -> int:
	return _atoms.size()


## Export the full buffer state for initial sync to a joining peer.
func export_state() -> Dictionary:
	return {
		"atoms": _atoms.duplicate(true),
		"clock": _clock,
	}


## Import a full buffer state received from the host during initial sync.
func import_state(state: Dictionary) -> void:
	_atoms = state.get("atoms", []).duplicate(true)
	var remote_clock: int = state.get("clock", 0)
	if remote_clock >= _clock:
		_clock = remote_clock + 1
	# Rebuild presence index
	_atom_index.clear()
	for atom in _atoms:
		_atom_index["%s:%d" % [atom["site"], atom["clock"]]] = true


# ═════════════════════════════════════════════════════════════════════
#  Fractional Position Allocation
# ═════════════════════════════════════════════════════════════════════

## Generate a position strictly between `before` and `after`.
## Uses boundary+ strategy: allocates near the lower bound with a small
## random offset, which works well for sequential left-to-right typing
## and leaves ample room for future insertions.
func _alloc_position_between(before: Array, after: Array) -> Array:
	var result: Array[int] = []
	var depth := 0
	var max_depth := maxi(before.size(), after.size()) + 2

	while depth <= max_depth:
		var b: int = before[depth] if depth < before.size() else 0
		var a: int = after[depth] if depth < after.size() else BASE

		var gap := a - b
		if gap > 1:
			# Boundary+ strategy: allocate near the lower bound
			var step := mini(gap - 1, 10)
			result.append(b + 1 + (randi() % step))
			return result

		# No room — descend one level deeper
		result.append(b)
		depth += 1

	# Fallback: extend with a value at the next level
	result.append(1 + (randi() % mini(BASE - 1, 10)))
	return result


# ═════════════════════════════════════════════════════════════════════
#  Sorting & Comparison
# ═════════════════════════════════════════════════════════════════════

## Find the correct sorted index for a new atom via binary search.
func _find_insert_index(new_atom: Dictionary) -> int:
	var lo := 0
	var hi := _atoms.size()

	while lo < hi:
		var mid := (lo + hi) / 2
		if _compare_atoms(_atoms[mid], new_atom) < 0:
			lo = mid + 1
		else:
			hi = mid
	return lo


## Compare two atoms by position, then by site_id as tiebreaker.
## Returns <0 if a comes before b, >0 if after, 0 if equal.
func _compare_atoms(a: Dictionary, b: Dictionary) -> int:
	var cmp := _compare_positions(a["pos"], b["pos"])
	if cmp != 0:
		return cmp
	# Tiebreak by site_id (lexicographic) — deterministic across all peers
	if a["site"] < b["site"]:
		return -1
	if a["site"] > b["site"]:
		return 1
	# Final tiebreak by clock
	return a["clock"] - b["clock"]


## Compare two position arrays lexicographically.
func _compare_positions(a: Array, b: Array) -> int:
	var len_a := a.size()
	var len_b := b.size()
	var min_len := mini(len_a, len_b)

	for i in range(min_len):
		if a[i] < b[i]:
			return -1
		if a[i] > b[i]:
			return 1

	# If all compared elements are equal, shorter array comes first
	if len_a < len_b:
		return -1
	if len_a > len_b:
		return 1
	return 0


func _atom_equals(a: Dictionary, b: Dictionary) -> bool:
	return a["site"] == b["site"] and a["clock"] == b["clock"]
