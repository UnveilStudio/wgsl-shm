# AGENTS.md

TL;DR for AI coding agents (Claude Code, Cursor, Copilot, …) picking up this repo.

## What this is

A single-file Python entry point (`wgsl_shm.py`) that:

1. picks the AMD integrated GPU via [`wgpu-py`](https://github.com/pygfx/wgpu-py),
2. compiles a WGSL compute shader from `shaders/*.wgsl`,
3. dispatches it every frame at the requested resolution (default 3840 × 2160),
4. reads the texture back into a numpy `(H, W, 4) uint8` RGBA array using a double-buffered staging path so GPU and CPU overlap,
5. ships the frame either to a TouchDesigner Shared Memory In TOP (`td_shm.py`, native UT_SharedMem protocol) **or** an NDI source (`ndi_sender.py`, ctypes wrapper around `Processing.NDI.Lib.x64.dll`),
6. serves an HTML / WebSocket control panel (`control/server.py` + `control/panel.html`) so a human in a browser can tweak the uniforms live.

This is **not** a pip-installable library. It's a runner. Clone, `pip install -r requirements.txt`, `python wgsl_shm.py`.

## Run it

```bash
git clone https://github.com/UnveilStudio/wgsl-shm.git
cd wgsl-shm
pip install -r requirements.txt
python wgsl_shm.py --preview          # cv2 window, no TD needed
python wgsl_shm.py                    # SHM → TouchDesigner
python wgsl_shm.py --out ndi          # NDI (needs NDI Runtime, see README)
```

Open http://127.0.0.1:54321/?ws=54322 in a browser for the control panel.

## Module map

| File | Role |
|---|---|
| `wgsl_shm.py` | CLI, main loop, FPS reporting, hot-reload, preview cv2 |
| `amd_generator.py` | `AMDGenerator`: wgpu compute pipeline + 2-staging-buffer readback |
| `td_shm.py` | `TopSharedMemSender`: `UT_SharedMem` protocol (Win32 file mapping + mutex + TD header v2) |
| `ndi_sender.py` | `NdiSender`: ctypes wrapper around libndi `NDIlib_send_*` |
| `control/server.py` | `ShaderControlState`, HTTP for `panel.html`, WebSocket for live params |
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
- **`cv2.waitKey(1)` cost**: on Windows the GUI pump is ~1-3 ms per frame even when idle. Adding `--preview` to a 4K pipeline drops fps from ~65 to ~30. Don't blame the shader.
- **Shader compile errors at hot-reload**: `AMDGenerator.reload_shader()` returns `False` and keeps the previous pipeline alive — the loop logs `[hot-reload] FAILED (keep old)` and keeps running. Look in stdout, not in the panel, for compile errors.
- **TD doesn't see the SHM**: TouchDesigner needs **Memory Name = `TOPamd`** and **Global = OFF**. The defaults in the SHM In TOP do *not* match.

## Don't touch

- `td_shm.py` — it's a clean-room Python implementation of the publicly documented `UT_SharedMem` / `TOP_SharedMemHeader` v2 wire format (header v2, Win32 mutex naming with the `4jhd783h` decoration, mapping size rules). Breaking the byte layout breaks every TD project that consumes the SHM.
- `amd_generator.py` row-pitch alignment (`((w * 4) + 255) & ~255`) — DX12 requires 256-byte aligned row pitch in `copy_texture_to_buffer`. Change it and AMD drivers will silently produce garbage.

## Tests

There's no formal test suite yet. The smoke check is:

```bash
python -c "import ast, glob; [ast.parse(open(p, encoding='utf-8').read()) for p in glob.glob('**/*.py', recursive=True)]"
python wgsl_shm.py --help
python wgsl_shm.py --preview --width 1280 --height 720    # 720p preview to validate the dataflow end-to-end
```

Contributions adding `tests/` are welcome — start with a headless `subprocess.Popen(['python', 'wgsl_shm.py', ...])` + a `td_shm` reader on the consumer side that asserts pixels are non-uniform.
