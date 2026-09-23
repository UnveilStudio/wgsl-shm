"""
wgsl-shm — compute shader WGSL su iGPU AMD -> SHM (TouchDesigner) o NDI.

Pipeline:
  [HTML panel @127.0.0.1:54321] ──WS──► ShaderControlState
                                              │
                  AMDGenerator (iGPU AMD via wgpu-py)
                  + persistent staging buffer
                  + query set timestamp (se --profile)
                              │
                ┌─────────────┴─────────────┐
                ▼                           ▼
       SHM "TOPamd" -> TouchDesigner   NDI source (via libndi)

Run:
  python wgsl_shm.py
  python wgsl_shm.py --shader shaders/voronoi.wgsl --schema shaders/voronoi.json
  python wgsl_shm.py --preview            # finestra cv2 locale (no TD richiesto)
  python wgsl_shm.py --out ndi --ndi-name "wgsl-shm"
  python wgsl_shm.py --out spout --spout-name "wgsl-shm"   # TD Non-Commercial friendly

Apri: http://127.0.0.1:54321/?ws=54322

Opzioni:
  --profile             abilita timestamp GPU (dispatch/copy ms separate)
  --no-ui               non avvia server HTTP/WS
  --shader PATH         override del .wgsl (default shaders/plasma.wgsl)
  --schema PATH         override del .json (default shaders/plasma.json)
  --port N              HTTP port (default 54321), WS = port+1
  --width  / --height   override risoluzione (default 3840x2160)
  --preview             apri finestra cv2 con l'output (no TD necessario)
  --preview-scale F     fattore scala finestra preview (default 0.5)
  --out shm|ndi|spout   transport del frame (default shm)
"""
import os, sys, time

import numpy as np
import wgpu

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from amd_generator import AMDGenerator
from td_shm import TopSharedMemSender, TOP_FORMAT_R8G8B8A8_UNORM
from control.server import (ShaderControlState, start_servers,
                            notify_shader_result)


SHM_NAME = "TOPamd"
REPORT_N = 30
# Layout uniform WGSL di plasma.wgsl — matcha struct Uni (80 byte)
#   time, width, height, scale            (16)
#   warp, speed, color_mix, octaves       (16)
#   col_a vec4 / col_b vec4 / col_c vec4  (48)
UNIFORM_LAYOUT = [
    ("time",      "f32", None),
    ("width",     "f32", None),
    ("height",    "f32", None),
    ("scale",     "f32", None),

    ("warp",      "f32", None),
    ("speed",     "f32", None),
    ("color_mix", "f32", None),
    ("octaves",   "f32", None),

    ("col_a",     "vec3", None),
    ("col_b",     "vec3", None),
    ("col_c",     "vec3", None),
]
UNIFORM_SIZE = 80


def pick_igpu_amd(required_features: list[str] = ()):
    print("[wgsl-shm] adapter enumeration:")
    chosen = None
    for a in wgpu.gpu.enumerate_adapters_sync():
        info = a.info
        mark = "  "
        if ("AMD" in info["vendor"]
                and info["adapter_type"] == "IntegratedGPU"
                and chosen is None):
            chosen = a
            mark = "-> "
        print(f"  {mark}{info['vendor']:10s} | {info['adapter_type']:14s} | "
              f"{info['backend_type']:8s} | {info['device']}")
    if chosen is None:
        raise RuntimeError("iGPU AMD non trovato")
    try:
        dev = chosen.request_device_sync(required_features=list(required_features))
    except Exception as e:
        if required_features:
            print(f"[wgsl-shm] features {required_features} rifiutate ({e}); provo senza")
            dev = chosen.request_device_sync()
        else:
            raise
    print(f"[wgsl-shm] selected: {chosen.info['device']} ({chosen.info['backend_type']})")
    return dev


def main():
    import argparse
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", action="store_true")
    ap.add_argument("--no-ui",   action="store_true")
    ap.add_argument("--shader",  default=os.path.join(here, "shaders", "plasma.wgsl"))
    ap.add_argument("--schema",  default=os.path.join(here, "shaders", "plasma.json"))
    ap.add_argument("--port",    type=int, default=54321)
    ap.add_argument("--width",   type=int, default=3840)
    ap.add_argument("--height",  type=int, default=2160)
    ap.add_argument("--shm-name", default=SHM_NAME, help="nome SHM TD (default TOPamd)")
    ap.add_argument("--out",      default="shm", choices=["shm", "ndi", "spout"],
                    help="transport del frame: shm (default), ndi o spout")
    ap.add_argument("--ndi-name",   default=None, help="nome NDI source (default = --shm-name)")
    ap.add_argument("--ndi-fps",    default="60/1", help="frame rate NDI dichiarato (N/D, default 60/1)")
    ap.add_argument("--spout-name", default=None, help="nome Spout sender (default = --shm-name)")
    ap.add_argument("--fps",      type=int, default=0, help="FPS cap (0=unlimited)")
    ap.add_argument("--preview",  action="store_true",
                    help="apri finestra cv2 con l'output (no TD necessario)")
    ap.add_argument("--preview-scale", type=float, default=0.5,
                    help="fattore scala finestra preview (default 0.5)")
    ap.add_argument("--osc-port", type=int, default=54323,
                    help="porta OSC in ingresso (default 54323)")
    ap.add_argument("--no-osc", action="store_true",
                    help="non aprire l'ingresso OSC")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="indirizzo di bind per HTTP/WS/OSC (default 127.0.0.1)")
    args = ap.parse_args()

    w, h = args.width, args.height
    # `write_timestamp` fuori da un pass richiede anche inside-encoders:
    # senza, wgpu >= 0.31 fallisce la validazione a CommandEncoder.finish().
    required = (["timestamp-query", "timestamp-query-inside-encoders"]
                if args.profile else [])
    device = pick_igpu_amd(required_features=required)

    state = ShaderControlState(schema_path=args.schema)

    if not args.no_ui:
        ws_port = args.port + 1
        start_servers(state, http_port=args.port, ws_port=ws_port, bind=args.bind)

    # OSC e' un ingresso di controllo, non una UI: resta disponibile anche con
    # --no-ui, per pilotare da TD senza panel. Lo spegne solo --no-osc.
    if not args.no_osc:
        from control.osc_input import start_osc
        start_osc(state, port=args.osc_port, bind=args.bind)

    print(f"[wgsl-shm] building generator {w}x{h} shader={os.path.basename(args.shader)}")
    gen = AMDGenerator(
        device, w, h,
        shader_path=args.shader,
        uniform_size=UNIFORM_SIZE,
        workgroup=(16, 16),
        enable_profile=args.profile,
    )

    if args.out == "ndi":
        from ndi_sender import NdiSender
        n_str, d_str = args.ndi_fps.split("/")
        tx = NdiSender(
            short_name=args.ndi_name or args.shm_name,
            width=w, height=h,
            fps_n=int(n_str), fps_d=int(d_str),
        )
    elif args.out == "spout":
        from spout_sender import SpoutOut
        tx = SpoutOut(
            short_name=args.spout_name or args.shm_name,
            width=w, height=h,
        )
    else:
        tx = TopSharedMemSender(
            short_name=args.shm_name, width=w, height=h,
            pixel_format=TOP_FORMAT_R8G8B8A8_UNORM, bytes_per_pixel=4,
            global_ns=False,
        )

    total_mb = w * h * 4 / (1024 * 1024)
    print(f"[wgsl-shm] frame={total_mb:.1f}MB  |  profile={args.profile}  |  Ctrl+C per uscire\n")

    cv2 = None
    if args.preview:
        import cv2
        pw = max(1, int(w * args.preview_scale))
        ph = max(1, int(h * args.preview_scale))
        cv2.namedWindow(args.shm_name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(args.shm_name, pw, ph)
        print(f"[wgsl-shm] preview cv2 {pw}x{ph} (q/ESC per uscire)")

    shaders_dir = os.path.dirname(args.shader)
    current_shader_path = args.shader
    shader_mtime = os.path.getmtime(current_shader_path)
    # In live coding il generator gira su codice che non esiste su disco:
    # il watcher del file va staccato, o al primo mtime lo sovrascriverebbe.
    live_mode = False

    target_fps = args.fps
    frame_dt = 1.0 / target_fps if target_fps > 0 else 0.0

    t_start = time.perf_counter()
    fps_t   = time.perf_counter()
    # Il polling del mtime costa una syscall: a 500+ fps sarebbero centinaia
    # di stat() al secondo per un file che cambia quando salvi in editor.
    HOTRELOAD_POLL_S = 0.25
    next_mtime_poll = t_start + HOTRELOAD_POLL_S
    n = 0
    acc_render = acc_write = 0.0
    acc_dispatch = acc_copy = 0.0

    try:
        while True:
            frame_start = time.perf_counter()
            t_now = frame_start - t_start

            pending = state.pop_pending_shader()
            if pending:
                new_wgsl = os.path.join(shaders_dir, pending + ".wgsl")
                if os.path.exists(new_wgsl):
                    try:
                        with open(new_wgsl, "r", encoding="utf-8") as f:
                            code = f.read()
                        if gen.reload_shader(shader_code=code):
                            current_shader_path = new_wgsl
                            shader_mtime = os.path.getmtime(new_wgsl)
                            state.switch_schema(pending)
                            if live_mode:
                                live_mode = False
                                print("[live] rientro dai file su disco")
                            print(f"[shader-switch] -> {pending}: OK")
                        else:
                            print(f"[shader-switch] -> {pending}: compile FAILED, keeping old")
                    except Exception as e:
                        print(f"[shader-switch] -> {pending}: {e}")

            pending_code = state.pop_shader_code()
            if pending_code:
                code, client = pending_code
                try:
                    ok = gen.reload_shader(shader_code=code)
                    err = None if ok else gen.last_error
                except Exception as e:
                    ok, err = False, str(e)
                if ok and not live_mode:
                    live_mode = True
                    print("[live] codice da WS attivo: hot-reload da file sospeso")
                print(f"[live] shader_code: {'OK' if ok else 'FAILED (keep old)'}")
                notify_shader_result(client, ok, err)

            uni_bytes = state.snapshot_as_struct(
                UNIFORM_LAYOUT,
                extras={"time": t_now, "width": float(w), "height": float(h)},
            )
            gen.write_uniforms(uni_bytes)

            t0 = time.perf_counter()
            result = gen.render()
            t1 = time.perf_counter()

            if gen.profiling:
                frame, metrics = result
                acc_dispatch += metrics["dispatch_ms"]
                acc_copy     += metrics["copy_ms"]
            else:
                frame = result

            tx.write(frame)
            t2 = time.perf_counter()

            if cv2 is not None:
                small = cv2.resize(frame, (pw, ph), interpolation=cv2.INTER_AREA)
                bgr = cv2.cvtColor(small, cv2.COLOR_RGBA2BGR)
                cv2.imshow(args.shm_name, bgr)
                if cv2.waitKey(1) & 0xFF in (ord('q'), 27):
                    break

            if frame_dt > 0:
                work = t2 - frame_start
                if work < frame_dt:
                    time.sleep(frame_dt - work)

            acc_render += (t1 - t0) * 1000
            acc_write  += (t2 - t1) * 1000
            n += 1

            if n >= REPORT_N:
                elapsed = time.perf_counter() - fps_t
                fps = n / elapsed
                r = acc_render / n
                wr = acc_write / n
                if gen.profiling:
                    d = acc_dispatch / n
                    c = acc_copy / n
                    print(f"  {w}x{h}  fps={fps:5.1f}  "
                          f"gpu_dispatch={d:5.2f}  gpu_copy={c:5.2f}  "
                          f"host_render={r:5.2f}  host_write={wr:5.2f}  "
                          f"total={r+wr:5.2f}ms")
                else:
                    print(f"  {w}x{h}  fps={fps:5.1f}  render={r:5.2f}ms  "
                          f"write={wr:5.2f}ms  total={r+wr:5.2f}ms")
                n = 0
                acc_render = acc_write = acc_dispatch = acc_copy = 0.0
                fps_t = time.perf_counter()

            now = time.perf_counter()
            if not live_mode and now >= next_mtime_poll:
                next_mtime_poll = now + HOTRELOAD_POLL_S
                try:
                    m = os.path.getmtime(current_shader_path)
                except OSError:
                    m = shader_mtime
                if m != shader_mtime:
                    shader_mtime = m
                    if gen.reload_shader():
                        print(f"[hot-reload] {os.path.basename(current_shader_path)}: OK")
                    else:
                        print(f"[hot-reload] {os.path.basename(current_shader_path)}: FAILED (keep old)")

    except KeyboardInterrupt:
        print("\n[wgsl-shm] Ctrl+C.")
    finally:
        tx.close()
        if cv2 is not None:
            cv2.destroyAllWindows()
        print("[wgsl-shm] stop.")


if __name__ == "__main__":
    main()
