# GodotWithU - Plugin

**Real-time collaborative editing plugin for Godot Engine 4.6+**

This is the GodotWithU plugin addon. For complete documentation, visit the [main repository](https://github.com/Airyshtoteles/GodotWithU).

## Features

- **Real-Time Scene Sync**: Instantly replicate node changes across connected editors
- **Collaborative Script Editing**: Edit `.gd` files simultaneously with CRDT (Conflict-free Replicated Data Types)
- **Node Locking**: Prevent conflicts when multiple users select the same node
- **Pure GDScript**: No C++ compilation required
- **Host & Join Workflow**: Simple connection-based collaboration

## Installation

This plugin should be in the `addons/godot_with_u/` folder of your Godot project.

1. Open **Project → Project Settings → Plugins** tab
2. Find **GodotWithU** in the list
3. Click the checkbox to enable it

## Quick Start

### Start a Session (Host)
1. Look for the **GodotWithU** dock panel (top right of editor)
2. Set the **Port** (default: `7654`)
3. Click **Host**

### Join a Session (Client)
1. Enter the **IP address** of the host machine
2. Set the **Port** to match the host
3. Click **Join**

Once connected, any changes to scenes or scripts sync automatically!

## Licensing

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

For full documentation, architecture details, and advanced usage, visit the [main repository](https://github.com/Airyshtoteles/GodotWithU).
