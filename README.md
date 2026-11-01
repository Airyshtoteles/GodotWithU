# GodotWithU

Real-time collaboration for the Godot editor. Several editors, native or web,
share one session: scene edits, GDScript co-editing, cursors, node locks and
new files all travel between them.

## Demo

![GodotWithU Demo](demo.gif)

## Features

- **ENet transport**: direct peer-to-peer hosting for native editors on a LAN or VPN.
- **WebSocket relay**: works from web (WASM) editors, through a relay you host or a hosted one.
- **Scene sync**: node additions, deletions, renames, reorders and property changes.
- **Script sync (CRDT)**: conflict-free real-time co-editing of GDScript files.
- **Ghost cursors**: see where every peer's cursor is in the script editor.
- **Node locking**: a node someone has selected cannot be edited by others.
- **File sync**: new and deleted `.tscn`, `.tres`, `.gd` and shader files reach every peer.

## Installation

1. Download the latest release from the [Releases tab](../../releases) or clone
   this repository, then copy the `addons/godot_with_u` folder into the
   `addons/` folder of your Godot project.
2. Enable the plugin in **Project > Project Settings > Plugins**.
3. The **GodotWithU** dock appears on the right side of the editor.

## Usage

### WebSocket relay (web editors, or peers on different networks)

1. Set **Transport** to `WebSocket relay`.
2. Enter the relay's address in **URL**: your own relay (see below) or a hosted one.
3. Enter a shared **Room** name. Everyone in the same room works together.
4. Every peer clicks **Join**. The first one into a room coordinates it. If it
   leaves, the relay hands that role to a peer that stayed, so the session goes on.

The dock only asks for what the relay requires. The relay tells it the first
time you join, and the dock remembers it for that URL:

| Relay mode | What the dock asks for |
|------------|------------------------|
| `none`     | nothing |
| `password` | the relay password |
| `backend`  | a Godot Manager login (API token, or email and password). The room is then one of your projects |

When a relay refuses you, the dock says why and shows the missing field. Fill
it in and click **Join** again.

The default URL is the hosted Godot Manager relay
(`wss://synchro.godaas.org/ws-relay`), which authenticates against `https://studio.godaas.org`. Replace it
with your relay's URL to use your own.

### ENet (native editors, LAN or VPN)

1. Set **Transport** to `ENet (native)`.
2. One editor clicks **Host** and shares its IP address.
3. The others enter that IP and click **Join**.

ENet has no relay and no authentication: anyone who can reach the host's port
can join.

## Running your own relay

The relay lives in `ws_server/`. It is a small Node.js process:

```sh
cd ws_server
npm install
npm start
```

It listens on `0.0.0.0:7655` (change it with the `PORT` and `HOST` environment
variables). In the dock, use `ws://<relay address>:7655/`, or `wss://` behind a
TLS reverse proxy. Any path is accepted, so the proxy can mount the relay
wherever suits you.

### Choosing who may join

`npm start` starts the relay **without authentication**: anyone who knows the
URL and a room name can join. To protect it, pick another mode:

| Start command | Mode | Each peer needs |
|---------------|------|-----------------|
| `npm start` | `none` | nothing |
| `RELAY_PASSWORD=<secret> npm run start:password` | `password` | the shared password |
| `BACKEND_BASE_URL=https://<your manager> npm run start:backend` | `backend` | a Godot Manager account that can open the room's project |

The mode can also be set with the `RELAY_AUTH` environment variable
(`none`, `password` or `backend`). The `--auth` option wins over it. Started as
plain `node ws_relay_server.js` with neither, the relay uses `backend`, so a
relay launched by hand without configuration is never open.

For the password mode:

- Use a long random password, for example the output of `openssl rand -base64 18`.
- Put the relay behind TLS and give peers a `wss://` URL: the password travels
  in the join message.
- A wrong password is answered after one second, which slows down guessing.

## Privacy

The addon only contacts a Godot Manager server once you log in to one in the
dock. Your login token is only sent to a relay on that server's host, on
your own machine, or to `wss://synchro.godaas.org/ws-relay` when you log in
to `https://studio.godaas.org`. Without a login, the only server the addon talks to is the
relay you join.

## Compatibility

Godot 4.4 or later (tested on 4.4.1 and 4.6). Godot 4.3 is not supported: the
plugin uses `EditorToaster`, added in 4.4.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## Support

If you find this plugin useful, consider supporting the development:

[![Ko-fi](https://img.shields.io/badge/Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/airyshtoteles)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
