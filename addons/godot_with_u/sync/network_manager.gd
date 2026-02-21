@tool
extends RefCounted
class_name NetworkManager

## network_manager.gd
##
## A pure GDScript networking layer for GodotWithU Editor collaboration.
## Replaces the C++ NetworkBridge. Uses Godot's built-in ENetMultiplayerPeer 
## independently from the SceneTree multiplayer API, making it perfectly safe 
## for an EditorPlugin while handling framing, peers, and reliable delivery natively.

var _peer: ENetMultiplayerPeer = null
var _is_server: bool = false
var _clients: Array[int] = []

signal peer_connected(id: int)
signal peer_disconnected(id: int)

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

func poll_messages() -> Array[PackedByteArray]:
	if not _peer:
		return []
		
	# Process network events (connections, disconnections, incoming packets)
	_peer.poll()
	
	var received: Array[PackedByteArray] = []
	
	while _peer.get_available_packet_count() > 0:
		var peer_id: int = _peer.get_packet_peer()
		var packet: PackedByteArray = _peer.get_packet()
		
		# If we are the host (server), we act as a relay for the "Multiuser" topology.
		# When a client sends a packet to the host, the host must bounce it to all OTHER clients.
		if _is_server:
			for client_id in _clients:
				if client_id != peer_id:
					_peer.set_target_peer(client_id)
					_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
					_peer.put_packet(packet)
					
		received.append(packet)
		
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
