@tool
class_name GodotWithUDock
extends Control

## Editor Dock panel — Host/Join local relay or connect via BitChat P2P.

signal host_requested(port: int)
signal join_requested(ip: String, port: int)
signal stop_requested()

const TAG := "GodotWithUDock"

var _status_label: Label
var _peer_list: ItemList
var _host_btn: Button
var _join_btn: Button
var _stop_btn: Button
var _port_input: SpinBox
var _ip_input: LineEdit
var _info_label: Label


func _init() -> void:
	name = "GodotWithU"


func _build_ui() -> void:
	var main := VBoxContainer.new()
	main.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.add_theme_constant_override("separation", 6)
	add_child(main)

	# Header
	var header := Label.new()
	header.text = "🌐 GodotWithU"
	header.add_theme_font_size_override("font_size", 16)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main.add_child(header)
	main.add_child(HSeparator.new())

	# Status
	_status_label = Label.new()
	_status_label.text = "Status: Offline"
	_status_label.add_theme_color_override("font_color", Color.GRAY)
	main.add_child(_status_label)

	# Port
	var ph := HBoxContainer.new()
	main.add_child(ph)
	var pl := Label.new()
	pl.text = "Port:"
	ph.add_child(pl)
	_port_input = SpinBox.new()
	_port_input.min_value = 1024
	_port_input.max_value = 65535
	_port_input.value = 7654
	_port_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(_port_input)

	# IP Address (for Join)
	var ih := HBoxContainer.new()
	main.add_child(ih)
	var il := Label.new()
	il.text = "IP:"
	ih.add_child(il)
	_ip_input = LineEdit.new()
	_ip_input.text = "127.0.0.1"
	_ip_input.placeholder_text = "Host IP address"
	_ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ih.add_child(_ip_input)

	# Buttons
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 4)
	main.add_child(bh)

	_host_btn = Button.new()
	_host_btn.text = "Host"
	_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_btn.pressed.connect(func(): host_requested.emit(int(_port_input.value)))
	bh.add_child(_host_btn)

	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_btn.pressed.connect(
		func(): join_requested.emit(
			_ip_input.text.strip_edges(), int(_port_input.value)
		)
	)
	bh.add_child(_join_btn)

	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(func(): stop_requested.emit())
	bh.add_child(_stop_btn)

	main.add_child(HSeparator.new())

	# Peers
	var peers_lbl := Label.new()
	peers_lbl.text = "Connected Peers:"
	main.add_child(peers_lbl)

	_peer_list = ItemList.new()
	_peer_list.custom_minimum_size = Vector2(0, 100)
	_peer_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_peer_list)

	main.add_child(HSeparator.new())

	_info_label = Label.new()
	_info_label.text = "v0.5.0"
	_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	_info_label.add_theme_font_size_override("font_size", 11)
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main.add_child(_info_label)


func _ready() -> void:
	_build_ui()


func set_connected(mode: String) -> void:
	_host_btn.disabled = true
	_join_btn.disabled = true
	_stop_btn.disabled = false
	_port_input.editable = false
	_ip_input.editable = false
	_status_label.text = "Status: %s" % mode
	_status_label.add_theme_color_override("font_color", Color.GREEN)


func set_disconnected() -> void:
	_host_btn.disabled = false
	_join_btn.disabled = false
	_stop_btn.disabled = true
	_port_input.editable = true
	_ip_input.editable = true
	_status_label.text = "Status: Offline"
	_status_label.add_theme_color_override("font_color", Color.GRAY)
	if _peer_list:
		_peer_list.clear()


func add_peer(peer_id: String) -> void:
	if _peer_list:
		_peer_list.add_item("👤 " + peer_id)


func remove_peer(peer_id: String) -> void:
	if not _peer_list: return
	for i in range(_peer_list.item_count - 1, -1, -1):
		if _peer_list.get_item_text(i) == "👤 " + peer_id:
			_peer_list.remove_item(i)


func update_info(text: String) -> void:
	if _info_label:
		_info_label.text = text
