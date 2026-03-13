@tool
class_name ScriptInterceptor
extends RefCounted

## Hooks into Godot's ScriptEditor to intercept text changes in the
## active CodeEdit, feeds them through a CRDTTextBuffer, and applies
## incoming remote CRDT operations with caret preservation.
##
## Key challenges solved:
## 1. Finding the active CodeEdit by traversing ScriptEditor children
## 2. Diffing cached text vs current text (Godot's text_changed has no delta)
## 3. Preserving local caret position when applying remote changes
## 4. Echo suppression via _suppress flag

signal crdt_op_generated(op: Dictionary, script_path: String)
signal cursor_changed(data: Dictionary, script_path: String)
signal active_editor_changed(code_edit: CodeEdit, script_path: String)
signal buffer_created(script_path: String)

const CRDTTextBufferClass = preload("res://addons/godot_with_u/crdt/crdt_text_buffer.gd")
const TAG := "ScriptInterceptor"
const CHECK_INTERVAL_SEC := 0.5
const CURSOR_BROADCAST_INTERVAL_SEC := 0.1

# ── References ───────────────────────────────────────────────────────
var _editor_plugin: EditorPlugin
var _site_id: String = "local"

# ── Active CodeEdit tracking ─────────────────────────────────────────
var _active_code_edit: CodeEdit = null
var _active_script_path: String = ""
var _cached_text: String = ""

# ── Cursor broadcast throttling ──────────────────────────────────────
var _last_cursor_broadcast: float = 0.0

# ── CRDT buffers: one per open script (keyed by res:// path) ────────
var _buffers: Dictionary = {}   ## script_path → CRDTTextBuffer

# ── Echo suppression ────────────────────────────────────────────────
var _suppress: bool = false

# ── Sync pending: when true, local edits are NOT broadcast ─────────
# Set when joining as client, cleared when host's crdt_sync arrives.
# Prevents the client from sending ops with incompatible atoms before
# receiving the host's authoritative buffer state.
var _sync_pending: bool = false

# ── Polling timer for detecting active editor changes ───────────────
var _check_timer: Timer = null


# ═════════════════════════════════════════════════════════════════════
#  Initialization / Teardown
# ═════════════════════════════════════════════════════════════════════

func init(plugin: EditorPlugin, site_id: String) -> void:
	_editor_plugin = plugin
	_site_id = site_id

	# Poll for active CodeEdit changes (ScriptEditor doesn't expose
	# a reliable "tab changed" signal to plugins)
	_check_timer = Timer.new()
	_check_timer.wait_time = CHECK_INTERVAL_SEC
	_check_timer.one_shot = false
	_check_timer.autostart = true
	_check_timer.timeout.connect(_on_check_active_editor)
	plugin.add_child(_check_timer)

	print("[%s] Initialized (site_id=%s)." % [TAG, _site_id])


func teardown() -> void:
	_disconnect_code_edit()

	if _check_timer:
		_check_timer.stop()
		_check_timer.queue_free()
		_check_timer = null

	print("[%s] Torn down." % TAG)


## Export all CRDT buffer states for initial sync to a joining peer.
func export_all_buffers() -> Dictionary:
	var result: Dictionary = {}
	for script_path in _buffers:
		var buf: RefCounted = _buffers[script_path]
		result[script_path] = buf.export_state()
	return result


## Import CRDT buffer states received from the host during initial sync.
func import_buffer_state(script_path: String, state: Dictionary) -> void:
	var buf: RefCounted
	if _buffers.has(script_path):
		buf = _buffers[script_path]
	else:
		buf = CRDTTextBufferClass.new()
		buf.init(_site_id)
		_buffers[script_path] = buf
	buf.import_state(state)

	# If this script is currently active, update the CodeEdit
	if script_path == _active_script_path \
			and _active_code_edit \
			and is_instance_valid(_active_code_edit):
		_suppress = true
		var caret_line := _active_code_edit.get_caret_line()
		var caret_col := _active_code_edit.get_caret_column()
		_active_code_edit.text = buf.get_text()
		_cached_text = buf.get_text()
		_active_code_edit.set_caret_line(mini(caret_line, _active_code_edit.get_line_count() - 1))
		_active_code_edit.set_caret_column(caret_col)
		_suppress = false


## Initialize a CRDT buffer from raw script content (used when a
## script_attach action is received from a remote peer).
func initialize_buffer_from_content(script_path: String, content: String) -> void:
	if _buffers.has(script_path):
		print("[%s] Buffer already exists for %s — skipping content init" % [TAG, script_path])
		return
	var buf := CRDTTextBufferClass.new()
	buf.init(_site_id)
	for i in range(content.length()):
		buf.local_insert(i, content[i])
	_buffers[script_path] = buf
	print("[%s] Initialized CRDT buffer for: %s (%d chars)" % [TAG, script_path, content.length()])


## Remove the CRDT buffer for a script path (e.g., when script is detached).
func remove_buffer(script_path: String) -> void:
	if _buffers.has(script_path):
		_buffers.erase(script_path)
		print("[%s] Removed CRDT buffer for: %s" % [TAG, script_path])


## Check if a CRDT buffer exists for a script path.
func has_buffer(script_path: String) -> bool:
	return _buffers.has(script_path)


## Export the state of a single CRDT buffer by script path.
func export_buffer(script_path: String) -> Dictionary:
	if not _buffers.has(script_path):
		return {}
	return _buffers[script_path].export_state()


## Set/clear the sync_pending flag. While pending, local edits are
## silently consumed (not broadcast) and new buffer bootstrapping is
## deferred so the host's authoritative state can arrive first.
func set_sync_pending(pending: bool) -> void:
	_sync_pending = pending
	print("[%s] sync_pending = %s" % [TAG, pending])


## Remove ALL CRDT buffers. Called when joining so stale local buffers
## (bootstrapped before connecting) don't conflict with the host's state.
func clear_all_buffers() -> void:
	_buffers.clear()
	print("[%s] All CRDT buffers cleared." % TAG)


# ═════════════════════════════════════════════════════════════════════
#  Active CodeEdit Detection
# ═════════════════════════════════════════════════════════════════════

func _on_check_active_editor() -> void:
	var script_editor := EditorInterface.get_script_editor()
	if not script_editor:
		_disconnect_code_edit()
		return

	var current_editor := script_editor.get_current_editor()
	if not current_editor:
		_disconnect_code_edit()
		return

	# Get the CodeEdit from the current ScriptEditorBase
	var code_edit := _find_code_edit(current_editor)
	if not code_edit:
		_disconnect_code_edit()
		return

	# Get the script resource path
	var script_path := ""
	var current_script = script_editor.get_current_script()
	if current_script:
		script_path = current_script.resource_path

	# If same CodeEdit, nothing to do
	if code_edit == _active_code_edit and script_path == _active_script_path:
		return

	# Switch to new CodeEdit
	_disconnect_code_edit()
	_connect_code_edit(code_edit, script_path)


## Recursively search for the CodeEdit child inside a ScriptEditorBase.
func _find_code_edit(node: Node) -> CodeEdit:
	if node is CodeEdit:
		return node as CodeEdit

	for child in node.get_children():
		var found := _find_code_edit(child)
		if found:
			return found
	return null


func _connect_code_edit(code_edit: CodeEdit, script_path: String) -> void:
	_active_code_edit = code_edit
	_active_script_path = script_path

	if not _buffers.has(script_path):
		if _sync_pending:
			# Waiting for host's authoritative buffer — don't bootstrap
			# locally. Just cache the current text so we can diff later.
			_cached_text = code_edit.text
		else:
			# Bootstrap a new CRDT buffer from the CodeEdit content
			var buf := CRDTTextBufferClass.new()
			buf.init(_site_id)
			var text := code_edit.text
			for i in range(text.length()):
				buf.local_insert(i, text[i])
			_buffers[script_path] = buf
			_cached_text = text
			buffer_created.emit(script_path)
	else:
		# Buffer exists — may have accumulated remote ops while
		# this script was in the background. Sync CodeEdit to match.
		var buf: RefCounted = _buffers[script_path]
		var buf_text: String = buf.get_text()
		if code_edit.text != buf_text:
			_suppress = true
			var caret_line := code_edit.get_caret_line()
			var caret_col := code_edit.get_caret_column()
			code_edit.text = buf_text
			code_edit.set_caret_line(mini(caret_line, code_edit.get_line_count() - 1))
			code_edit.set_caret_column(caret_col)
			_suppress = false
		_cached_text = buf_text

	code_edit.text_changed.connect(_on_text_changed)
	code_edit.caret_changed.connect(_on_caret_changed)
	active_editor_changed.emit(code_edit, script_path)
	print("[%s] Hooked CodeEdit for: %s" % [TAG, script_path])


func _disconnect_code_edit() -> void:
	if _active_code_edit and is_instance_valid(_active_code_edit):
		if _active_code_edit.text_changed.is_connected(_on_text_changed):
			_active_code_edit.text_changed.disconnect(_on_text_changed)
		if _active_code_edit.caret_changed.is_connected(_on_caret_changed):
			_active_code_edit.caret_changed.disconnect(_on_caret_changed)

	_active_code_edit = null
	_active_script_path = ""
	_cached_text = ""


# ═════════════════════════════════════════════════════════════════════
#  Local Text Change → Diff → CRDT Ops
# ═════════════════════════════════════════════════════════════════════

func _on_text_changed() -> void:
	if _suppress: return
	if not _active_code_edit or not is_instance_valid(_active_code_edit): return

	var new_text: String = _active_code_edit.text
	var old_text: String = _cached_text

	if new_text == old_text:
		return

	# While waiting for the host's authoritative sync, accept the edit
	# locally but don't generate CRDT ops (they'd have wrong atoms).
	if _sync_pending:
		_cached_text = new_text
		return

	var buf: RefCounted = _buffers.get(_active_script_path)
	if not buf:
		_cached_text = new_text
		return

	# ── Fast diff: find the changed region ───────────────────────
	# Find common prefix
	var prefix_len := 0
	var min_len := mini(old_text.length(), new_text.length())
	while prefix_len < min_len and old_text[prefix_len] == new_text[prefix_len]:
		prefix_len += 1

	# Find common suffix (from the end, not overlapping with prefix)
	var suffix_len := 0
	var max_suffix := min_len - prefix_len
	while suffix_len < max_suffix and \
			old_text[old_text.length() - 1 - suffix_len] == \
			new_text[new_text.length() - 1 - suffix_len]:
		suffix_len += 1

	var deleted_count := old_text.length() - prefix_len - suffix_len
	var inserted_count := new_text.length() - prefix_len - suffix_len

	# ── Generate CRDT operations ─────────────────────────────────
	# Process deletes first (from right to left to keep indices stable)
	for i in range(deleted_count - 1, -1, -1):
		var op: Dictionary = buf.local_delete(prefix_len + i)
		if not op.is_empty():
			crdt_op_generated.emit(op, _active_script_path)

	# Then inserts (left to right)
	for i in range(inserted_count):
		var ch: String = new_text[prefix_len + i]
		var op: Dictionary = buf.local_insert(prefix_len + i, ch)
		crdt_op_generated.emit(op, _active_script_path)

	_cached_text = new_text


## Broadcast the local user's caret position to peers (throttled).
func _on_caret_changed() -> void:
	if _suppress:
		return
	if not _active_code_edit or not is_instance_valid(_active_code_edit):
		return

	var now := Time.get_unix_time_from_system()
	if now - _last_cursor_broadcast < CURSOR_BROADCAST_INTERVAL_SEC:
		return
	_last_cursor_broadcast = now

	cursor_changed.emit({
		"line": _active_code_edit.get_caret_line(),
		"column": _active_code_edit.get_caret_column(),
	}, _active_script_path)


# ═════════════════════════════════════════════════════════════════════
#  Remote CRDT Operations → Apply to CodeEdit
# ═════════════════════════════════════════════════════════════════════

## Apply an incoming remote CRDT operation to the local buffer and
## CodeEdit using surgical text operations (insert/remove) instead of
## full text replacement, preserving the local user's caret and selection.
func apply_remote_op(op: Dictionary, script_path: String) -> void:
	# Get or create buffer
	if not _buffers.has(script_path):
		var new_buf := CRDTTextBufferClass.new()
		new_buf.init(_site_id)
		_buffers[script_path] = new_buf

	var buf: RefCounted = _buffers[script_path]
	var doc_index: int = -1

	match op.get("op", ""):
		"insert":
			doc_index = buf.remote_insert(op)
		"delete":
			doc_index = buf.remote_delete(op)
		_:
			return

	if doc_index < 0:
		return   # duplicate or not found

	# Only update the CodeEdit if this script is currently active
	if script_path != _active_script_path:
		return
	if not _active_code_edit or not is_instance_valid(_active_code_edit):
		return

	_suppress = true
	_active_code_edit.begin_complex_operation()

	var op_type: String = op.get("op", "")
	if op_type == "insert":
		_apply_surgical_insert(doc_index, op.get("char", ""))
	elif op_type == "delete":
		_apply_surgical_delete(doc_index)

	_active_code_edit.end_complex_operation()

	# Verify CodeEdit stayed in sync with the CRDT buffer. If a surgical
	# operation placed a character at the wrong position (e.g. because
	# the buffers were bootstrapped independently with different atoms),
	# fall back to a full text replacement so the editor always converges.
	var expected_text: String = buf.get_text()
	if _cached_text != expected_text:
		_active_code_edit.text = expected_text
		_cached_text = expected_text

	_suppress = false


## Surgically insert a character at `doc_index` in the CodeEdit
## WITHOUT touching the local user's caret or selection. Uses
## set_line() / insert_line_at() so the edit happens in the
## background — no cursor jumping or viewport flickering.
func _apply_surgical_insert(doc_index: int, ch: String) -> void:
	# Calculate the (line, col) position for the insertion
	var pos := _flat_to_line_col(_cached_text, doc_index)
	var insert_line: int = pos[0]
	var insert_col: int = pos[1]

	# Bounds check: if the computed line is out of range, the CodeEdit
	# and _cached_text have desynced. Fall back to full text replacement
	# from the CRDT buffer (which already contains the inserted char).
	if insert_line >= _active_code_edit.get_line_count():
		var buf: RefCounted = _buffers.get(_active_script_path)
		if buf:
			_active_code_edit.text = buf.get_text()
			_cached_text = buf.get_text()
		return

	# Save local caret state (to adjust AFTER the background edit)
	var caret_line := _active_code_edit.get_caret_line()
	var caret_col := _active_code_edit.get_caret_column()

	# Save selection state
	var has_sel := _active_code_edit.has_selection()
	var sel_from_line := -1
	var sel_from_col := -1
	var sel_to_line := -1
	var sel_to_col := -1
	if has_sel:
		sel_from_line = _active_code_edit.get_selection_from_line()
		sel_from_col = _active_code_edit.get_selection_from_column()
		sel_to_line = _active_code_edit.get_selection_to_line()
		sel_to_col = _active_code_edit.get_selection_to_column()

	# Perform surgical insert via direct line manipulation — never
	# moves the caret, so the local user sees zero disruption.
	if ch == "\n":
		var line_text: String = _active_code_edit.get_line(insert_line)
		var before: String = line_text.substr(0, insert_col)
		var after: String = line_text.substr(insert_col)
		_active_code_edit.set_line(insert_line, before)
		_active_code_edit.insert_line_at(insert_line + 1, after)
	else:
		var line_text: String = _active_code_edit.get_line(insert_line)
		var new_line_text: String = line_text.substr(0, insert_col) + ch + line_text.substr(insert_col)
		_active_code_edit.set_line(insert_line, new_line_text)

	# Adjust caret position for the insertion (shift if insert was
	# before or on the same line as the caret)
	var adj_caret := _adjust_pos_for_insert(
		caret_line, caret_col, insert_line, insert_col, ch)
	_active_code_edit.set_caret_line(adj_caret[0])
	_active_code_edit.set_caret_column(adj_caret[1])

	# Adjust and restore selection
	if has_sel:
		var adj_from := _adjust_pos_for_insert(
			sel_from_line, sel_from_col, insert_line, insert_col, ch)
		var adj_to := _adjust_pos_for_insert(
			sel_to_line, sel_to_col, insert_line, insert_col, ch)
		_active_code_edit.select(adj_from[0], adj_from[1], adj_to[0], adj_to[1])

	_cached_text = _active_code_edit.text


## Surgically delete the character at `doc_index` in the CodeEdit,
## preserving the local user's caret and selection positions.
func _apply_surgical_delete(doc_index: int) -> void:
	if doc_index >= _cached_text.length():
		# Desync: fall back to full text replacement from CRDT buffer
		var buf: RefCounted = _buffers.get(_active_script_path)
		if buf:
			_active_code_edit.text = buf.get_text()
			_cached_text = buf.get_text()
		else:
			_cached_text = _active_code_edit.text
		return

	# Calculate position of the character to delete
	var pos := _flat_to_line_col(_cached_text, doc_index)
	var del_line: int = pos[0]
	var del_col: int = pos[1]

	# Bounds check: if the computed line is out of range, fall back
	# to full text replacement from the CRDT buffer.
	if del_line >= _active_code_edit.get_line_count():
		var buf: RefCounted = _buffers.get(_active_script_path)
		if buf:
			_active_code_edit.text = buf.get_text()
			_cached_text = buf.get_text()
		return

	# Determine end position (handles newline spanning two lines)
	var del_char: String = _cached_text[doc_index]
	var end_line := del_line
	var end_col := del_col + 1
	if del_char == "\n":
		end_line = del_line + 1
		end_col = 0

	# Save local caret state
	var caret_line := _active_code_edit.get_caret_line()
	var caret_col := _active_code_edit.get_caret_column()

	# Save selection state
	var has_sel := _active_code_edit.has_selection()
	var sel_from_line := -1
	var sel_from_col := -1
	var sel_to_line := -1
	var sel_to_col := -1
	if has_sel:
		sel_from_line = _active_code_edit.get_selection_from_line()
		sel_from_col = _active_code_edit.get_selection_from_column()
		sel_to_line = _active_code_edit.get_selection_to_line()
		sel_to_col = _active_code_edit.get_selection_to_column()

	# Perform surgical delete
	_active_code_edit.remove_text(del_line, del_col, end_line, end_col)

	# Adjust caret position for the deletion
	var adj_caret := _adjust_pos_for_delete(
		caret_line, caret_col, del_line, del_col, del_char)
	_active_code_edit.set_caret_line(adj_caret[0])
	_active_code_edit.set_caret_column(adj_caret[1])

	# Adjust and restore selection
	if has_sel:
		var adj_from := _adjust_pos_for_delete(
			sel_from_line, sel_from_col, del_line, del_col, del_char)
		var adj_to := _adjust_pos_for_delete(
			sel_to_line, sel_to_col, del_line, del_col, del_char)
		_active_code_edit.select(adj_from[0], adj_from[1], adj_to[0], adj_to[1])

	_cached_text = _active_code_edit.text


## Adjust a (line, col) position after a character insertion.
## Returns [adjusted_line, adjusted_col].
static func _adjust_pos_for_insert(
	line: int, col: int,
	ins_line: int, ins_col: int,
	ch: String,
) -> Array:
	if ch == "\n":
		if ins_line < line:
			return [line + 1, col]
		if ins_line == line and ins_col <= col:
			return [line + 1, col - ins_col]
	else:
		if ins_line == line and ins_col <= col:
			return [line, col + 1]
	return [line, col]


## Adjust a (line, col) position after a character deletion.
## Returns [adjusted_line, adjusted_col].
static func _adjust_pos_for_delete(
	line: int, col: int,
	del_line: int, del_col: int,
	del_char: String,
) -> Array:
	if del_char == "\n":
		if del_line < line:
			return [maxi(0, line - 1), col]
		if del_line == line and del_col == 0 and line > 0:
			# Edge case: newline at start of current line merges with previous
			return [maxi(0, line - 1), col]
	else:
		if del_line == line and del_col < col:
			return [line, maxi(0, col - 1)]
	return [line, col]


# ═════════════════════════════════════════════════════════════════════
#  Helpers: flat index ↔ (line, column) conversion
# ═════════════════════════════════════════════════════════════════════

## Convert (line, column) to a flat character offset in the full text.
func _line_col_to_flat(text: String, line: int, col: int) -> int:
	var flat := 0
	var current_line := 0
	for i in range(text.length()):
		if current_line == line:
			return flat + col
		if text[i] == "\n":
			current_line += 1
		flat += 1

	# If we're past the last newline, we're on the last line
	return flat + col


## Convert a flat character offset to [line, column].
func _flat_to_line_col(text: String, flat_pos: int) -> Array:
	flat_pos = clampi(flat_pos, 0, text.length())
	var line := 0
	var col := 0
	for i in range(flat_pos):
		if i < text.length() and text[i] == "\n":
			line += 1
			col = 0
		else:
			col += 1
	return [line, col]
