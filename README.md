# GodotWithU 🌐

**GodotWithU** is a lightweight, pure GDScript real-time collaboration plugin for the Godot Engine (v4+). 
It allows multiple developers to work on the same Godot project simultaneously over a local network or VPN, similar to Unreal Engine's Multi-User Editing.

## ✨ Features

- **Real-Time Scene Sync**: Instantly replicate node additions, deletions, translations, and property changes across all connected Godot editors.
- **CRDT Script Sync**: Collaborative coding with Conflict-free Replicated Data Types! Edit the same `.gd` file simultaneously, Google Docs style.
- **Pure GDScript Networking**: Uses Godot's built-in `ENetMultiplayerPeer` independently from the SceneTree API. No heavy C++ GDExtension compilation required! It's perfectly safe and performant for an `EditorPlugin`.
- **Host & Join Workflow**: One editor acts as the Host/Relay Server, and others join as Clients. 
- **Action Interception**: Transparently hooks into Godot's `EditorUndoRedoManager` to broadcast your edits.

## 🚀 Installation

1. Download the latest release from the [Releases tab](../../releases) or clone this repository.
2. Copy the `addons/godot_with_u` folder into your Godot project's `addons/` directory.
3. Open your Godot Project.
4. Go to **Project -> Project Settings -> Plugins** and enable **GodotWithU**.

## 💻 How to Use

### Starting a Session (Host)
1. In the Godot Editor, look for the **GodotWithU** dock panel (usually on the top right).
2. Leave the Port as default (e.g., `7654`) or change it if necessary.
3. Click **Host**. Your editor is now broadcasting changes and waiting for peers.

### Joining a Session (Client)
1. Another developer opens the same project on their machine (or another Godot instance on your machine locally).
2. In the GodotWithU dock, set the Port to match the host.
3. Since it is currently hardcoded for localhost in `_do_join`, make sure you modify `join("127.0.0.1", port)` to target the host's LAN or VPN IP address if testing across different machines.
4. Click **Join**. 

Once connected, any changes made to the 3D/2D Scene or Scripts will mirror instantly!

## 🛠️ Architecture

Instead of relying on heavy C++ implementations or modifying the main `SceneTree.multiplayer`, GodotWithU utilizes an independent `NetworkManager` running an `ENetMultiplayerPeer`. The plugin actively polls for messages every `0.05` seconds and serializes intercepted Godot actions into JSON/Binary packets, broadcasting them reliably across peers.

## 🤝 Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
