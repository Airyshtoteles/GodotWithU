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

const TAG := "ScriptInterceptor"
const CHECK_INTERVAL_SEC := 0.5

# ── References ───────────────────────────────────────────────────────
var _editor_plugin: EditorPlugin
var _site_id: String = "local"

# ── Active CodeEdit tracking ─────────────────────────────────────────
var _active_code_edit: CodeEdit = null
var _active_script_path: String = ""
var _cached_text: String = ""

# ── CRDT buffers: one per open script (keyed by res:// path) ────────
var _buffers: Dictionary = {}   ## script_path → CRDTTextBuffer

# ── Echo suppression ────────────────────────────────────────────────
var _suppress: bool = false

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
	_cached_text = code_edit.text

	# Ensure a CRDT buffer exists for this script
	if not _buffers.has(script_path):
		var buf := CRDTTextBuffer.new()
		buf.init(_site_id)
		# Bootstrap the buffer with the current document content
		for i in range(_cached_text.length()):
			buf.local_insert(i, _cached_text[i])
		_buffers[script_path] = buf

	code_edit.text_changed.connect(_on_text_changed)
	print("[%s] Hooked CodeEdit for: %s" % [TAG, script_path])


func _disconnect_code_edit() -> void:
	if _active_code_edit and is_instance_valid(_active_code_edit):
		if _active_code_edit.text_changed.is_connected(_on_text_changed):
			_active_code_edit.text_changed.disconnect(_on_text_changed)

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

	var buf: CRDTTextBuffer = _buffers.get(_active_script_path)
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
		var op := buf.local_delete(prefix_len + i)
		if not op.is_empty():
			crdt_op_generated.emit(op, _active_script_path)

	# Then inserts (left to right)
	for i in range(inserted_count):
		var ch: String = new_text[prefix_len + i]
		var op := buf.local_insert(prefix_len + i, ch)
		crdt_op_generated.emit(op, _active_script_path)

	_cached_text = new_text


# ═════════════════════════════════════════════════════════════════════
#  Remote CRDT Operations → Apply to CodeEdit
# ═════════════════════════════════════════════════════════════════════

## Apply an incoming remote CRDT operation to the local buffer and
## CodeEdit, preserving the local user's caret position.
func apply_remote_op(op: Dictionary, script_path: String) -> void:
	# Get or create buffer
	if not _buffers.has(script_path):
		var buf := CRDTTextBuffer.new()
		buf.init(_site_id)
		_buffers[script_path] = buf

	var buf: CRDTTextBuffer = _buffers[script_path]
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

	# ── Save caret state ─────────────────────────────────────────
	var caret_line := _active_code_edit.get_caret_line()
	var caret_col := _active_code_edit.get_caret_column()
	var caret_flat := _line_col_to_flat(_cached_text, caret_line, caret_col)

	# ── Apply to CodeEdit with echo suppression ──────────────────
	_suppress = true

	var op_type: String = op.get("op", "")
	if op_type == "insert":
		var pos := _flat_to_line_col(_cached_text, doc_index)
		_active_code_edit.insert_text_at_caret(op["char"])
		# Actually, we need to set the full text to be safe
		var new_full_text := buf.get_text()
		_active_code_edit.text = new_full_text
		_cached_text = new_full_text

		# Adjust caret: if insertion is before caret, shift right
		if doc_index <= caret_flat:
			caret_flat += 1

	elif op_type == "delete":
		var new_full_text := buf.get_text()
		_active_code_edit.text = new_full_text
		_cached_text = new_full_text

		# Adjust caret: if deletion is before caret, shift left
		if doc_index < caret_flat:
			caret_flat = maxi(0, caret_flat - 1)

	# ── Restore caret ────────────────────────────────────────────
	var restored := _flat_to_line_col(_cached_text, caret_flat)
	_active_code_edit.set_caret_line(restored[0])
	_active_code_edit.set_caret_column(restored[1])

	_suppress = false


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
