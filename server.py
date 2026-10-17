"""Small LAN relay for TiltDrive. No accounts or external services required."""

from __future__ import annotations

import asyncio
import json
import logging
import random
import socket
import threading
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.asyncio.server import ServerConnection, serve

ROOT = Path(__file__).resolve().parent
GAME_DIR = ROOT / "game"
WS_PORT = 8765
HTTP_PORT = 8000
ROOM = f"{random.randint(0, 99999):05d}"
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

rooms: dict[str, dict] = {ROOM: {"games": set(), "controllers": {}, "started": False}}


async def send(ws: ServerConnection, payload: dict) -> None:
    try:
        await ws.send(json.dumps(payload, separators=(",", ":")))
    except Exception:
        pass


async def broadcast_games(room: str, payload: dict) -> None:
    state = rooms.get(room)
    if not state:
        return
    await asyncio.gather(*(send(game, payload) for game in list(state["games"])))


async def broadcast_controllers(room: str, payload: dict) -> None:
    state = rooms.get(room)
    if not state:
        return
    await asyncio.gather(*(send(ws, payload) for ws in list(state["controllers"].keys())))


async def relay(ws: ServerConnection) -> None:
    role = None
    room = None
    player_id = None
    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                await send(ws, {"type": "error", "message": "That message was not readable."})
                continue

            kind = data.get("type")
            if kind == "join":
                requested_room = str(data.get("room", ""))
                requested_role = data.get("role")
                if requested_role not in ("game", "controller") or requested_room != ROOM:
                    await send(ws, {"type": "error", "message": "Room code not found. Make sure the game is open."})
                    continue
                role, room = requested_role, requested_room
                state = rooms[room]
                if role == "game":
                    state["games"].add(ws)
                    await send(ws, {"type": "joined", "role": "game", "room": room, "controllers": len(state["controllers"])})
                    for connected, existing_id in state["controllers"].items():
                        await send(ws, {"type": "player_joined", "playerId": existing_id, "name": "PHONE PILOT"})
                    await broadcast_controllers(room, {"type": "game_started" if state["started"] else "game_waiting"})
                else:
                    player_id = f"pilot-{len(state['controllers']) + 1}-{random.randint(100, 999)}"
                    state["controllers"][ws] = player_id
                    await send(ws, {"type": "joined", "role": "controller", "room": room, "playerId": player_id, "gameOnline": bool(state["games"])})
                    await broadcast_games(room, {"type": "player_joined", "playerId": player_id, "name": "PHONE PILOT"})
                    await send(ws, {"type": "game_started" if state["started"] else "game_waiting"})
                logging.info("%s joined room %s", role, room)
                continue

            if role is None:
                await send(ws, {"type": "error", "message": "Join a room first."})
                continue

            if kind == "ping":
                await send(ws, {"type": "pong", "sentAt": data.get("sentAt")})
            elif role == "controller" and kind == "input":
                state = rooms[room]
                pilot_id = state["controllers"].get(ws, player_id)
                await broadcast_games(room, {
                    "type": "control",
                    "playerId": pilot_id,
                    "tiltX": max(-1.0, min(1.0, float(data.get("tiltX", 0)))),
                    "tiltY": max(-1.0, min(1.0, float(data.get("tiltY", 0)))),
                    "jump": bool(data.get("jump", False)),
                    "seq": int(data.get("seq", 0)),
                })
            elif role == "game" and kind == "start":
                rooms[room]["started"] = True
                await broadcast_controllers(room, {"type": "game_started"})
            elif role == "game" and kind == "reset":
                rooms[room]["started"] = False
                await broadcast_controllers(room, {"type": "game_waiting"})
            elif role == "game" and kind == "state":
                await broadcast_controllers(room, {"type": "game_state", "score": data.get("score", 0)})
    except Exception as exc:
        logging.debug("Connection closed: %s", exc)
    finally:
        if role and room in rooms:
            state = rooms[room]
            if role == "game":
                state["games"].discard(ws)
                state["started"] = False
                await broadcast_controllers(room, {"type": "game_waiting"})
            else:
                removed_id = state["controllers"].pop(ws, player_id)
                await broadcast_games(room, {"type": "player_left", "playerId": removed_id})
            logging.info("%s left room %s", role, room)


class GameHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(GAME_DIR), **kwargs)

    def do_GET(self):
        if self.path == "/api/room":
            body = json.dumps({"room": ROOM, "websocketPort": WS_PORT}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/health":
            body = b"TiltDrive relay is up."
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/":
            self.path = "/game.html"
        return super().do_GET()

    def log_message(self, format, *args):
        logging.info("web %s - %s", self.address_string(), format % args)


def serve_http() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), GameHandler)
    server.daemon_threads = True
    logging.info("Game page: http://localhost:%s", HTTP_PORT)
    server.serve_forever()


async def main() -> None:
    threading.Thread(target=serve_http, name="tiltdrive-http", daemon=True).start()
    logging.info("Room code: %s", ROOM)
    logging.info("WebSocket relay listening on port %s", WS_PORT)
    try:
        addresses = sorted({
            row[4][0]
            for row in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
            if not row[4][0].startswith("127.")
        })
        if addresses:
            logging.info("Laptop Wi-Fi address candidates: %s", ", ".join(addresses))
    except OSError:
        pass
    threading.Timer(1.2, lambda: webbrowser.open(f"http://localhost:{HTTP_PORT}")).start()
    async with serve(relay, "0.0.0.0", WS_PORT, ping_interval=20, ping_timeout=20, max_size=4096):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nTiltDrive stopped. Thanks for driving.")
