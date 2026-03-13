@tool
class_name GhostCursorOverlay
extends Control
## Draws colored cursor indicators for connected peers, overlaid on
## the active CodeEdit. Each peer gets a unique color and a small
## label showing their abbreviated peer ID.

const TAG := "GhostCursorOverlay"
const CURSOR_WIDTH := 2
const LABEL_OFFSET := Vector2(4, -16)
const STALE_TIMEOUT_SEC := 10.0

## Peer color palette (8 distinct colors).
const PEER_COLORS: Array[Color] = [
	Color(0.2, 0.6, 1.0),     # Blue
	Color(1.0, 0.4, 0.3),     # Red
	Color(0.3, 0.8, 0.3),     # Green
	Color(1.0, 0.7, 0.2),     # Orange
	Color(0.7, 0.4, 1.0),     # Purple
	Color(0.2, 0.8, 0.8),     # Cyan
	Color(1.0, 0.5, 0.7),     # Pink
	Color(0.8, 0.8, 0.3),     # Yellow
]

## peer_id -> { "script_path": String, "line": int, "column": int,
##              "timestamp": float }
var _peer_cursors: Dictionary = {}
var _code_edit: CodeEdit = null
var _active_script_path: String = ""


func attach_to(code_edit: CodeEdit, script_path: String) -> void:
	if _code_edit and is_instance_valid(_code_edit):
		if _code_edit.draw.is_connected(_on_code_edit_redraw):
			_code_edit.draw.disconnect(_on_code_edit_redraw)
		_disconnect_scroll_bars()

	_code_edit = code_edit
	_active_script_path = script_path
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if _code_edit:
		_code_edit.draw.connect(_on_code_edit_redraw)
		_connect_scroll_bars()

	queue_redraw()


func detach() -> void:
	if _code_edit and is_instance_valid(_code_edit):
		if _code_edit.draw.is_connected(_on_code_edit_redraw):
			_code_edit.draw.disconnect(_on_code_edit_redraw)
		_disconnect_scroll_bars()
	_code_edit = null
	_active_script_path = ""
	queue_redraw()


func update_peer_cursor(peer_id: String, data: Dictionary) -> void:
	_peer_cursors[peer_id] = {
		"script_path": data.get("script_path", ""),
		"line": data.get("line", 0),
		"column": data.get("column", 0),
		"timestamp": Time.get_unix_time_from_system(),
	}
	queue_redraw()


func remove_peer(peer_id: String) -> void:
	_peer_cursors.erase(peer_id)
	queue_redraw()


func _get_peer_color(peer_id: String) -> Color:
	var hash_val := peer_id.hash()
	return PEER_COLORS[absi(hash_val) % PEER_COLORS.size()]


func _draw() -> void:
	if not _code_edit or not is_instance_valid(_code_edit):
		return

	var now := Time.get_unix_time_from_system()
	var to_remove: Array[String] = []
	var font: Font = _code_edit.get_theme_font("font", "CodeEdit")
	var font_size: int = _code_edit.get_theme_font_size("font_size", "CodeEdit")

	for peer_id in _peer_cursors:
		var cursor_data: Dictionary = _peer_cursors[peer_id]

		# Skip cursors from peers editing a different script
		if cursor_data.get("script_path", "") != _active_script_path:
			continue

		# Remove stale cursors
		if now - cursor_data.get("timestamp", 0.0) > STALE_TIMEOUT_SEC:
			to_remove.append(peer_id)
			continue

		var line: int = cursor_data.get("line", 0)
		var col: int = cursor_data.get("column", 0)

		# Clamp line/column to valid range for this CodeEdit
		var line_count: int = _code_edit.get_line_count()
		if line >= line_count:
			line = line_count - 1
		if line < 0:
			line = 0
		var line_length: int = _code_edit.get_line(line).length()
		if col > line_length:
			col = line_length

		# Use TextEdit's get_rect_at_line_column() to find pixel position
		var rect: Rect2 = _code_edit.get_rect_at_line_column(line, col)
		if rect.size == Vector2.ZERO:
			continue  # Off-screen or invalid

		var color := _get_peer_color(peer_id)

		# Draw cursor line
		var cursor_top := rect.position
		var cursor_bottom := Vector2(rect.position.x, rect.position.y + rect.size.y)
		draw_line(cursor_top, cursor_bottom, color, CURSOR_WIDTH)

		# Draw peer label (abbreviated ID)
		var label_pos := cursor_top + LABEL_OFFSET
		var short_id: String = peer_id.substr(peer_id.length() - 6) \
			if peer_id.length() > 6 else peer_id
		if font:
			draw_string(
				font, label_pos, short_id,
				HORIZONTAL_ALIGNMENT_LEFT, -1, mini(font_size, 10), color)

	for pid in to_remove:
		_peer_cursors.erase(pid)


func _on_code_edit_redraw() -> void:
	queue_redraw()


## Connect to CodeEdit's vertical and horizontal scroll bar signals
## so ghost cursors redraw at correct positions when the user scrolls.
func _connect_scroll_bars() -> void:
	if not _code_edit or not is_instance_valid(_code_edit):
		return
	var v_bar: VScrollBar = _code_edit.get_v_scroll_bar()
	if v_bar and not v_bar.value_changed.is_connected(_on_scroll_changed):
		v_bar.value_changed.connect(_on_scroll_changed)
	var h_bar: HScrollBar = _code_edit.get_h_scroll_bar()
	if h_bar and not h_bar.value_changed.is_connected(_on_scroll_changed):
		h_bar.value_changed.connect(_on_scroll_changed)


func _disconnect_scroll_bars() -> void:
	if not _code_edit or not is_instance_valid(_code_edit):
		return
	var v_bar: VScrollBar = _code_edit.get_v_scroll_bar()
	if v_bar and v_bar.value_changed.is_connected(_on_scroll_changed):
		v_bar.value_changed.disconnect(_on_scroll_changed)
	var h_bar: HScrollBar = _code_edit.get_h_scroll_bar()
	if h_bar and h_bar.value_changed.is_connected(_on_scroll_changed):
		h_bar.value_changed.disconnect(_on_scroll_changed)


func _on_scroll_changed(_value: float) -> void:
	queue_redraw()
