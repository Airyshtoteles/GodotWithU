@tool
extends RefCounted

## network_manager.gd
##
## Shared transport wrapper for GodotWithU editor collaboration.
## Supports:
## - ENet peer-to-peer hosting for native editors.
## - WebSocket relay mode for Web/WASM editors through a small Node server.

signal peer_connected(id: int)
signal peer_disconnected(id: int)
## Emitted when the relay tells us which role we hold. `promoted` is false for
## the role handed out on join, true when the relay moved us later (the former
## host left and we were picked to replace it).
signal role_assigned(role: String, promoted: bool)
## Emitted when the relay states how it authenticates peers: "none", "password"
## or "backend". It says so in its welcome, and when it refuses a join.
signal relay_auth_mode_received(mode: String)

## Maximum allowed packet size (8 MB). Packets larger than this are dropped.
const MAX_PACKET_SIZE := 8 * 1024 * 1024
const WS_BUFFER_SIZE := 16 * 1024 * 1024
const WS_MAX_QUEUED_PACKETS := 32768

const TRANSPORT_ENET := "enet"
const TRANSPORT_WEBSOCKET := "websocket"
const DEFAULT_WS_URL := "wss://synchro.godaas.org/ws-relay"
const DEFAULT_WS_ROOM := "default"
const WS_HEARTBEAT_INTERVAL_MSEC := 20000
const RELAY_AUTH_NONE := "none"
const RELAY_AUTH_PASSWORD := "password"
const RELAY_AUTH_BACKEND := "backend"
## Close codes the relay uses when it refuses a join (HTTP 401 / 403 + 4000).
const WS_CLOSE_AUTH_REQUIRED := 4401
const WS_CLOSE_ACCESS_DENIED := 4403
const WS_REJECTION_CODES := ["auth_required", "auth_invalid", "project_access_denied"]

var _transport: String = ""

var _enet_peer: ENetMultiplayerPeer = null
var _enet_is_server: bool = false
var _enet_clients: Array[int] = []

var _ws_peer: WebSocketPeer = null
var _ws_server_url: String = DEFAULT_WS_URL
var _ws_room: String = DEFAULT_WS_ROOM
var _ws_role: String = "client"
var _ws_peer_name: String = ""
var _ws_auth_token: String = ""
var _ws_join_sent: bool = false
var _ws_peer_id: int = 0
var _ws_host_peer_id: int = 0
var _ws_known_peers: Array[int] = []
var _ws_peer_names: Dictionary = {}   ## peer_id (int) -> display name (String)
var _ws_last_state: int = WebSocketPeer.STATE_CLOSED
var _ws_last_heartbeat_msec: int = 0
var _ws_heartbeat_enabled: bool = false
## Auth mode the relay announced, "" until it says.
var _ws_relay_auth_mode: String = ""
## Why the relay refused our join: {code, message, auth}. Empty otherwise.
var _ws_rejection: Dictionary = {}


func host(port: int) -> Error:
	return host_enet(port)


func join(ip: String, port: int) -> Error:
	return join_enet(ip, port)


func host_enet(port: int) -> Error:
	stop()
	_transport = TRANSPORT_ENET
	_enet_peer = ENetMultiplayerPeer.new()
	var err = _enet_peer.create_server(port)
	if err == OK:
		_enet_is_server = true
		_enet_peer.peer_connected.connect(_on_enet_peer_connected)
		_enet_peer.peer_disconnected.connect(_on_enet_peer_disconnected)
	else:
		_transport = ""
		_enet_peer = null
	return err


func join_enet(ip: String, port: int) -> Error:
	stop()
	_transport = TRANSPORT_ENET
	_enet_peer = ENetMultiplayerPeer.new()
	var err = _enet_peer.create_client(ip, port)
	if err == OK:
		_enet_is_server = false
		_enet_peer.peer_connected.connect(_on_enet_peer_connected)
		_enet_peer.peer_disconnected.connect(_on_enet_peer_disconnected)
	else:
		_transport = ""
		_enet_peer = null
	return err


func host_websocket(server_url: String, room: String, peer_name: String = "", auth_token: String = "") -> Error:
	return _connect_websocket(server_url, room, "host", peer_name, auth_token)


func join_websocket(server_url: String, room: String, peer_name: String = "", auth_token: String = "") -> Error:
	return _connect_websocket(server_url, room, "client", peer_name, auth_token)


static func can_reach_websocket_server(server_url: String, timeout_ms: int = 1200) -> bool:
	# StreamPeerTCP is unavailable in WASM — skip the probe and let the
	# WebSocket connection itself report failure.
	if OS.get_name() == "Web":
		return true

	var endpoint := _parse_websocket_endpoint(server_url)
	if endpoint.is_empty():
		return false

	var tcp := StreamPeerTCP.new()
	var err := tcp.connect_to_host(String(endpoint.get("host", "")), int(endpoint.get("port", 0)))
	if err != OK:
		return false

	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		tcp.poll()
		var status := tcp.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			tcp.disconnect_from_host()
			return true
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			tcp.disconnect_from_host()
			return false
		OS.delay_msec(20)

	tcp.disconnect_from_host()
	return false


static func _parse_websocket_endpoint(server_url: String) -> Dictionary:
	var cleaned := server_url.strip_edges()
	var default_port := 80

	if cleaned.begins_with("ws://"):
		cleaned = cleaned.trim_prefix("ws://")
	elif cleaned.begins_with("wss://"):
		cleaned = cleaned.trim_prefix("wss://")
		default_port = 443

	var slash_index := cleaned.find("/")
	if slash_index != -1:
		cleaned = cleaned.substr(0, slash_index)

	if cleaned.is_empty():
		return {}

	var host := cleaned
	var port := default_port

	if cleaned.begins_with("["):
		var closing_bracket := cleaned.find("]")
		if closing_bracket == -1:
			return {}
		host = cleaned.substr(1, closing_bracket - 1)
		var remainder := cleaned.substr(closing_bracket + 1)
		if remainder.begins_with(":"):
			port = int(remainder.substr(1))
	else:
		var colon_index := cleaned.rfind(":")
		if colon_index > 0 and cleaned.count(":") == 1:
			host = cleaned.substr(0, colon_index)
			port = int(cleaned.substr(colon_index + 1))

	if host.is_empty() or port <= 0:
		return {}

	return {
		"host": host,
		"port": port,
	}


func stop() -> void:
	if _enet_peer:
		_enet_peer.close()
	_enet_peer = null
	_enet_is_server = false
	_enet_clients.clear()

	if _ws_peer:
		_ws_peer.close()
	_ws_peer = null
	_ws_server_url = DEFAULT_WS_URL
	_ws_room = DEFAULT_WS_ROOM
	_ws_role = "client"
	_ws_auth_token = ""
	_ws_join_sent = false
	_ws_peer_id = 0
	_ws_host_peer_id = 0
	_ws_known_peers.clear()
	_ws_peer_names.clear()
	_ws_last_state = WebSocketPeer.STATE_CLOSED
	_ws_last_heartbeat_msec = 0
	_ws_heartbeat_enabled = false
	_ws_relay_auth_mode = ""
	_ws_rejection = {}

	_transport = ""


func broadcast_packet(packet: PackedByteArray) -> void:
	if packet.is_empty():
		return

	match _transport:
		TRANSPORT_ENET:
			if not _enet_peer:
				return
			if _enet_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
				return
			_enet_peer.set_target_peer(0)
			_enet_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			_enet_peer.put_packet(packet)
		TRANSPORT_WEBSOCKET:
			_send_ws_packet(0, packet)


## Send a packet to a single specific peer (by transport-specific network ID).
func send_to_peer(target_id: int, packet: PackedByteArray) -> void:
	if packet.is_empty():
		return

	match _transport:
		TRANSPORT_ENET:
			if not _enet_peer:
				return
			if _enet_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
				return
			_enet_peer.set_target_peer(target_id)
			_enet_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			_enet_peer.put_packet(packet)
		TRANSPORT_WEBSOCKET:
			_send_ws_packet(target_id, packet)


## Poll incoming packets and return them as an array of
## [sender_net_id: int, packet: PackedByteArray] pairs.
func poll_messages() -> Array:
	match _transport:
		TRANSPORT_ENET:
			return _poll_enet_messages()
		TRANSPORT_WEBSOCKET:
			return _poll_ws_messages()
	return []


func is_active() -> bool:
	match _transport:
		TRANSPORT_ENET:
			return _enet_peer != null and _enet_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED
		TRANSPORT_WEBSOCKET:
			return _ws_peer != null and _ws_peer.get_ready_state() != WebSocketPeer.STATE_CLOSED
	return false


func get_transport() -> String:
	return _transport


## Auth mode the relay announced ("none", "password", "backend"), "" if unknown.
func get_relay_auth_mode() -> String:
	return _ws_relay_auth_mode


## Why the relay refused the join, as {code, message, auth}. Empty when the
## connection was not refused (still open, or dropped for another reason).
func get_rejection() -> Dictionary:
	return _ws_rejection.duplicate()


func _poll_enet_messages() -> Array:
	if not _enet_peer:
		return []

	_enet_peer.poll()

	var received: Array = []

	while _enet_peer.get_available_packet_count() > 0:
		var sender_id: int = _enet_peer.get_packet_peer()
		var packet: PackedByteArray = _enet_peer.get_packet()

		if packet.size() > MAX_PACKET_SIZE:
			push_warning(
				"[NetworkManager] Dropped oversized packet: %d bytes from peer %d"
				% [packet.size(), sender_id]
			)
			continue

		if _enet_is_server:
			var relay_targets := _enet_clients.duplicate()
			for client_id in relay_targets:
				if client_id != sender_id:
					_enet_peer.set_target_peer(client_id)
					_enet_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
					_enet_peer.put_packet(packet)

		received.append([sender_id, packet])

	return received


func _connect_websocket(server_url: String, room: String, role: String, peer_name: String = "", auth_token: String = "") -> Error:
	stop()
	_transport = TRANSPORT_WEBSOCKET
	_ws_peer = WebSocketPeer.new()
	# The 64 KiB defaults cannot hold one message near MAX_PACKET_SIZE (base64
	# adds a third) and, read once per frame, cap the throughput of an initial
	# scene state.
	_ws_peer.inbound_buffer_size = WS_BUFFER_SIZE
	_ws_peer.outbound_buffer_size = WS_BUFFER_SIZE
	_ws_peer.max_queued_packets = WS_MAX_QUEUED_PACKETS
	_ws_server_url = server_url.strip_edges()
	_ws_room = room.strip_edges()
	_ws_role = role
	_ws_peer_name = peer_name.strip_edges()
	_ws_auth_token = String(auth_token).strip_edges()
	_ws_last_heartbeat_msec = 0
	_ws_heartbeat_enabled = false

	if _ws_server_url.is_empty():
		_ws_server_url = DEFAULT_WS_URL
	if _ws_room.is_empty():
		_ws_room = DEFAULT_WS_ROOM

	var err := _ws_peer.connect_to_url(_ws_server_url)
	if err != OK:
		_transport = ""
		_ws_peer = null
		return err

	_ws_last_state = _ws_peer.get_ready_state()
	return OK


func _poll_ws_messages() -> Array:
	if not _ws_peer:
		return []

	_ws_peer.poll()

	var state := _ws_peer.get_ready_state()
	_handle_ws_state_transition(state)

	if state == WebSocketPeer.STATE_OPEN and not _ws_join_sent:
		var join_msg: Dictionary = {
			"type": "join_room",
			"room": _ws_room,
			"role": _ws_role,
		}
		if not _ws_peer_name.is_empty():
			join_msg["peer_name"] = _ws_peer_name
		if not _ws_auth_token.is_empty():
			join_msg["auth_token"] = _ws_auth_token
		_ws_send_json(join_msg)
		_ws_join_sent = true
		_ws_last_heartbeat_msec = Time.get_ticks_msec()

	if state == WebSocketPeer.STATE_OPEN:
		_ws_maybe_send_heartbeat()

	var received: Array = []

	while _ws_peer.get_available_packet_count() > 0:
		var packet: PackedByteArray = _ws_peer.get_packet()
		if not _ws_peer.was_string_packet():
			push_warning("[NetworkManager] Ignored non-text WebSocket control packet.")
			continue

		var parsed = JSON.parse_string(packet.get_string_from_utf8())
		if not (parsed is Dictionary):
			push_warning("[NetworkManager] Ignored malformed relay message.")
			continue

		var message: Dictionary = parsed
		match String(message.get("type", "")):
			"welcome":
				_ws_handle_welcome(message)
			"role_changed":
				_ws_handle_role_changed(message)
			"peer_connected":
				var pid := int(message.get("peer_id", 0))
				var pname := String(message.get("peer_name", ""))
				if not pname.is_empty():
					_ws_peer_names[pid] = pname
				_ws_register_peer(pid)
			"peer_disconnected":
				var dpid := int(message.get("peer_id", 0))
				_ws_peer_names.erase(dpid)
				_ws_unregister_peer(dpid)
			"packet":
				var sender_id := int(message.get("sender_id", 0))
				var payload := Marshalls.base64_to_raw(String(message.get("payload", "")))
				if payload.size() > MAX_PACKET_SIZE:
					push_warning(
						"[NetworkManager] Dropped oversized packet: %d bytes from peer %d"
						% [payload.size(), sender_id]
					)
					continue
				received.append([sender_id, payload])
			"error":
				_ws_handle_error(message)
			"heartbeat", "heartbeat_ack", "pong":
				pass
			"ping":
				_ws_send_json({
					"type": "pong",
					"timestamp": Time.get_unix_time_from_system(),
				})
			_:
				push_warning(
					"[NetworkManager] Ignored unknown relay message type: %s"
					% String(message.get("type", ""))
				)

	return received


func _handle_ws_state_transition(state: int) -> void:
	if state == _ws_last_state:
		return

	if state == WebSocketPeer.STATE_CLOSED:
		# The relay closes right after refusing a join. Its error message may be
		# lost with the socket, so read the refusal from the close frame too.
		if _ws_rejection.is_empty() and _ws_peer != null:
			_ws_record_close_rejection(_ws_peer.get_close_code(), _ws_peer.get_close_reason())
		var peers := _ws_known_peers.duplicate()
		_ws_known_peers.clear()
		_ws_peer_id = 0
		_ws_join_sent = false
		_ws_last_heartbeat_msec = 0
		_ws_heartbeat_enabled = false
		for peer_id in peers:
			peer_disconnected.emit(peer_id)
	elif state == WebSocketPeer.STATE_OPEN:
		_ws_last_heartbeat_msec = Time.get_ticks_msec()

	_ws_last_state = state


func _ws_handle_welcome(message: Dictionary) -> void:
	_ws_peer_id = int(message.get("peer_id", 0))
	_ws_host_peer_id = int(message.get("host_peer_id", 0))
	# A relay older than the auth modes omits the field: leave the mode unknown.
	_ws_set_relay_auth_mode(String(message.get("auth", "")))
	_ws_role = _ws_role_from_message(message)
	role_assigned.emit(_ws_role, false)
	_ws_heartbeat_enabled = (
		message.has("heartbeat_interval_ms")
		or message.has("heartbeat_interval_msec")
		or bool(message.get("heartbeat", false))
	)
	# Register pre-existing peers (may include names if relay sends them)
	var peers = message.get("peers", [])
	if peers is Array:
		for peer_entry in peers:
			if peer_entry is Dictionary:
				var pid := int(peer_entry.get("peer_id", 0))
				var pname := String(peer_entry.get("peer_name", ""))
				if not pname.is_empty():
					_ws_peer_names[pid] = pname
				_ws_register_peer(pid)
			elif peer_entry is int or peer_entry is float:
				_ws_register_peer(int(peer_entry))
	# Announce our own name to everyone already in the room
	if not _ws_peer_name.is_empty() and _ws_peer_id > 0:
		_ws_send_json({
			"type": "announce_name",
			"peer_name": _ws_peer_name,
		})


## Read the role out of a relay message, falling back to comparing our peer id
## against the room's host when an older relay omits the field.
func _ws_role_from_message(message: Dictionary) -> String:
	var assigned_role := String(message.get("role", "")).strip_edges().to_lower()
	if assigned_role == "host" or assigned_role == "client":
		return assigned_role
	return "host" if _ws_peer_id > 0 and _ws_peer_id == _ws_host_peer_id else "client"


func _ws_handle_role_changed(message: Dictionary) -> void:
	_ws_host_peer_id = int(message.get("host_peer_id", _ws_host_peer_id))
	var assigned_role := _ws_role_from_message(message)
	if assigned_role == _ws_role:
		return
	_ws_role = assigned_role
	role_assigned.emit(_ws_role, true)


func _ws_handle_error(message: Dictionary) -> void:
	var text := String(message.get("message", "unknown error"))
	push_warning("[NetworkManager] Relay error: %s" % text)
	var code := String(message.get("code", "")).strip_edges()
	if not WS_REJECTION_CODES.has(code):
		return
	# A relay older than the auth modes only ever refused backend logins.
	var auth := String(message.get("auth", RELAY_AUTH_BACKEND))
	_ws_rejection = {"code": code, "message": text, "auth": auth}
	_ws_set_relay_auth_mode(auth)


## Fallback when the refusal message did not survive the close: the relay puts
## "<code>:<auth mode>" in the close reason of a 4401 / 4403 close.
func _ws_record_close_rejection(close_code: int, close_reason: String) -> void:
	if close_code != WS_CLOSE_AUTH_REQUIRED and close_code != WS_CLOSE_ACCESS_DENIED:
		return
	var parts := close_reason.strip_edges().split(":", false, 1)
	var code := parts[0] if parts.size() > 0 else ""
	if not WS_REJECTION_CODES.has(code):
		code = "auth_required" if close_code == WS_CLOSE_AUTH_REQUIRED else "project_access_denied"
	var auth := parts[1] if parts.size() > 1 else RELAY_AUTH_BACKEND
	_ws_rejection = {"code": code, "message": close_reason, "auth": auth}
	_ws_set_relay_auth_mode(auth)


func _ws_set_relay_auth_mode(mode: String) -> void:
	var normalized := mode.strip_edges().to_lower()
	if not [RELAY_AUTH_NONE, RELAY_AUTH_PASSWORD, RELAY_AUTH_BACKEND].has(normalized):
		return
	_ws_relay_auth_mode = normalized
	relay_auth_mode_received.emit(normalized)


func _ws_register_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if peer_id == _ws_peer_id and _ws_peer_id != 0:
		return
	if _ws_known_peers.has(peer_id):
		return

	_ws_known_peers.append(peer_id)
	peer_connected.emit(peer_id)


func _ws_unregister_peer(peer_id: int) -> void:
	if not _ws_known_peers.has(peer_id):
		return

	_ws_known_peers.erase(peer_id)
	peer_disconnected.emit(peer_id)


func _ws_maybe_send_heartbeat() -> void:
	if not _ws_peer:
		return
	if not _ws_join_sent:
		return
	if not _ws_heartbeat_enabled:
		return
	if _ws_peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	var now := Time.get_ticks_msec()
	if _ws_last_heartbeat_msec > 0 and now - _ws_last_heartbeat_msec < WS_HEARTBEAT_INTERVAL_MSEC:
		return

	_ws_last_heartbeat_msec = now
	_ws_send_json({
		"type": "heartbeat",
		"peer_id": _ws_peer_id,
		"room": _ws_room,
		"timestamp": Time.get_unix_time_from_system(),
	})


func _send_ws_packet(target_id: int, packet: PackedByteArray) -> void:
	if not _ws_peer:
		return
	if _ws_peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	_ws_send_json({
		"type": "packet",
		"target": target_id,
		"payload": Marshalls.raw_to_base64(packet),
	})


func _ws_send_json(message: Dictionary) -> void:
	if not _ws_peer:
		return
	if _ws_peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	_ws_peer.send_text(JSON.stringify(message))


func _on_enet_peer_connected(id: int) -> void:
	if not _enet_clients.has(id):
		_enet_clients.append(id)
	peer_connected.emit(id)


func _on_enet_peer_disconnected(id: int) -> void:
	_enet_clients.erase(id)
	peer_disconnected.emit(id)
