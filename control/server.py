"""
control/server.py — HTTP static + WebSocket control plane.

Serve `panel.html` + l'endpoint GET `/schema` (il .json dello shader),
e un endpoint WS `/ws` che riceve messaggi JSON {name, value} dal browser
e aggiorna lo stato thread-safe.

Lato wgpu main loop: `state.snapshot_bytes(dtype)` ritorna i byte pronti
per `queue.write_buffer(uniform_buf, ...)`.

Uso:
    state = ShaderControlState(schema_path="dx12/shaders/plasma.json")
    server = start_server(state, port=54321)   # thread daemon
    # main loop:
    uni_bytes = state.snapshot_bytes(UNIFORM_DTYPE)
"""
import os, sys, json, threading, asyncio, time
import mimetypes
import numpy as np

import websockets
from http.server import HTTPServer, BaseHTTPRequestHandler


HERE = os.path.dirname(os.path.abspath(__file__))


# ─── stato condiviso ────────────────────────────────────────────────────────
class ShaderControlState:
    """
    Tiene i valori correnti dei parametri (dict name -> scalar | list[3]).
    Popolato dai default dello schema + overridato via WS.
    Supporta cambio shader a runtime via pending_shader.
    """
    def __init__(self, schema_path: str, shaders_dir: str | None = None,
                 clock=time.monotonic):
        self.schema_path = os.path.abspath(schema_path)
        self.shaders_dir = shaders_dir or os.path.dirname(self.schema_path)
        self._lock = threading.Lock()
        self._clock = clock                       # iniettabile per i test
        self._values: dict = {}
        self._ranges: dict = {}                   # name -> (min, max, is_int)
        self._sources: dict = {}                  # name -> (source, timestamp)
        self._schema: dict | None = None
        self._schema_mtime: float = 0.0
        self._pending_shader: str | None = None   # name without extension
        self._pending_code: tuple | None = None   # (wgsl, client) live coding
        self.reload_schema()

    # -- range / clamp ----------------------------------------------------
    @staticmethod
    def _clamp(value, lo, hi, is_int: bool):
        v = int(round(float(value))) if is_int else float(value)
        if lo is not None and v < lo:
            v = int(lo) if is_int else float(lo)
        if hi is not None and v > hi:
            v = int(hi) if is_int else float(hi)
        return v

    def _clamp_to_schema(self, name, value):
        """Clampa nel range dello schema corrente. I colori passano intatti."""
        rng = self._ranges.get(name)
        if rng is None:
            return value
        lo, hi, is_int = rng
        try:
            return self._clamp(value, lo, hi, is_int)
        except (TypeError, ValueError):
            return value

    def _apply_schema_locked(self, schema: dict, preserve: bool):
        """Popola _ranges e _values dal nuovo schema. Chiamare col lock preso.

        preserve=True conserva i valori gia' impostati (clampati nel nuovo
        range), preserve=False riparte dai default dello schema.
        """
        self._ranges = {}
        for u in schema["uniforms"]:
            if u["type"] in ("float", "int"):
                self._ranges[u["name"]] = (u.get("min"), u.get("max"),
                                           u["type"] == "int")
        for u in schema["uniforms"]:
            name = u["name"]
            if preserve and name in self._values:
                self._values[name] = self._clamp_to_schema(name, self._values[name])
            elif name not in self._values:
                self._values[name] = u["default"]

    # -- schema ----------------------------------------------------------
    def reload_schema(self) -> bool:
        """Rilegge il file .json se cambiato sul disco. Ritorna True se reloadato."""
        try:
            m = os.path.getmtime(self.schema_path)
        except OSError:
            return False
        if m == self._schema_mtime and self._schema is not None:
            return False
        with open(self.schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)
        with self._lock:
            self._schema = schema
            self._schema_mtime = m
            self._apply_schema_locked(schema, preserve=True)
        return True

    def get_schema(self) -> dict:
        with self._lock:
            return json.loads(json.dumps(self._schema))  # deep copy

    # -- shader switching ------------------------------------------------
    def list_shaders(self) -> list[dict]:
        """Return list of available shaders [{name, file}] from shaders_dir."""
        result = []
        for f in sorted(os.listdir(self.shaders_dir)):
            if f.endswith(".json"):
                name = f[:-5]
                wgsl = os.path.join(self.shaders_dir, name + ".wgsl")
                if os.path.exists(wgsl):
                    result.append({"name": name, "file": f})
        return result

    def request_shader_change(self, name: str):
        """Request shader change. Main loop picks it up via pop_pending_shader()."""
        with self._lock:
            self._pending_shader = name

    def pop_pending_shader(self) -> str | None:
        """Called by main loop. Returns shader name if change requested, else None."""
        with self._lock:
            name = self._pending_shader
            self._pending_shader = None
            return name

    def switch_schema(self, name: str) -> bool:
        """Passa allo schema di un altro shader conservando i valori correnti.

        I parametri con lo stesso nome sopravvivono al cambio shader, clampati
        nel range del nuovo schema: dal vivo azzerare tutto a ogni switch
        significa perdere la regolazione. I range differiscono davvero tra gli
        shader (scale 0.2-6 vs 1-20, octaves 1-4 vs 3-12), quindi il clamp non
        e' opzionale. I parametri assenti dal nuovo schema restano nel dict e
        tornano se si rientra in uno shader che li prevede.
        """
        new_path = os.path.join(self.shaders_dir, name + ".json")
        if not os.path.exists(new_path):
            return False
        self.schema_path = os.path.abspath(new_path)
        self._schema_mtime = 0.0
        self.reload_schema()
        return True

    # -- live coding -----------------------------------------------------
    def push_shader_code(self, code: str, client=None):
        """Accoda WGSL da compilare. Il main loop lo raccoglie col pop."""
        with self._lock:
            self._pending_code = (code, client)

    def pop_shader_code(self):
        """Chiamato dal main loop. Ritorna (code, client) o None.

        La compilazione deve avvenire nel main loop, mai nel thread WS:
        costruire una pipeline wgpu da un altro thread mentre il loop
        renderizza non e' sicuro.
        """
        with self._lock:
            pending = self._pending_code
            self._pending_code = None
            return pending

    # -- valori ----------------------------------------------------------
    def set_value(self, name: str, value, source: str = "panel"):
        """Scrive un parametro, clampato, ricordando da dove e' arrivato.

        `source` e' uno di "panel", "ws", "osc". Serve solo a far spegnere lo
        slider nel panel quando il parametro e' pilotato da fuori: la semantica
        di scrittura resta "ultimo che scrive vince" per tutte le sorgenti.
        """
        with self._lock:
            self._values[name] = self._clamp_to_schema(name, value)
            self._sources[name] = (source, self._clock())

    def external_locks(self, timeout: float = 2.0) -> list[str]:
        """Parametri scritti da OSC/WS esterno negli ultimi `timeout` secondi.

        Il timeout evita che staccare il patch TD lasci la UI morta senza modo
        di riprendere il controllo.
        """
        now = self._clock()
        with self._lock:
            return sorted(n for n, (src, ts) in self._sources.items()
                          if src in ("osc", "ws") and (now - ts) < timeout)

    def get_value(self, name, default=None):
        with self._lock:
            return self._values.get(name, default)

    def snapshot(self) -> dict:
        with self._lock:
            return dict(self._values)

    # -- serializzazione a uniform bytes --------------------------------
    def snapshot_as_struct(self, layout: list[tuple[str, str, int | None]],
                           extras: dict | None = None) -> bytes:
        """
        Serializza i valori attuali nello struct WGSL secondo `layout`.
        `layout` è una lista di tuple (name, type, index):
          - ("time", "f32", None)
          - ("col_a", "vec3", None)  -> pack + 1 pad float per vec4 alignment
          - ("scale", "f32", None)
        `extras` può override valori non nel _values (es. time live, width, height).
        Ritorna bytes LE.
        """
        import struct
        buf = bytearray()
        vals = self.snapshot()
        if extras:
            vals = {**vals, **extras}
        for name, kind, _ in layout:
            v = vals.get(name, 0)
            if kind == "f32":
                buf += struct.pack("<f", float(v))
            elif kind == "i32":
                buf += struct.pack("<i", int(v))
            elif kind == "vec3":  # pack come vec4 (align 16)
                r, g, b = (list(v) + [0, 0, 0])[:3]
                buf += struct.pack("<ffff", float(r), float(g), float(b), 0.0)
            elif kind == "pad":
                buf += b"\x00\x00\x00\x00"
            else:
                raise ValueError(f"unknown kind {kind}")
        return bytes(buf)


# ─── HTTP handler (servito da thread dedicato) ──────────────────────────────
def make_http_handler(state: ShaderControlState):
    class H(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            # Silenzia il rumore in console
            pass

        def _send(self, status: int, body: bytes, ctype: str):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/" or path == "/panel.html":
                p = os.path.join(HERE, "panel.html")
                with open(p, "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
                return
            if path == "/schema":
                state.reload_schema()
                body = json.dumps(state.get_schema()).encode("utf-8")
                self._send(200, body, "application/json")
                return
            if path == "/shaders":
                body = json.dumps(state.list_shaders()).encode("utf-8")
                self._send(200, body, "application/json")
                return
            self._send(404, b"not found", "text/plain")
    return H


# ─── WebSocket handler ──────────────────────────────────────────────────────
_ws_clients: set = set()
_ws_loop: asyncio.AbstractEventLoop | None = None

async def _ws_handler(ws, state: ShaderControlState):
    _ws_clients.add(ws)
    # Panel e client esterni (TouchDesigner) condividono la stessa porta, ma
    # non la stessa provenienza: se marcassimo tutto "ws" il panel spegnerebbe
    # i propri slider da solo. Chi non si presenta con `hello` e' esterno.
    role = "ws"
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
                mtype = msg.get("type")

                if mtype == "hello":
                    if msg.get("client") == "panel":
                        role = "panel"
                    continue

                # Live coding: WGSL spedito da fuori, compilato dal main loop
                if mtype == "shader_code":
                    code = msg.get("code")
                    if code:
                        state.push_shader_code(code, ws)
                        print(f"[ws] shader_code ricevuto ({len(code)} byte)")
                    continue

                if mtype == "change_shader":
                    shader_name = msg.get("shader")
                    if shader_name:
                        state.request_shader_change(shader_name)
                        print(f"[ws] shader change requested: {shader_name}")
                    continue

                # Normal parameter update
                name = msg.get("name"); value = msg.get("value")
                if name is None:
                    continue
                state.set_value(name, value, source=role)
            except Exception as e:
                print(f"[ws] bad msg: {e}")
    finally:
        _ws_clients.discard(ws)


def notify_shader_result(client, ok: bool, error: str | None = None):
    """Rimanda l'esito della compilazione a chi ha spedito il codice.

    Chiamato dal main loop (thread diverso da quello del WS), quindi il send
    va schedulato sul loop asyncio del server.
    """
    if client is None or _ws_loop is None:
        return
    payload = {"type": "shader_result", "ok": ok}
    if error:
        payload["error"] = error
    try:
        asyncio.run_coroutine_threadsafe(
            client.send(json.dumps(payload)), _ws_loop)
    except Exception as e:
        print(f"[ws] shader_result non inviato: {e}")


async def broadcast(msg: dict):
    if not _ws_clients:
        return
    raw = json.dumps(msg)
    # Copia perché il set può mutare durante l'iterazione
    for c in list(_ws_clients):
        try:
            await c.send(raw)
        except Exception:
            _ws_clients.discard(c)


# ─── Schema watcher: notifica via WS se il file .json cambia ───────────────
async def _schema_watch_loop(state: ShaderControlState, interval: float = 0.5):
    last_locks = None
    while True:
        await asyncio.sleep(interval)
        try:
            if state.reload_schema():
                await broadcast({"type": "schema_changed"})
                print(f"[control] schema reloaded -> notified {len(_ws_clients)} client(s)")
            # Parametri pilotati da fuori: il panel ci spegne gli slider.
            # Si trasmette solo quando cambia, non a ogni giro.
            locks = state.external_locks()
            if locks != last_locks:
                last_locks = locks
                await broadcast({"type": "locks", "params": locks})
        except Exception as e:
            print(f"[control] schema watch err: {e}")


# ─── entry point: HTTP + WS su due porte, 127.0.0.1 ────────────────────────
def start_servers(state: ShaderControlState,
                  http_port: int = 54321,
                  ws_port: int = 54322,
                  bind: str = "127.0.0.1") -> None:
    """Due porte: HTTP su `http_port`, WS su `ws_port`. Entrambe 127.0.0.1.
    Il browser apre panel.html su http_port e poi fa new WebSocket su ws_port.
    Il panel.html sceglie la porta WS leggendo un query param `ws`.
    """
    # --- HTTP thread -----------------------------------------------------
    handler = make_http_handler(state)
    httpd = HTTPServer((bind, http_port), handler)

    def _serve():
        httpd.serve_forever()
    t_http = threading.Thread(target=_serve, daemon=True, name="http-panel")
    t_http.start()

    # --- WS thread (asyncio) --------------------------------------------
    def _run_ws():
        global _ws_loop
        asyncio.set_event_loop(asyncio.new_event_loop())
        loop = asyncio.get_event_loop()
        _ws_loop = loop
        async def main():
            # 1 MB: il limite precedente (16 KB) stava stretto al live coding,
            # raymarch.wgsl ci passava di poco.
            async with websockets.serve(lambda w: _ws_handler(w, state),
                                         bind, ws_port,
                                         max_size=1 << 20, compression=None):
                await _schema_watch_loop(state)
        loop.run_until_complete(main())

    t_ws = threading.Thread(target=_run_ws, daemon=True, name="ws-panel")
    t_ws.start()

    print(f"[control] HTTP  http://{bind}:{http_port}/?ws={ws_port}")
    print(f"[control] WS    ws://{bind}:{ws_port}/")
