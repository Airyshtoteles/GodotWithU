const crypto = require("crypto");
const http = require("http");
const util = require("util");
const { WebSocketServer, WebSocket } = require("ws");

const host = process.env.HOST || "0.0.0.0";
const port = Number(process.env.PORT || 7655);
const RELAY_ERROR_BUFFER_SIZE = Math.max(50, Number.parseInt(process.env.RELAY_ERROR_BUFFER_SIZE || "300", 10) || 300);
const HEARTBEAT_INTERVAL_MS = Math.max(5_000, Number.parseInt(process.env.WS_HEARTBEAT_INTERVAL_MS || "25000", 10) || 25_000);
const HEARTBEAT_MAX_MISSED = Math.max(1, Number.parseInt(process.env.WS_HEARTBEAT_MAX_MISSED || "3", 10) || 3);
const RELAY_EVENT_BUFFER_SIZE = Math.max(50, Number.parseInt(process.env.RELAY_EVENT_BUFFER_SIZE || "200", 10) || 200);

// How a peer proves it may join a room:
//   none      anyone can join (LAN, trusted friends, local dev)
//   password  every peer sends the shared RELAY_PASSWORD
//   backend   every peer sends a Godot Manager token, checked against
//             BACKEND_BASE_URL, and the room must be a project it can open
// Read from --auth <mode>, then RELAY_AUTH, then the older RELAY_REQUIRE_AUTH=0
// (none). Without any of them the relay uses backend, so a relay started with
// no configuration never ends up open by accident.
const AUTH_MODES = ["none", "password", "backend"];
const BACKEND_BASE_URL = (process.env.BACKEND_BASE_URL || "https://studio.godaas.org").replace(/\/+$/, "");
const AUTH_VERIFY_TIMEOUT_MS = Math.max(500, Number.parseInt(process.env.RELAY_AUTH_TIMEOUT_MS || "5000", 10) || 5000);
// Slows down password guessing; the real defence is a long random password.
const PASSWORD_FAILURE_DELAY_MS = 1000;

function readCliOption(name) {
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === `--${name}`) return args[i + 1] || "";
    if (args[i].startsWith(`--${name}=`)) return args[i].slice(name.length + 3);
  }
  return "";
}

function resolveAuthMode() {
  const requested = String(readCliOption("auth") || process.env.RELAY_AUTH || "").trim().toLowerCase();
  if (requested) return requested;
  if (String(process.env.RELAY_REQUIRE_AUTH || "").trim() === "0") return "none";
  return "backend";
}

const AUTH_MODE = resolveAuthMode();
const RELAY_PASSWORD = String(process.env.RELAY_PASSWORD || "");
if (!AUTH_MODES.includes(AUTH_MODE)) {
  console.error(`[relay] unknown auth mode "${AUTH_MODE}", expected one of: ${AUTH_MODES.join(", ")}`);
  process.exit(1);
}
if (AUTH_MODE === "password" && !RELAY_PASSWORD) {
  console.error("[relay] auth mode \"password\" needs the RELAY_PASSWORD environment variable");
  process.exit(1);
}

// Compares digests so the check takes the same time whatever the input length.
function passwordMatches(candidate) {
  const given = crypto.createHash("sha256").update(String(candidate)).digest();
  const expected = crypto.createHash("sha256").update(RELAY_PASSWORD).digest();
  return crypto.timingSafeEqual(given, expected);
}

async function backendFetch(path, token) {
  const trimmed = typeof token === "string" ? token.trim() : "";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), AUTH_VERIFY_TIMEOUT_MS);
  try {
    const response = await fetch(`${BACKEND_BASE_URL}${path}`, {
      method: "GET",
      headers: {
        "Accept": "application/json",
        ...(trimmed ? { "Authorization": `Bearer ${trimmed}` } : {}),
      },
      signal: controller.signal,
    });
    let payload = null;
    try {
      payload = await response.json();
    } catch {}
    return { ok: response.ok, status: response.status, payload };
  } catch (error) {
    return { ok: false, status: 0, payload: null, error: error && error.message ? error.message : String(error) };
  } finally {
    clearTimeout(timer);
  }
}


async function verifyBearerToken(token) {
  const trimmed = typeof token === "string" ? token.trim() : "";
  if (!trimmed) {
    return { ok: false, error: "missing auth token" };
  }
  const result = await backendFetch("/api/me", trimmed);
  if (!result.ok) {
    if (result.error) return { ok: false, error: `backend verify failed: ${result.error}` };
    return { ok: false, error: `backend rejected token (HTTP ${result.status})` };
  }
  const user = result.payload && typeof result.payload === "object" ? result.payload.user : null;
  return { ok: true, user: user && typeof user === "object" ? user : {} };
}


// Returns { ok: true } if the user has access to the project (by id) in `room`.
async function verifyProjectAccess(token, roomProjectId) {
  const trimmedRoom = typeof roomProjectId === "string" ? roomProjectId.trim() : "";
  if (!trimmedRoom) {
    return { ok: false, error: "room must be a project id" };
  }
  const result = await backendFetch("/api/projects", token);
  if (!result.ok) {
    if (result.error) return { ok: false, error: `project lookup failed: ${result.error}` };
    return { ok: false, error: `project lookup failed (HTTP ${result.status})` };
  }
  const payload = result.payload;
  if (!payload || typeof payload !== "object") {
    return { ok: false, error: "invalid /api/projects response" };
  }
  const lists = [payload.projects, payload.sharedProjects];
  for (const list of lists) {
    if (!Array.isArray(list)) continue;
    for (const entry of list) {
      if (entry && typeof entry === "object" && String(entry.id || "").trim() === trimmedRoom) {
        return { ok: true, project: entry };
      }
    }
  }
  return { ok: false, error: "no access to this project" };
}

let nextPeerId = 1;

const rooms = new Map();
const relayErrors = [];
const relayEvents = [];
let relayErrorSeq = 0;
let relayEventSeq = 0;

function formatErrorValue(value) {
  if (value instanceof Error) {
    return value.stack || value.message;
  }
  if (typeof value === "string") {
    return value;
  }
  return util.inspect(value, { depth: 6, breakLength: 160, compact: true, colors: false });
}

function stripAnsiSequences(value) {
  return String(value || "")
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\u001b[@-_]/g, "")
    .trim();
}

function pushRelayError({ message = "", details = "", level = "error" }) {
  const normalizedMessage = stripAnsiSequences(message);
  const normalizedDetails = stripAnsiSequences(details);
  if (!normalizedMessage && !normalizedDetails) {
    return;
  }

  relayErrorSeq += 1;
  relayErrors.push({
    id: relayErrorSeq,
    ts: new Date().toISOString(),
    level,
    message: normalizedMessage || normalizedDetails,
    details: normalizedDetails || null,
  });

  if (relayErrors.length > RELAY_ERROR_BUFFER_SIZE) {
    relayErrors.splice(0, relayErrors.length - RELAY_ERROR_BUFFER_SIZE);
  }
}

function nowIso() {
  return new Date().toISOString();
}

function getSessionDisplayName(session) {
  return String(
    session && (
      session.displayName
      || session.authUserName
      || session.authUserEmail
      || session.authUserId
      || ""
    )
  ).trim();
}

function pushRelayEvent({ type = "", room = "", peerId = 0, role = "", displayName = "", source = "external" }) {
  const eventType = String(type || "").trim();
  if (!eventType) return;

  relayEventSeq += 1;
  relayEvents.push({
    id: relayEventSeq,
    ts: nowIso(),
    source,
    type: eventType,
    room: String(room || ""),
    peerId: Number(peerId) || 0,
    role: String(role || ""),
    displayName: String(displayName || ""),
  });

  if (relayEvents.length > RELAY_EVENT_BUFFER_SIZE) {
    relayEvents.splice(0, relayEvents.length - RELAY_EVENT_BUFFER_SIZE);
  }
}

const originalConsoleError = console.error.bind(console);
console.error = (...args) => {
  try {
    const full = args.map(formatErrorValue).join(" ");
    pushRelayError({ message: full, level: "error" });
  } catch {}
  originalConsoleError(...args);
};

process.on("unhandledRejection", (reason) => {
  pushRelayError({
    message: "Unhandled promise rejection",
    details: formatErrorValue(reason),
    level: "error",
  });
});

process.on("uncaughtException", (error) => {
  pushRelayError({
    message: "Uncaught exception",
    details: formatErrorValue(error),
    level: "error",
  });
});

function getOrCreateRoom(name) {
  if (!rooms.has(name)) {
    rooms.set(name, {
      name,
      hostPeerId: 0,
      peers: new Map(),
      createdAt: nowIso(),
      updatedAt: nowIso(),
    });
  }

  return rooms.get(name);
}

function sendJson(socket, message) {
  if (socket.readyState !== WebSocket.OPEN) {
    return;
  }

  socket.send(JSON.stringify(message));
}

function handleHeartbeatMessage(session, message) {
  session.socket.isAlive = true;
  session.socket.missedPongs = 0;

  const requestType = typeof message.type === "string" ? message.type : "heartbeat";
  sendJson(session.socket, {
    type: requestType === "ping" ? "pong" : "heartbeat_ack",
    timestamp: new Date().toISOString(),
  });
}

function normalizeRoomName(value) {
  if (typeof value !== "string") {
    return "default";
  }

  const room = value.trim();
  return room.length > 0 ? room.slice(0, 128) : "default";
}

function leaveRoom(session) {
  if (!session.roomName) {
    return;
  }

  const room = rooms.get(session.roomName);
  if (!room) {
    session.roomName = "";
    return;
  }

  const displayName = getSessionDisplayName(session);
  room.peers.delete(session.peerId);
  room.updatedAt = nowIso();

  if (room.hostPeerId === session.peerId) {
    // Hand the coordinator role to whoever is still in the room, so the
    // session survives the host closing its editor.
    room.hostPeerId = 0;
    const nextHost = room.peers.values().next().value;
    if (nextHost) {
      nextHost.role = "host";
      room.hostPeerId = nextHost.peerId;
      sendJson(nextHost.socket, {
        type: "role_changed",
        role: "host",
        host_peer_id: room.hostPeerId,
      });
      console.log(
        `[relay] peer ${nextHost.peerId} promoted to host in room "${room.name}"`
      );
    }
  }

  for (const peer of room.peers.values()) {
    sendJson(peer.socket, {
      type: "peer_disconnected",
      peer_id: session.peerId,
    });
  }

  console.log(`[relay] peer ${session.peerId} left room "${room.name}"`);
  pushRelayEvent({
    type: "leave",
    room: room.name,
    peerId: session.peerId,
    role: session.role,
    displayName,
  });

  if (room.peers.size === 0) {
    rooms.delete(room.name);
    console.log(`[relay] removed empty room "${room.name}"`);
  }

  session.roomName = "";
}

// Returns { ok: true } when the peer may join, otherwise the refusal to send.
// `auth_token` carries the credential for both modes that need one: the shared
// password, or the Godot Manager bearer token.
async function authorizeJoin(session, message, roomName) {
  const credential = typeof message.auth_token === "string" ? message.auth_token.trim() : "";

  if (AUTH_MODE === "none") {
    return { ok: true };
  }

  if (AUTH_MODE === "password") {
    if (!credential) {
      return { ok: false, code: "auth_required", closeCode: 4401, message: "this relay requires a password" };
    }
    if (!passwordMatches(credential)) {
      await new Promise((resolve) => setTimeout(resolve, PASSWORD_FAILURE_DELAY_MS));
      return { ok: false, code: "auth_invalid", closeCode: 4401, message: "wrong relay password" };
    }
    return { ok: true };
  }

  const verify = await verifyBearerToken(credential);
  if (!verify.ok) {
    return { ok: false, code: "auth_required", closeCode: 4401, message: `authentication required: ${verify.error}` };
  }
  session.authUserId = String((verify.user && verify.user.id) || "");
  session.authUserEmail = String((verify.user && verify.user.email) || "");
  session.authUserName = String((verify.user && verify.user.name) || "");

  const access = await verifyProjectAccess(credential, roomName);
  if (!access.ok) {
    return {
      ok: false,
      code: "project_access_denied",
      closeCode: 4403,
      message: `project access denied: ${access.error}`,
    };
  }
  return { ok: true };
}

function rejectJoin(session, { code, closeCode, message }) {
  sendJson(session.socket, { type: "error", code, auth: AUTH_MODE, message });
  // The close reason repeats code and mode: a client can lose the message above
  // when the socket closes right behind it.
  try { session.socket.close(closeCode, `${code}:${AUTH_MODE}`); } catch {}
  const who = session.authUserId ? ` (user ${session.authUserId})` : "";
  console.log(`[relay] peer ${session.peerId}${who} rejected, ${code}: ${message}`);
}

async function handleJoinRoom(session, message) {
  if (session.roomName) {
    sendJson(session.socket, {
      type: "error",
      message: "peer is already joined to a room",
    });
    return;
  }

  const roomName = normalizeRoomName(message.room);

  const authorization = await authorizeJoin(session, message, roomName);
  if (!authorization.ok) {
    rejectJoin(session, authorization);
    return;
  }

  const requestedRole = message.role === "host" ? "host" : "client";
  const room = getOrCreateRoom(roomName);

  // Store optional display name sent by the client
  const rawName = typeof message.peer_name === "string" ? message.peer_name.trim().slice(0, 64) : "";
  if (rawName) session.displayName = rawName;
  if (!session.displayName) {
    session.displayName = session.authUserName || session.authUserEmail || session.authUserId || "";
  }

  if (requestedRole === "host" && room.hostPeerId !== 0 && room.hostPeerId !== session.peerId) {
    sendJson(session.socket, {
      type: "error",
      message: `room "${room.name}" already has a host`,
    });
    return;
  }

  const existingPeerIds = Array.from(room.peers.keys());
  // An empty room has no coordinator: whoever arrives first takes the role,
  // even when it only asked to join. Peers no longer need to agree in advance
  // on who presses Host.
  const role = room.hostPeerId === 0 ? "host" : requestedRole;

  room.peers.set(session.peerId, session);
  session.roomName = room.name;
  session.role = role;
  session.lastSeenAt = nowIso();
  room.updatedAt = session.lastSeenAt;

  if (role === "host") {
    room.hostPeerId = session.peerId;
  }

  sendJson(session.socket, {
    type: "welcome",
    peer_id: session.peerId,
    room: room.name,
    host_peer_id: room.hostPeerId,
    role,
    auth: AUTH_MODE,
    heartbeat_interval_ms: HEARTBEAT_INTERVAL_MS,
    // Send existing peers with their names so late joiners can populate their map
    peers: existingPeerIds.map((pid) => {
      const p = room.peers.get(pid);
      return p && p.displayName ? { peer_id: pid, peer_name: p.displayName } : pid;
    }),
  });

  for (const peerId of existingPeerIds) {
    const peer = room.peers.get(peerId);
    if (!peer) {
      continue;
    }

    sendJson(peer.socket, {
      type: "peer_connected",
      peer_id: session.peerId,
      ...(session.displayName ? { peer_name: session.displayName } : {}),
    });
  }

  console.log(
    `[relay] peer ${session.peerId} joined room "${room.name}" as ${role}`
  );
  pushRelayEvent({
    type: "join",
    room: room.name,
    peerId: session.peerId,
    role,
    displayName: getSessionDisplayName(session),
  });
}

function handlePacket(session, message) {
  if (!session.roomName) {
    sendJson(session.socket, {
      type: "error",
      message: "join a room before sending packets",
    });
    return;
  }

  if (typeof message.payload !== "string" || message.payload.length === 0) {
    sendJson(session.socket, {
      type: "error",
      message: "packet payload must be a base64 string",
    });
    return;
  }

  const room = rooms.get(session.roomName);
  if (!room) {
    sendJson(session.socket, {
      type: "error",
      message: "room no longer exists",
    });
    return;
  }

  const envelope = {
    type: "packet",
    sender_id: session.peerId,
    payload: message.payload,
  };

  const target = Number.isInteger(message.target) ? message.target : Number(message.target || 0);
  if (Number.isFinite(target) && target > 0) {
    const peer = room.peers.get(target);
    if (peer) {
      sendJson(peer.socket, envelope);
    }
    return;
  }

  for (const [peerId, peer] of room.peers.entries()) {
    if (peerId === session.peerId) {
      continue;
    }

    sendJson(peer.socket, envelope);
  }
}

const httpServer = http.createServer((request, response) => {
  if (request.url === "/errors" && request.method === "DELETE") {
    relayErrors.length = 0;
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
    return;
  }

  if (request.url && request.url.startsWith("/errors") && request.method === "GET") {
    const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
    const limit = Math.min(500, Math.max(1, Number.parseInt(url.searchParams.get("limit") || "200", 10) || 200));
    const items = relayErrors.slice(-limit).reverse();
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      items,
      total: relayErrors.length,
      bufferSize: RELAY_ERROR_BUFFER_SIZE,
    }));
    return;
  }

  if (request.url === "/health") {
    const roomList = [];
    for (const [name, room] of rooms.entries()) {
      const peers = [];
      for (const [pid, peer] of room.peers.entries()) {
        peers.push({
          peerId: pid,
          displayName: getSessionDisplayName(peer) || null,
          role: peer.role || (room.hostPeerId === pid ? "host" : "client"),
          authUserId: peer.authUserId || null,
          authUserEmail: peer.authUserEmail || null,
          connectedAt: peer.connectedAt || null,
          lastSeenAt: peer.lastSeenAt || peer.connectedAt || null,
          remoteAddress: peer.remoteAddress || null,
        });
      }
      roomList.push({
        name,
        peerCount: room.peers.size,
        hostPeerId: room.hostPeerId,
        createdAt: room.createdAt || null,
        updatedAt: room.updatedAt || null,
        peers,
      });
    }
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      rooms: rooms.size,
      roomList,
      recentErrors: relayErrors.slice(-100),
      errorCount: relayErrors.length,
      errorBufferSize: RELAY_ERROR_BUFFER_SIZE,
      recentEvents: relayEvents.slice(-100),
      eventBufferSize: RELAY_EVENT_BUFFER_SIZE,
      heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
      heartbeatMaxMissed: HEARTBEAT_MAX_MISSED,
      auth: AUTH_MODE,
    }));
    return;
  }

  response.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
  response.end("GodotWithU WebSocket relay is running.\n");
});

const wss = new WebSocketServer({ server: httpServer });
wss.on("error", (error) => {
  pushRelayError({
    message: "Relay WebSocket server error",
    details: formatErrorValue(error),
    level: "error",
  });
});

wss.on("connection", (socket, request) => {
  socket.isAlive = true;
  socket.missedPongs = 0;

  const session = {
    socket,
    peerId: nextPeerId++,
    roomName: "",
    role: "client",
    displayName: "",
    authUserId: "",
    authUserEmail: "",
    authUserName: "",
    connectedAt: nowIso(),
    lastSeenAt: nowIso(),
    remoteAddress: request.socket.remoteAddress || "",
  };

  console.log(`[relay] connected peer ${session.peerId} from ${session.remoteAddress}`);

  socket.on("pong", () => {
    socket.isAlive = true;
    socket.missedPongs = 0;
    session.lastSeenAt = nowIso();
  });

  socket.on("message", (data, isBinary) => {
    socket.isAlive = true;
    socket.missedPongs = 0;
    session.lastSeenAt = nowIso();

    if (isBinary) {
      sendJson(socket, {
        type: "error",
        message: "relay control messages must be text frames",
      });
      return;
    }

    let message;
    try {
      message = JSON.parse(String(data));
    } catch (error) {
      sendJson(socket, {
        type: "error",
        message: "invalid JSON payload",
      });
      return;
    }

    switch (message.type) {
      case "join_room":
        handleJoinRoom(session, message);
        break;
      case "announce_name": {
        // A peer announcing its display name after welcome (for peers already in room)
        const name = typeof message.peer_name === "string" ? message.peer_name.trim().slice(0, 64) : "";
        if (name) {
          session.displayName = name;
          // Broadcast updated name to all other peers in the same room
          if (session.roomName) {
            const room = rooms.get(session.roomName);
            if (room) {
              room.updatedAt = session.lastSeenAt;
              for (const [pid, peer] of room.peers.entries()) {
                if (pid !== session.peerId) {
                  sendJson(peer.socket, {
                    type: "peer_name_updated",
                    peer_id: session.peerId,
                    peer_name: name,
                  });
                }
              }
            }
          }
        }
        break;
      }
      case "heartbeat":
      case "ping":
      case "pong":
      case "heartbeat_ack":
        handleHeartbeatMessage(session, message);
        break;
      case "packet":
        handlePacket(session, message);
        break;
      default:
        sendJson(socket, {
          type: "error",
          message: `unknown message type "${message.type}"`,
        });
        break;
    }
  });

  socket.on("close", () => {
    leaveRoom(session);
    console.log(`[relay] disconnected peer ${session.peerId}`);
  });

  socket.on("error", (error) => {
    console.error(`[relay] socket error for peer ${session.peerId}:`, error.message);
  });
});

const heartbeatInterval = setInterval(() => {
  wss.clients.forEach((socket) => {
    if (socket.readyState !== WebSocket.OPEN) {
      return;
    }

    if (!socket.isAlive) {
      socket.missedPongs = (socket.missedPongs || 0) + 1;
      if (socket.missedPongs >= HEARTBEAT_MAX_MISSED) {
        socket.terminate();
        return;
      }
    } else {
      socket.missedPongs = 0;
    }

    socket.isAlive = false;
    try {
      socket.ping();
    } catch (error) {
      pushRelayError({
        message: "Relay heartbeat ping failed",
        details: formatErrorValue(error),
        level: "warning",
      });
      socket.terminate();
    }
  });
}, HEARTBEAT_INTERVAL_MS);

wss.on("close", () => clearInterval(heartbeatInterval));

httpServer.listen(port, host, () => {
  console.log(`[relay] listening on ws://${host}:${port}`);
  const authDescriptions = {
    none: "none, anyone can join",
    password: "password, peers send RELAY_PASSWORD",
    backend: `backend, Godot Manager accounts checked against ${BACKEND_BASE_URL}`,
  };
  console.log(`[relay] auth: ${authDescriptions[AUTH_MODE]}`);
});
