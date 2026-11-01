# gdlint:disable=max-public-methods,max-file-lines
@tool
# No global class_name: loaded by path via _instantiate_addon_script; declaring a
# global class breaks the source-reload fallback on re-enable ("hides a global script class").
extends Control

## Editor Dock panel for ENet and WebSocket relay transports.

signal host_requested(config: Dictionary)
signal join_requested(config: Dictionary)
signal stop_requested()
signal auth_requested(settings: Dictionary, password: String)
signal generate_token_requested(settings: Dictionary)
signal refresh_rooms_requested()
signal disconnect_requested()

const TAG := "GodotWithUDock"
const TRANSPORT_ENET := "enet"
const TRANSPORT_WEBSOCKET := "websocket"
const AUTH_MODE_API_TOKEN := "api_token"
const AUTH_MODE_PASSWORD := "password"
const DEFAULT_BACKEND_URL := "https://studio.godaas.org"
const DEFAULT_WS_URL := "wss://synchro.godaas.org/ws-relay"
## How a relay checks peers, as it announced it. A relay never heard from has no
## entry, and the dock then asks for nothing until the relay says otherwise.
const RELAY_AUTH_NONE := "none"
const RELAY_AUTH_PASSWORD := "password"
const RELAY_AUTH_BACKEND := "backend"
const TONE_SUCCESS := Color(0.45, 0.85, 0.55)
const TONE_ERROR := Color(1.0, 0.45, 0.45)
const TONE_INFO := Color(0.65, 0.75, 1.0)
const _SETTING_FILE_SYNC := "godot_with_u/sync_scene_files"
const _SETTING_GD_SYNC   := "godot_with_u/sync_gd_files"
const _SETTING_RELAY_AUTH_MODES := "godot_with_u/relay_auth_modes"

var _status_label: RichTextLabel
var _peer_list: ItemList
var _host_btn: Button
var _join_btn: Button
var _stop_btn: Button
var _peer_name_input: LineEdit
var _transport_select: OptionButton
var _transport_label: Label
var _address_label: Label
var _address_input: LineEdit
var _port_input: SpinBox
var _port_row: HBoxContainer
var _room_row: HBoxContainer
var _room_input: LineEdit
var _info_label: Label
var _file_sync_checkbox: CheckBox
var _gd_sync_checkbox: CheckBox
var _all_sync_checkbox: CheckBox
var _activity_ping_checkbox: CheckBox
var _room_select: OptionButton
var _refresh_rooms_btn: Button
var _hint_label: Label
var _projects_list: Array = []
var _relay_password_row: HBoxContainer
var _relay_password_input: LineEdit
## Relay URL → auth mode it announced. Persisted so the right field shows at once.
var _relay_auth_modes: Dictionary = {}

# ── Auth UI ──
var _auth_panel: VBoxContainer
var _auth_separator: HSeparator
var _auth_status_label: Label
var _disconnect_btn: Button
var _auth_backend_input: LineEdit
var _auth_mode_option: OptionButton
var _auth_token_input: LineEdit
var _auth_token_row: HBoxContainer
var _auth_identifier_input: LineEdit
var _auth_password_input: LineEdit
var _auth_project_name_input: LineEdit
var _auth_identifier_row: HBoxContainer
var _auth_password_row: HBoxContainer
var _auth_button: Button
var _auth_generate_button: Button
var _auth_authenticated := false
var _auto_filled := false
var _auto_filled_email := ""
var _auto_filled_room := ""
var _auto_filled_url := ""

var _enet_address: String = "127.0.0.1"
var _ws_url: String = DEFAULT_WS_URL
var _session_state := {
	"active": false,
	"mode": "",
	"transport": "",
	"room": "",
	"peer_id": "",
	"peer_name": "",
	"peer_count": 0,
}


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

	# Godot Manager login, shown only for a relay that asks for it
	_build_auth_panel(main)
	_auth_separator = HSeparator.new()
	main.add_child(_auth_separator)

	# Status
	var sync_title := Label.new()
	sync_title.text = "Synchronisation"
	sync_title.add_theme_font_size_override("font_size", 22)
	main.add_child(sync_title)
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.text = "[color=#ff7373]Status: Offline[/color]"
	main.add_child(_status_label)
	_hint_label = Label.new()
	_hint_label.text = "💡 Login first, then click Join."
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_color_override("font_color", Color(0.65, 0.75, 1.0))
	_hint_label.add_theme_font_size_override("font_size", 20)
	main.add_child(_hint_label)

	# Display name
	var nh := HBoxContainer.new()
	main.add_child(nh)
	var nl := Label.new()
	nl.text = "Pseudo:"
	nh.add_child(nl)
	_peer_name_input = LineEdit.new()
	_peer_name_input.placeholder_text = "How other peers will see you"
	_peer_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nh.add_child(_peer_name_input)

	# Transport
	var th := HBoxContainer.new()
	main.add_child(th)
	_transport_label = Label.new()
	_transport_label.text = "Transport:"
	th.add_child(_transport_label)
	_transport_select = OptionButton.new()
	_transport_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_transport_select.add_item("ENet (native)", 0)
	_transport_select.add_item("WebSocket relay", 1)
	_transport_select.item_selected.connect(_on_transport_selected)
	th.add_child(_transport_select)

	# Port
	_port_row = HBoxContainer.new()
	main.add_child(_port_row)
	var pl := Label.new()
	pl.text = "Port:"
	_port_row.add_child(pl)
	_port_input = SpinBox.new()
	_port_input.min_value = 1024
	_port_input.max_value = 65535
	_port_input.value = 7654
	_port_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_port_row.add_child(_port_input)

	# Address / URL
	var ah := HBoxContainer.new()
	main.add_child(ah)
	_address_label = Label.new()
	_address_label.text = "IP:"
	ah.add_child(_address_label)
	_address_input = LineEdit.new()
	_address_input.text = _enet_address
	_address_input.placeholder_text = "Host IP address"
	_address_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_input.text_changed.connect(_on_address_changed)
	ah.add_child(_address_input)

	# Relay password, shown only for a relay in "password" mode
	_relay_password_row = HBoxContainer.new()
	main.add_child(_relay_password_row)
	var rpl := Label.new()
	rpl.text = "Password:"
	_relay_password_row.add_child(rpl)
	_relay_password_input = LineEdit.new()
	_relay_password_input.placeholder_text = "Shared relay password"
	_relay_password_input.secret = true
	_relay_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_relay_password_row.add_child(_relay_password_input)

	# Room
	_room_row = HBoxContainer.new()
	main.add_child(_room_row)
	var rl := Label.new()
	rl.text = "Room:"
	_room_row.add_child(rl)
	_room_input = LineEdit.new()
	_room_input.placeholder_text = "Shared room name"
	_room_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_row.add_child(_room_input)
	_room_select = OptionButton.new()
	_room_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_select.visible = false
	_room_row.add_child(_room_select)
	_refresh_rooms_btn = Button.new()
	_refresh_rooms_btn.text = "⟳"
	_refresh_rooms_btn.tooltip_text = "Refresh project list from server"
	_refresh_rooms_btn.custom_minimum_size = Vector2(28, 0)
	_refresh_rooms_btn.visible = false
	_refresh_rooms_btn.pressed.connect(func(): refresh_rooms_requested.emit())
	_room_row.add_child(_refresh_rooms_btn)

	# Buttons
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 4)
	main.add_child(bh)

	# ENet only: on a relay the first peer in a room becomes its coordinator.
	_host_btn = Button.new()
	_host_btn.text = "Host"
	_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_btn.pressed.connect(func(): host_requested.emit(_build_connection_config()))
	bh.add_child(_host_btn)

	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_btn.pressed.connect(func(): join_requested.emit(_build_connection_config()))
	bh.add_child(_join_btn)

	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(func(): stop_requested.emit())
	bh.add_child(_stop_btn)

	main.add_child(HSeparator.new())

	# ── File sync options ─────────────────────────────────────
	var sync_lbl := Label.new()
	sync_lbl.text = "File Sync:"
	sync_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	sync_lbl.add_theme_font_size_override("font_size", 20)
	main.add_child(sync_lbl)

	_all_sync_checkbox = CheckBox.new()
	_all_sync_checkbox.text = "Sync all files"
	_all_sync_checkbox.tooltip_text = \
		"Auto-sync ALL file types (scenes, scripts, resources…) with all peers"
	_all_sync_checkbox.button_pressed = true
	main.add_child(_all_sync_checkbox)

	_file_sync_checkbox = CheckBox.new()
	_file_sync_checkbox.text = "Sync new scene files"
	_file_sync_checkbox.tooltip_text = \
		"Auto-sync .tscn/.tres file creates, deletes and renames with all peers"
	main.add_child(_file_sync_checkbox)

	_gd_sync_checkbox = CheckBox.new()
	_gd_sync_checkbox.text = "Sync new GDScript files"
	_gd_sync_checkbox.tooltip_text = "Auto-sync .gd file creates, deletes and renames with all peers"
	main.add_child(_gd_sync_checkbox)

	_activity_ping_checkbox = CheckBox.new()
	_activity_ping_checkbox.text = "Show as online in manager"
	_activity_ping_checkbox.tooltip_text = ("Periodically ping the backend so the Godaas "
		+ "manager shows you as online while a session is active")
	_activity_ping_checkbox.button_pressed = true
	main.add_child(_activity_ping_checkbox)

	main.add_child(HSeparator.new())

	# ── Connected peers ────────────────────────────────────────
	var peers_row := HBoxContainer.new()
	main.add_child(peers_row)
	var peers_lbl := Label.new()
	peers_lbl.text = "Connected Peers:"
	peers_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peers_row.add_child(peers_lbl)

	_peer_list = ItemList.new()
	_peer_list.custom_minimum_size = Vector2(0, 100)
	_peer_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_peer_list)

	main.add_child(HSeparator.new())

	_info_label = Label.new()
	_info_label.text = "v0.8.0"
	_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	_info_label.add_theme_font_size_override("font_size", 20)
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main.add_child(_info_label)


func _ready() -> void:
	_build_ui()
	_load_sync_settings()
	_load_relay_auth_modes()
	_all_sync_checkbox.toggled.connect(_on_sync_setting_changed.unbind(1))
	_file_sync_checkbox.toggled.connect(_on_sync_setting_changed.unbind(1))
	_gd_sync_checkbox.toggled.connect(_on_sync_setting_changed.unbind(1))
	_peer_name_input.text = _detect_default_peer_name()
	var default_room := str(
		ProjectSettings.get_setting("application/config/name", "default")).strip_edges()
	_room_input.text = default_room if not default_room.is_empty() else "default"
	# Default to WebSocket relay on all platforms (was: only on web).
	# _sync_transport_fields also shows what the selected relay asks for.
	_transport_select.select(1)
	_sync_transport_fields()


func _build_auth_panel(parent: VBoxContainer) -> void:
	_auth_panel = VBoxContainer.new()
	_auth_panel.add_theme_constant_override("separation", 4)
	parent.add_child(_auth_panel)

	var title := Label.new()
	title.text = "Authentication"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	title.add_theme_font_size_override("font_size", 22)
	_auth_panel.add_child(title)

	# Backend URL
	var url_row := HBoxContainer.new()
	_auth_panel.add_child(url_row)
	var url_label := Label.new()
	url_label.text = "Backend:"
	url_row.add_child(url_label)
	_auth_backend_input = LineEdit.new()
	_auth_backend_input.placeholder_text = DEFAULT_BACKEND_URL
	_auth_backend_input.text = DEFAULT_BACKEND_URL
	_auth_backend_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(_auth_backend_input)

	# Auth mode selector
	var mode_row := HBoxContainer.new()
	_auth_panel.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Mode:"
	mode_row.add_child(mode_label)
	_auth_mode_option = OptionButton.new()
	_auth_mode_option.add_item("API Token", 0)
	_auth_mode_option.add_item("Email + Password", 1)
	_auth_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_mode_option.item_selected.connect(func(_idx): _update_auth_mode_visibility())
	mode_row.add_child(_auth_mode_option)

	# API token
	_auth_token_row = HBoxContainer.new()
	_auth_panel.add_child(_auth_token_row)
	var token_label := Label.new()
	token_label.text = "Token:"
	_auth_token_row.add_child(token_label)
	_auth_token_input = LineEdit.new()
	_auth_token_input.placeholder_text = "gm_..."
	_auth_token_input.secret = true
	_auth_token_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_auth_token_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_token_row.add_child(_auth_token_input)

	# Identifier
	_auth_identifier_row = HBoxContainer.new()
	_auth_panel.add_child(_auth_identifier_row)
	var id_label := Label.new()
	id_label.text = "Email:"
	_auth_identifier_row.add_child(id_label)
	_auth_identifier_input = LineEdit.new()
	_auth_identifier_input.placeholder_text = "Email or username"
	_auth_identifier_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_identifier_row.add_child(_auth_identifier_input)

	# Password
	_auth_password_row = HBoxContainer.new()
	_auth_panel.add_child(_auth_password_row)
	var pw_label := Label.new()
	pw_label.text = "Pass:"
	_auth_password_row.add_child(pw_label)
	_auth_password_input = LineEdit.new()
	_auth_password_input.placeholder_text = "Password"
	_auth_password_input.secret = true
	_auth_password_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_auth_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_password_row.add_child(_auth_password_input)

	# Backend project name
	var project_name_row := HBoxContainer.new()
	_auth_panel.add_child(project_name_row)
	var project_name_label := Label.new()
	project_name_label.text = "Backend project name:"
	project_name_row.add_child(project_name_label)
	_auth_project_name_input = LineEdit.new()
	var default_backend_project_name := _get_default_backend_project_name()
	_auth_project_name_input.placeholder_text = default_backend_project_name
	_auth_project_name_input.text = default_backend_project_name
	_auth_project_name_input.tooltip_text = "Server project name used to resolve the backend project"
	_auth_project_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	project_name_row.add_child(_auth_project_name_input)

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	_auth_panel.add_child(btn_row)

	_auth_button = Button.new()
	_auth_button.text = "Authenticate"
	_auth_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_button.pressed.connect(_on_authenticate_pressed)
	btn_row.add_child(_auth_button)

	_auth_generate_button = Button.new()
	_auth_generate_button.text = "Generate Token"
	_auth_generate_button.tooltip_text = "Generate and save a new API token (requires being logged in)"
	_auth_generate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auth_generate_button.pressed.connect(_on_generate_pressed)
	btn_row.add_child(_auth_generate_button)

	# Status
	_auth_status_label = Label.new()
	_auth_status_label.text = "Not authenticated."
	_auth_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_auth_status_label.add_theme_color_override("font_color", TONE_INFO)
	_auth_status_label.add_theme_font_size_override("font_size", 11)
	_auth_panel.add_child(_auth_status_label)

	# Disconnect button (shown only when authenticated)
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Déconnecter"
	_disconnect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_disconnect_btn.visible = false
	_disconnect_btn.pressed.connect(func(): disconnect_requested.emit())
	_auth_panel.add_child(_disconnect_btn)

	_update_auth_mode_visibility()


func _update_auth_mode_visibility() -> void:
	var password_mode := _auth_mode_option != null and _auth_mode_option.selected == 1
	if _auth_token_row != null:
		_auth_token_row.visible = not password_mode
	if _auth_identifier_row != null:
		_auth_identifier_row.visible = password_mode
	if _auth_password_row != null:
		_auth_password_row.visible = password_mode



func _on_authenticate_pressed() -> void:
	auth_requested.emit(get_auth_settings(), _get_password())


func _on_generate_pressed() -> void:
	generate_token_requested.emit(get_auth_settings())


func _get_password() -> String:
	return String(_auth_password_input.text if _auth_password_input != null else "")


func _get_default_backend_project_name() -> String:
	return String(ProjectSettings.get_setting("application/config/name", "")).strip_edges()


func get_auth_settings() -> Dictionary:
	return {
		"backend_url": String(
			_auth_backend_input.text if _auth_backend_input != null else DEFAULT_BACKEND_URL
		).strip_edges(),
		"auth_mode": (
			AUTH_MODE_PASSWORD if (_auth_mode_option != null and _auth_mode_option.selected == 1)
			else AUTH_MODE_API_TOKEN
		),
		"identifier": String(
			_auth_identifier_input.text if _auth_identifier_input != null else ""
		).strip_edges(),
		"api_token": String(_auth_token_input.text if _auth_token_input != null else "").strip_edges(),
		"backend_project_name": String(
			_auth_project_name_input.text if _auth_project_name_input != null
			else _get_default_backend_project_name()
		).strip_edges(),
	}


func set_auth_settings(settings: Dictionary) -> void:
	if _auth_backend_input != null:
		_auth_backend_input.text = String(settings.get("backend_url", DEFAULT_BACKEND_URL))
	if _auth_mode_option != null:
		var mode := String(settings.get("auth_mode", AUTH_MODE_API_TOKEN)).to_lower()
		_auth_mode_option.select(1 if mode == AUTH_MODE_PASSWORD else 0)
	if _auth_identifier_input != null:
		_auth_identifier_input.text = String(settings.get("identifier", ""))
	if _auth_token_input != null:
		_auth_token_input.text = String(settings.get("api_token", ""))
	if _auth_project_name_input != null:
		var backend_project_name := String(settings.get("backend_project_name", "")).strip_edges()
		if backend_project_name.is_empty():
			backend_project_name = _get_default_backend_project_name()
		_auth_project_name_input.text = backend_project_name
	_update_auth_mode_visibility()


func set_auth_busy(busy: bool) -> void:
	if _auth_button != null:
		_auth_button.disabled = busy
		_auth_button.text = "Authenticating..." if busy else "Authenticate"
	if _auth_generate_button != null:
		_auth_generate_button.disabled = busy
	if _auth_backend_input != null:
		_auth_backend_input.editable = not busy
	if _auth_token_input != null:
		_auth_token_input.editable = not busy
	if _auth_identifier_input != null:
		_auth_identifier_input.editable = not busy
	if _auth_password_input != null:
		_auth_password_input.editable = not busy
	if _auth_project_name_input != null:
		_auth_project_name_input.editable = not busy
	if _auth_mode_option != null:
		_auth_mode_option.disabled = busy


func set_auth_status(message: String, status_type: String = "info") -> void:
	if _auth_status_label == null:
		return
	_auth_status_label.text = message.strip_edges()
	var tone := TONE_INFO
	match status_type:
		"success": tone = TONE_SUCCESS
		"error": tone = TONE_ERROR
	_auth_status_label.add_theme_color_override("font_color", tone)
	_auth_status_label.add_theme_font_size_override("font_size", 20)


func set_authenticated(authenticated: bool) -> void:
	_auth_authenticated = authenticated
	if authenticated:
		# Show disconnect button, hide auth form controls
		if _auth_panel != null:
			for child in _auth_panel.get_children():
				child.visible = child == _auth_status_label or child == _disconnect_btn
		if _disconnect_btn != null:
			_disconnect_btn.visible = true
	else:
		# Show full auth form, hide disconnect button
		if _auth_panel != null:
			for child in _auth_panel.get_children():
				child.visible = true
			_update_auth_mode_visibility()
		if _disconnect_btn != null:
			_disconnect_btn.visible = false
		clear_user_auth()
	_refresh_auth_ui()


## Auto-fill pseudo/transport/URL/room from the authenticated user + their project
## record. Shows a dropdown of all user projects so they can pick which one to join.
## The relay verifies access using the same data.
func apply_user_auth(user_email: String, project_id: String, relay_url: String = "",
		projects: Array = []) -> void:
	_auto_filled = true
	_auto_filled_email = user_email
	_auto_filled_room = project_id
	_projects_list = projects
	var url := relay_url.strip_edges()
	if url.is_empty():
		url = _ws_url
	_auto_filled_url = url
	_ws_url = url
	_apply_auto_fill()


## Restore the connection fields to user-editable state.
func clear_user_auth() -> void:
	_auto_filled = false
	_auto_filled_email = ""
	_auto_filled_room = ""
	_auto_filled_url = ""
	_projects_list = []
	if _peer_name_input != null:
		_peer_name_input.editable = true
	if _transport_select != null:
		_transport_select.disabled = false
	if _address_input != null:
		_address_input.editable = true
	if _room_input != null:
		_room_input.editable = true
		_room_input.visible = true
	if _room_select != null:
		_room_select.visible = false
		_room_select.clear()
	if _refresh_rooms_btn != null:
		_refresh_rooms_btn.visible = false


func _apply_auto_fill() -> void:
	if not _auto_filled:
		return
	if _peer_name_input != null:
		_peer_name_input.text = _auto_filled_email
		_peer_name_input.editable = false
	if _transport_select != null:
		_transport_select.select(1)
		_transport_select.disabled = true
	if _address_input != null:
		_address_input.text = _auto_filled_url
		_address_input.editable = false
	# Room: show a dropdown of all user projects when available, locked input otherwise.
	if _room_select != null and not _projects_list.is_empty():
		_room_select.clear()
		var select_idx := 0
		for i in range(_projects_list.size()):
			var p = _projects_list[i]
			var p_id := String(p.get("id", "")).strip_edges()
			var p_name := String(p.get("name", "")).strip_edges()
			if p_name.is_empty():
				p_name = p_id
			_room_select.add_item(p_name, i)
			_room_select.set_item_metadata(i, p_id)
			if p_id == _auto_filled_room:
				select_idx = i
		_room_select.select(select_idx)
		_room_select.disabled = false
		_room_select.visible = true
		if _refresh_rooms_btn != null:
			_refresh_rooms_btn.visible = true
		if _room_input != null:
			_room_input.visible = false
	else:
		if _room_input != null:
			_room_input.text = _auto_filled_room
			_room_input.editable = false
			_room_input.visible = true
		if _room_select != null:
			_room_select.visible = false
	# Switch _sync_transport_fields helpers off because transport is forced.
	if _port_row != null:
		_port_row.visible = false
	if _room_row != null:
		_room_row.visible = true
	if _address_label != null:
		_address_label.text = "URL:"


func is_authenticated() -> bool:
	return _auth_authenticated


func _apply_auth_gate() -> void:
	# Join stays usable without the credential the relay is known to want: the
	# relay's answer is what corrects a remembered mode its owner has changed.
	var in_session := _stop_btn != null and not _stop_btn.disabled
	if _join_btn != null:
		_join_btn.disabled = in_session
	if _host_btn != null:
		_host_btn.disabled = in_session


## Shows only what the selected relay asks for: the Godot Manager login for a
## "backend" relay, the password box for a "password" relay, nothing otherwise.
## ENet goes peer to peer and never asks.
func _refresh_auth_ui() -> void:
	var on_relay := _get_selected_transport() == TRANSPORT_WEBSOCKET
	var mode := get_relay_auth_mode() if on_relay else RELAY_AUTH_NONE
	var show_login := _auth_authenticated or mode == RELAY_AUTH_BACKEND
	if _auth_panel != null:
		_auth_panel.visible = show_login
	if _auth_separator != null:
		_auth_separator.visible = show_login
	if _relay_password_row != null:
		_relay_password_row.visible = mode == RELAY_AUTH_PASSWORD
	# Being "online in the manager" needs a manager to report to.
	if _activity_ping_checkbox != null:
		_activity_ping_checkbox.visible = _auth_authenticated
	if _host_btn != null:
		_host_btn.visible = not on_relay
	if _hint_label != null:
		_hint_label.text = _hint_for(on_relay, mode)
	_apply_auth_gate()


func _hint_for(on_relay: bool, mode: String) -> String:
	if not on_relay:
		return "💡 One editor clicks Host, the others enter its IP and click Join."
	match mode:
		RELAY_AUTH_BACKEND:
			if _auth_authenticated:
				return "Choose a project, then click Join."
			return ("💡 This relay needs a Godot Manager account: log in above, "
				+ "or enter the URL of another relay.")
		RELAY_AUTH_PASSWORD:
			return "💡 Enter the relay password, then click Join."
		RELAY_AUTH_NONE:
			return "💡 Pick a room, then click Join."
	return "💡 Pick a room, then click Join. The relay tells you if it needs a password or a login."


## Auth mode the relay at the current URL announced, "" when it never said.
func get_relay_auth_mode() -> String:
	return relay_auth_mode_for(_ws_url)


func relay_auth_mode_for(url: String) -> String:
	var key := _relay_key(url)
	if _relay_auth_modes.has(key):
		return String(_relay_auth_modes[key])
	# The hosted relay wants a Godot Manager login; show it before the first try.
	if key == _relay_key(DEFAULT_WS_URL):
		return RELAY_AUTH_BACKEND
	return ""


## Records the mode a relay announced and updates the fields to match.
func remember_relay_auth_mode(url: String, mode: String) -> void:
	var key := _relay_key(url)
	if key.is_empty() or mode.is_empty():
		return
	if String(_relay_auth_modes.get(key, "")) != mode:
		_relay_auth_modes[key] = mode
		EditorInterface.get_editor_settings().set_setting(_SETTING_RELAY_AUTH_MODES, _relay_auth_modes)
	_refresh_auth_ui()


## The relay at `url` refused us, or is known to need a credential we lack:
## show the matching field and the reason.
func show_relay_auth_needed(url: String, mode: String, message: String) -> void:
	remember_relay_auth_mode(url, mode)
	show_warning(message)
	if mode == RELAY_AUTH_BACKEND and not _auth_authenticated:
		set_auth_status(message, "error")
	elif mode == RELAY_AUTH_PASSWORD and _relay_password_input != null \
			and _relay_password_input.is_inside_tree():
		_relay_password_input.grab_focus()


func _load_relay_auth_modes() -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(_SETTING_RELAY_AUTH_MODES):
		return
	var stored = es.get_setting(_SETTING_RELAY_AUTH_MODES)
	if stored is Dictionary:
		_relay_auth_modes = stored.duplicate()


func _relay_key(url: String) -> String:
	var key := url.strip_edges().to_lower()
	while key.ends_with("/"):
		key = key.trim_suffix("/")
	return key


func _load_sync_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	# _all_sync_checkbox is NOT persisted — it always resets to true (checked) on
	# every editor start so that file sync is on by default and never silently
	# disabled across sessions.
	if not es.has_setting(_SETTING_FILE_SYNC):
		es.set_setting(_SETTING_FILE_SYNC, false)
	if not es.has_setting(_SETTING_GD_SYNC):
		es.set_setting(_SETTING_GD_SYNC, false)
	if _file_sync_checkbox != null:
		_file_sync_checkbox.button_pressed = bool(es.get_setting(_SETTING_FILE_SYNC))
	if _gd_sync_checkbox != null:
		_gd_sync_checkbox.button_pressed = bool(es.get_setting(_SETTING_GD_SYNC))


func _on_sync_setting_changed() -> void:
	var es := EditorInterface.get_editor_settings()
	if _file_sync_checkbox != null:
		es.set_setting(_SETTING_FILE_SYNC, _file_sync_checkbox.button_pressed)
	if _gd_sync_checkbox != null:
		es.set_setting(_SETTING_GD_SYNC, _gd_sync_checkbox.button_pressed)


func _get_current_room_info() -> Dictionary:
	var room_id := ""
	var room_name := ""
	if _room_select != null and _room_select.visible and _room_select.item_count > 0:
		room_id = String(_room_select.get_item_metadata(_room_select.selected))
		room_name = _room_select.get_item_text(_room_select.selected)
	else:
		room_id = _room_input.text.strip_edges() if _room_input != null else ""
		# Try to resolve name from projects list
		for p in _projects_list:
			if String(p.get("id", "")) == room_id:
				room_name = String(p.get("name", ""))
				break
	if room_name.is_empty():
		room_name = room_id
	return {"id": room_id, "name": room_name}


func set_connected(mode: String) -> void:
	if _host_btn != null:
		_host_btn.disabled = true
	_join_btn.disabled = true
	_stop_btn.disabled = false
	_peer_name_input.editable = false
	_transport_select.disabled = true
	_port_input.editable = false
	_address_input.editable = false
	_room_input.editable = false
	if _room_select != null:
		_room_select.disabled = true
	var info: Dictionary = _get_current_room_info()
	var room_id := String(info.get("id", ""))
	var room_name := String(info.get("name", ""))
	var mode_base := mode.replace(room_id, "").strip_edges() if not room_id.is_empty() else mode
	var has_distinct_name := room_name != room_id and not room_name.is_empty()
	var bbcode := "[color=#73d97f]Status: %s[/color]" % mode_base
	if has_distinct_name:
		bbcode += " [b]%s[/b]" % room_name
		if not room_id.is_empty():
			bbcode += " [color=#888888](%s)[/color]" % room_id
	elif not room_id.is_empty():
		bbcode += " [color=#888888]%s[/color]" % room_id
	_status_label.text = bbcode


func show_warning(message: String) -> void:
	_status_label.text = "[color=#ffb233]Status: %s[/color]" % message


## Called by _on_connection_dropped() in the main plugin to reflect a silent
## WebSocket drop in the dock UI without requiring a manual stop press.
func show_connection_dropped() -> void:
	set_disconnected()
	_status_label.text = "[color=#ff7373]Status: Connection lost[/color]"


func set_disconnected() -> void:
	_stop_btn.disabled = true
	_port_input.editable = true
	_status_label.text = "[color=#ff7373]Status: Offline[/color]"
	if _peer_list:
		_peer_list.clear()
	if _auto_filled:
		_apply_auto_fill()
		if _room_select != null:
			_room_select.disabled = false
	else:
		_peer_name_input.editable = true
		_transport_select.disabled = false
		_address_input.editable = true
		_room_input.editable = true
		if _room_select != null:
			_room_select.visible = false
		_sync_transport_fields()
	_apply_auth_gate()


func set_peer_name(peer_name: String) -> void:
	if _peer_name_input:
		_peer_name_input.text = peer_name


func upsert_peer(peer_id: String, peer_label: String) -> void:
	if not _peer_list:
		return

	var item_text := "👤 " + peer_label
	for i in range(_peer_list.item_count):
		if String(_peer_list.get_item_metadata(i)) == peer_id:
			_peer_list.set_item_text(i, item_text)
			return

	var index := _peer_list.item_count
	_peer_list.add_item(item_text)
	_peer_list.set_item_metadata(index, peer_id)


func remove_peer(peer_id: String) -> void:
	if not _peer_list: return
	for i in range(_peer_list.item_count - 1, -1, -1):
		if String(_peer_list.get_item_metadata(i)) == peer_id:
			_peer_list.remove_item(i)


func update_info(text: String) -> void:
	if _info_label:
		_info_label.text = text


func set_session_state(state: Dictionary) -> void:
	_session_state = {
		"active": bool(state.get("active", false)),
		"mode": String(state.get("mode", "")).strip_edges(),
		"transport": String(state.get("transport", "")).strip_edges(),
		"room": String(state.get("room", "")).strip_edges(),
		"peer_id": String(state.get("peer_id", "")).strip_edges(),
		"peer_name": String(state.get("peer_name", "")).strip_edges(),
		"peer_count": maxi(int(state.get("peer_count", 0)), 0),
	}


func get_session_state() -> Dictionary:
	return _session_state.duplicate(true)


func is_file_sync_enabled() -> bool:
	return (_all_sync_checkbox != null and _all_sync_checkbox.button_pressed) \
		or (_file_sync_checkbox != null and _file_sync_checkbox.button_pressed)


func is_gd_sync_enabled() -> bool:
	return (_all_sync_checkbox != null and _all_sync_checkbox.button_pressed) \
		or (_gd_sync_checkbox != null and _gd_sync_checkbox.button_pressed)


func is_all_sync_enabled() -> bool:
	return _all_sync_checkbox != null and _all_sync_checkbox.button_pressed


func is_activity_ping_enabled() -> bool:
	return _activity_ping_checkbox == null or _activity_ping_checkbox.button_pressed


func _build_connection_config() -> Dictionary:
	_store_address_for_current_transport()
	var transport := _get_selected_transport()
	var room: String
	if _room_select != null and _room_select.visible and _room_select.item_count > 0:
		room = String(_room_select.get_item_metadata(_room_select.selected))
	else:
		room = _room_input.text.strip_edges()
	return {
		"transport": transport,
		"peer_name": _peer_name_input.text.strip_edges(),
		"ip": _enet_address,
		"port": int(_port_input.value),
		"server_url": _ws_url,
		"room": room,
		"relay_auth_mode": get_relay_auth_mode(),
		"relay_password": (
			_relay_password_input.text.strip_edges() if _relay_password_input != null else ""
		),
	}


func _get_selected_transport() -> String:
	if _transport_select and _transport_select.selected == 1:
		return TRANSPORT_WEBSOCKET
	return TRANSPORT_ENET


func _on_transport_selected(_index: int) -> void:
	_sync_transport_fields()


func _sync_transport_fields() -> void:
	if not _address_input:
		return

	var transport := _get_selected_transport()
	if transport == TRANSPORT_WEBSOCKET:
		_address_label.text = "URL:"
		_address_input.text = _ws_url
		_address_input.placeholder_text = "wss://synchro.godaas.org/ws-relay"
		_port_row.visible = false
		_room_row.visible = true
	else:
		_address_label.text = "IP:"
		_address_input.text = _enet_address
		_address_input.placeholder_text = "Host IP address"
		_port_row.visible = true
		_room_row.visible = false
	_refresh_auth_ui()


func _store_address_for_current_transport() -> void:
	if not _address_input:
		return

	if _get_selected_transport() == TRANSPORT_WEBSOCKET:
		_ws_url = _address_input.text.strip_edges()
	else:
		_enet_address = _address_input.text.strip_edges()


func _on_address_changed(new_text: String) -> void:
	if _get_selected_transport() == TRANSPORT_WEBSOCKET:
		_ws_url = new_text.strip_edges()
		_refresh_auth_ui()
	else:
		_enet_address = new_text.strip_edges()


func _detect_default_peer_name() -> String:
	var env_keys := PackedStringArray(["USER", "USERNAME"])
	for key in env_keys:
		if OS.has_environment(key):
			var value := OS.get_environment(key).strip_edges()
			if not value.is_empty():
				return value
	return "User"
