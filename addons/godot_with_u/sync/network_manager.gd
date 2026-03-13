@tool
class_name NetworkManager
extends RefCounted

## network_manager.gd
##
## A pure GDScript networking layer for GodotWithU Editor collaboration.
## Replaces the C++ NetworkBridge. Uses Godot's built-in ENetMultiplayerPeer
## independently from the SceneTree multiplayer API, making it perfectly safe
## for an EditorPlugin while handling framing, peers, and reliable delivery natively.

signal peer_connected(id: int)
signal peer_disconnected(id: int)

## Maximum allowed packet size (8 MB). Packets larger than this are dropped.
const MAX_PACKET_SIZE := 8 * 1024 * 1024

var _peer: ENetMultiplayerPeer = null
var _is_server: bool = false
var _clients: Array[int] = []

func host(port: int) -> Error:
	stop()
	_peer = ENetMultiplayerPeer.new()
	var err = _peer.create_server(port)
	if err == OK:
		_is_server = true
		_peer.peer_connected.connect(_on_peer_connected)
		_peer.peer_disconnected.connect(_on_peer_disconnected)
	else:
		_peer = null
	return err

func join(ip: String, port: int) -> Error:
	stop()
	_peer = ENetMultiplayerPeer.new()
	var err = _peer.create_client(ip, port)
	if err == OK:
		_is_server = false
		_peer.peer_connected.connect(_on_peer_connected)
		_peer.peer_disconnected.connect(_on_peer_disconnected)
	else:
		_peer = null
	return err

func stop() -> void:
	if _peer:
		_peer.close()
		_peer = null
	_is_server = false
	_clients.clear()

func broadcast_packet(packet: PackedByteArray) -> void:
	if not _peer or _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return

	# MultiplayerPeer constant 0 means "broadcast to all connected peers".
	# For host, this sends to all clients. For client, this sends to the host.
	_peer.set_target_peer(0)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_peer.put_packet(packet)


## Send a packet to a single specific peer (by ENet network ID).
## Used for targeted operations like initial sync to a new joiner.
func send_to_peer(target_id: int, packet: PackedByteArray) -> void:
	if not _peer or _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	_peer.set_target_peer(target_id)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_peer.put_packet(packet)

## Poll incoming packets and return them as an array of
## [sender_net_id: int, packet: PackedByteArray] pairs.
func poll_messages() -> Array:
	if not _peer:
		return []

	# Process network events (connections, disconnections, incoming packets)
	_peer.poll()

	var received: Array = []

	while _peer.get_available_packet_count() > 0:
		var sender_id: int = _peer.get_packet_peer()
		var packet: PackedByteArray = _peer.get_packet()

		# Drop oversized packets to prevent memory exhaustion
		if packet.size() > MAX_PACKET_SIZE:
			push_warning(
				"[NetworkManager] Dropped oversized packet: %d bytes from peer %d"
				% [packet.size(), sender_id]
			)
			continue

		# If we are the host (server), we act as a relay for the "Multiuser" topology.
		# When a client sends a packet to the host, the host must bounce it to all OTHER clients.
		if _is_server:
			var relay_targets := _clients.duplicate()
			for client_id in relay_targets:
				if client_id != sender_id:
					_peer.set_target_peer(client_id)
					_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
					_peer.put_packet(packet)

		received.append([sender_id, packet])

	return received

func _on_peer_connected(id: int) -> void:
	if not _clients.has(id):
		_clients.append(id)
	peer_connected.emit(id)

func _on_peer_disconnected(id: int) -> void:
	_clients.erase(id)
	peer_disconnected.emit(id)

func is_active() -> bool:
	return _peer != null and _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED
