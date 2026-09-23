# AGENTS.md

TL;DR for AI coding agents (Claude Code, Cursor, Copilot, …) picking up this repo.

## What this is

A single-file Python entry point (`wgsl_shm.py`) that:

1. picks the AMD integrated GPU via [`wgpu-py`](https://github.com/pygfx/wgpu-py),
2. compiles a WGSL compute shader from `shaders/*.wgsl`,
3. dispatches it every frame at the requested resolution (default 3840 × 2160),
4. reads the texture back into a numpy `(H, W, 4) uint8` RGBA array using a double-buffered staging path so GPU and CPU overlap,
5. ships the frame to one of three transports — `td_shm.py` (Win32 file mapping, UT_SharedMem wire format), `spout_sender.py` (DX11 GPU sharing via `UnveilStudio/SPOUT2ForPython`), or `ndi_sender.py` (LAN streaming via `Processing.NDI.Lib.x64.dll`),
6. serves an HTML / WebSocket control panel (`control/server.py` + `control/panel.html`) so a human in a browser can tweak the uniforms live,
7. accepts **OSC** (`control/osc_input.py`) and **WebSocket** input so TouchDesigner can drive the parameters and hot-ship WGSL source for live coding (see `docs/TOUCHDESIGNER.md`).

This is **not** a pip-installable library. It's a runner. Clone, `pip install -r requirements.txt`, `python wgsl_shm.py`.

## Run it

```bash
git clone https://github.com/UnveilStudio/wgsl-shm.git
cd wgsl-shm
pip install -r requirements.txt
python wgsl_shm.py --preview          # cv2 window, no consumer needed
python wgsl_shm.py                    # SHM → TouchDesigner Pro (default)
python wgsl_shm.py --out spout        # Spout → TD Non-Commercial / OBS / Resolume / ...
python wgsl_shm.py --out ndi          # NDI (needs NDI Runtime, see README)
```

Open http://127.0.0.1:54321/?ws=54322 in a browser for the control panel.

## Module map

| File | Role |
|---|---|
| `wgsl_shm.py` | CLI, main loop, FPS reporting, hot-reload, preview cv2 |
| `amd_generator.py` | `AMDGenerator`: wgpu compute pipeline + 2-staging-buffer readback |
| `td_shm.py` | `TopSharedMemSender`: `UT_SharedMem` protocol (Win32 file mapping + mutex + TD header v2) |
| `spout_sender.py` | `SpoutOut`: thin wrapper around `UnveilStudio/SPOUT2ForPython`. Lazy-imports `spout`. Pre-creates a hidden GL context (`create_opengl()`) so the script can run headless. |
| `ndi_sender.py` | `NdiSender`: ctypes wrapper around libndi `NDIlib_send_*` |
| `control/server.py` | `ShaderControlState`, HTTP for `panel.html`, WebSocket for live params + live-coding source |
| `control/osc_input.py` | OSC input server. OSC address = parameter name (matches TD's OSC Out CHOP) |
| `control/panel.html` | Browser UI — sliders / colors / shader dropdown |
| `shaders/<name>.wgsl` | Compute shader, `@compute @workgroup_size(16,16)` writing to `texture_storage_2d<rgba8unorm, write>` |
| `shaders/<name>.json` | Schema for the panel: parameter names, types (f32/vec3), default values, ranges |

## Add a new shader

1. Drop `shaders/myshader.wgsl` and `shaders/myshader.json` into `shaders/`. Use one of the existing pairs as a template.
2. WGSL contract: bind group 0 has binding 0 = `Uniforms` (uniform buffer, ≤ 80 bytes), binding 1 = `texture_storage_2d<rgba8unorm, write>`. Entry point must be named `main`.
3. JSON contract: array of `{name, type, default, min, max}` describing the slider widgets the panel should generate. The order matches `UNIFORM_LAYOUT` in `wgsl_shm.py:46-63`.
4. Run `python wgsl_shm.py --shader shaders/myshader.wgsl --schema shaders/myshader.json`. Hot reload picks up file edits without restart.

## Frame data model

- Shader writes RGBA, 8-bit per channel, sRGB-naive (no automatic gamma).
- Readback: numpy `np.uint8`, shape `(H, W, 4)`, layout `RGBA`, contiguous.
- For cv2 / display: convert to BGR (`cv2.cvtColor(frame, cv2.COLOR_RGBA2BGR)`) — the entry-point code does this only when `--preview` is on, and resizes first to keep the GUI thread cheap.
- TD SHM consumes RGBA8 directly; NDI sender re-tags it as `FOURCC_RGBA` so no conversion happens.

## Common pitfalls

- **Wrong adapter picked**: `pick_igpu_amd()` in `wgsl_shm.py` hard-filters for `AMD` + `IntegratedGPU`. On a system without an AMD iGPU it raises `RuntimeError`. Edit the filter for other targets.
- **NDI DLL not found**: `--out ndi` fails clearly if `Processing.NDI.Lib.x64.dll` is not in PATH. Either install the NDI Runtime (see README) or copy the DLL next to `wgsl_shm.py`.
- **Spout package not installed**: `--out spout` raises `ImportError` pointing at `pip install git+https://github.com/UnveilStudio/SPOUT2ForPython.git`. The DLL is bundled in that package — no separate runtime install.
- **Spout GPU upload cost**: SpoutLibrary uploads the CPU buffer into a DX11 shared texture per frame (~3-5 ms at 4K). This is inherent to the protocol — Spout shares NT handles, not RAM. The CPU-side copy is already zero (we pass the numpy buffer pointer with `ctypes.data_as`).
- **`cv2.waitKey(1)` cost**: on Windows the GUI pump is ~1-3 ms per frame even when idle. Adding `--preview` to a 4K pipeline drops fps from ~65 to ~30. Don't blame the shader.
- **Shader compile errors at hot-reload**: `AMDGenerator.reload_shader()` returns `False` and keeps the previous pipeline alive — the loop logs `[hot-reload] FAILED (keep old)` and keeps running. Look in stdout, not in the panel, for compile errors.
- **TD doesn't see the SHM**: TouchDesigner needs **Memory Name = `TOPamd`** and **Global = OFF**. The defaults in the SHM In TOP do *not* match.
- **A slider in the panel won't move**: something is driving that parameter over OSC/WS. It re-enables 2 s after the external source goes quiet. This is by design, not a UI bug.
- **Edits to a `.wgsl` file do nothing**: you are in live mode — source arrived over the WS and the file watcher is suspended. Switch shader from the panel to go back to disk. The transition is logged (`[live] ...`).
- **`--profile` needs two features**, `timestamp-query` *and* `timestamp-query-inside-encoders`; without the second, wgpu ≥ 0.31 fails validation at `CommandEncoder.finish()`. `AMDGenerator.profiling` (not the CLI flag) tells you whether `render()` actually returns metrics.
- **Non-ASCII in `print()` kills the process** on a cp1252 console (`UnicodeEncodeError` before anything renders). Keep runtime output ASCII.

## Don't touch

- `td_shm.py` — it's a clean-room Python implementation of the publicly documented `UT_SharedMem` / `TOP_SharedMemHeader` v2 wire format (header v2, Win32 mutex naming with the `4jhd783h` decoration, mapping size rules). Breaking the byte layout breaks every TD project that consumes the SHM.
- `amd_generator.py` row-pitch alignment (`((w * 4) + 255) & ~255`) — DX12 requires 256-byte aligned row pitch in `copy_texture_to_buffer`. Change it and AMD drivers will silently produce garbage.

## Control plane

Three inputs write into the same `ShaderControlState`: the browser panel (WS),
OSC, and external WS clients. Last writer wins — deliberately. The main loop's
once-per-frame `snapshot_as_struct()` under lock is already the serialisation
point, so no arbiter was added.

- `set_value(name, value, source=...)` records provenance; `external_locks()`
  lists parameters written by `osc`/`ws` in the last 2 s. The server broadcasts
  that set and the panel disables those sliders.
- The panel announces itself with `{"type":"hello","client":"panel"}` — without
  it, it would count as an external source and disable its own sliders.
- `{"type":"shader_code","code":...}` compiles **in the main loop** (never in the
  WS thread — building a wgpu pipeline off-thread while the loop renders is not
  safe) and replies `{"type":"shader_result","ok":...,"error":...}` to the sender.
- The first `shader_code` suspends the file mtime watcher (**live mode**), else
  the next file poll would silently overwrite code that has no file on disk.
  `change_shader` restores it.
- `switch_schema()` **keeps** parameter values across shader switches, clamped to
  the new schema's ranges (they genuinely differ: `scale` `(0.2, 6.0)` vs
  `(1.0, 20.0)`, `octaves` `(1, 4)` vs `(3, 12)`).

## Tests

`tests/test_control_state.py` covers the GPU-free logic: clamping and value
preservation across shader switches, slider-lock expiry (injectable clock), and
OSC argument parsing.

```bash
python -m pytest tests/ -q
```

Everything else still needs the GPU and is verified by running. The smoke check is:

```bash
python -c "import ast, glob; [ast.parse(open(p, encoding='utf-8').read()) for p in glob.glob('**/*.py', recursive=True)]"
python wgsl_shm.py --help
python wgsl_shm.py --preview --width 1280 --height 720    # 720p preview to validate the dataflow end-to-end
```

Still missing and welcome: a `td_shm` reader on the consumer side asserting the
pixels are non-uniform, and coverage of the transports.
