# GodotWithU

**GodotWithU** is a lightweight, pure GDScript real-time collaboration plugin for the Godot Engine (v4+).
It allows multiple developers to work on the same Godot project simultaneously over a local network or VPN, similar to Unreal Engine's Multi-User Editing.

## Demo

![GodotWithU Demo](demo.gif)

## Features

- **Real-Time Scene Sync**: Instantly replicate node additions, deletions, translations, and property changes across all connected Godot editors.
- **CRDT Script Sync**: Collaborative coding with Conflict-free Replicated Data Types (Logoot). Edit the same `.gd` file simultaneously, Google Docs style.
- **Node Locking**: When a remote peer selects a node, it becomes locked (shown with a lock icon in the scene tree) to prevent conflicting edits. Locks auto-expire after 30 seconds of inactivity.
- **Pure GDScript Networking**: Uses Godot's built-in `ENetMultiplayerPeer` independently from the SceneTree API. No C++ GDExtension compilation required.
- **Host & Join Workflow**: One editor acts as the Host/Relay Server, and others join as Clients via configurable IP and Port.
- **Action Interception**: Transparently hooks into Godot's `EditorUndoRedoManager` to broadcast your edits.
- **Initial State Sync**: When a new peer joins, the host automatically sends the full scene state and all CRDT script buffers so the joiner is immediately up to date.

## Installation

1. Download the latest release from the [Releases tab](../../releases) or clone this repository.
2. Copy the `addons/godot_with_u` folder into your Godot project's `addons/` directory.
3. Open your Godot Project.
4. Go to **Project -> Project Settings -> Plugins** and enable **GodotWithU**.

## How to Use

### Starting a Session (Host)
1. In the Godot Editor, look for the **GodotWithU** dock panel (usually on the top right).
2. Leave the Port as default (e.g., `7654`) or change it if necessary.
3. Click **Host**. Your editor is now broadcasting changes and waiting for peers.

### Joining a Session (Client)
1. Another developer opens the same project on their machine (or another Godot instance on your machine locally).
2. In the GodotWithU dock, enter the **IP address** of the host machine (defaults to `127.0.0.1` for local testing).
3. Set the **Port** to match the host.
4. Click **Join**.

Once connected, any changes made to the 3D/2D Scene or Scripts will mirror instantly!

## Architecture

Instead of relying on heavy C++ implementations or modifying the main `SceneTree.multiplayer`, GodotWithU utilizes an independent `NetworkManager` running an `ENetMultiplayerPeer`. The plugin actively polls for messages every `0.05` seconds and serializes intercepted Godot actions into binary packets, broadcasting them reliably across peers.

### Conflict Resolution Strategy

| Layer | Strategy | Details |
|-------|----------|---------|
| **Script Editing** | CRDT (Logoot) | Each character has a unique, mathematically sortable position ID. Concurrent inserts at the same location are resolved deterministically by comparing site IDs. No coordination needed. |
| **Node Selection** | Locking | When a remote peer selects a node, it is locked for that peer. Other peers cannot modify or delete locked nodes. Locks auto-release when the peer changes selection, disconnects, or after a 30-second timeout. |
| **Property Changes** | Last-Write-Wins | Simultaneous property changes to the same node use last-write-wins ordering based on receive order. The locking system prevents most simultaneous edits to the same node. |
| **Node Add/Delete** | Idempotent | Duplicate `node_add` actions are ignored if the node already exists. Delete actions silently succeed if the node is already gone. |

### Security

- Remote node instantiation is validated against a whitelist of safe Godot node types.
- Packet size is limited to 8 MB to prevent memory exhaustion.
- Peer IDs use SHA-256 derived identifiers to minimize collision risk.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## Support

If you find this plugin useful, consider supporting the development:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/airyshtoteles)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
