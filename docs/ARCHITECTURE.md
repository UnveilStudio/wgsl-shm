# Architecture

Cross-checked against the source: `wgsl_shm.py`, `amd_generator.py`, `td_shm.py`, `ndi_sender.py`, `control/server.py`. Read this with the code open in another tab.

## Process model

Single Python process. Three logical components running cooperatively in the same event loop:

```
                ┌────────────────────────────────────────────────┐
   browser ◄─── │  threading: HTTP + WebSocket (control/server)   │
                │  asyncio inside threads, daemonised             │
                └────────────────────────────────────────────────┘
                                  ▼  ShaderControlState (shared, lock-protected)
                ┌────────────────────────────────────────────────┐
   main loop:   │  uniforms snapshot → AMDGenerator.render()      │
   wgsl_shm.py  │  → tx.write(frame)                              │
                │  → optional cv2.imshow (--preview)              │
                │  → fps cap → loop                               │
                └────────────────────────────────────────────────┘
                                  ▼
                ┌────────────────────────────────────────────────┐
                │  AMDGenerator (wgpu device, iGPU AMD)           │
                │  compute pipeline + 2-staging readback          │
                │  optional timestamp query set (--profile)       │
                └────────────────────────────────────────────────┘
```

The HTTP/WS thread is daemonised; `Ctrl+C` in the main loop tears everything down through the `finally:` block (closes the SHM / NDI sender, destroys cv2 windows).

## Render loop (per frame)

1. **Pop pending shader switch** from the panel queue. If a new `shaders/<name>.wgsl` is requested, recompile in place via `AMDGenerator.reload_shader(code)`. On compile failure the previous pipeline stays alive.
2. **Snapshot uniform state** (`ShaderControlState.snapshot_as_struct(UNIFORM_LAYOUT, extras={time, width, height})`) → 80-byte struct matching the WGSL `Uniforms` block. Written to the GPU via `device.queue.write_buffer(uni_buf, 0, data)`.
3. **Dispatch** `(W/16) × (H/16)` workgroups (default `(16, 16)` per shader).
4. **Copy texture → staging[write_idx]** (DX12 row-pitch aligned to 256 bytes).
5. **Map and read staging[read_idx]** = the *previous* frame's buffer. First iteration is special-cased: maps `staging[write_idx]` synchronously (no overlap on frame 0).
6. **Swap indices** (`write_idx ^= 1`), so frame N+1's GPU work targets the buffer the CPU just released.
7. **`tx.write(frame)`** — SHM write or NDI send. SHM writer holds the per-mapping mutex for the duration of the `memcpy`.
8. **Optional cv2 preview** — `cv2.resize` first (smaller GUI frame), then `cvtColor RGBA→BGR`, then `imshow + waitKey(1)`.
9. **Frame cap** — single `time.sleep(frame_dt - work)` if `--fps` was set.

The double-buffered staging is the entire reason this hits 60+ fps at 4K — without it, mapping the buffer right after `submit()` blocks the CPU until the GPU finishes copying, pushing latency over a frame.

## SHM protocol (`td_shm.py`)

Clean-room Python implementation of the publicly documented TouchDesigner `UT_SharedMem` + `TOP_SharedMemHeader` v2 wire format. We did not copy or derive from any proprietary Derivative source code — only the protocol shape is reused, since it's the explicit contract any external app must implement to talk to a Shared Memory In TOP:

- **Two Win32 file mappings** with a fixed naming scheme:

  ```
  data:  TouchSHM<short>          (W × H × bpp + 4 KiB header padding)
  info:  TouchSHM<short>4jhd783h  (76 B fixed)
  ```

  The `4jhd783h` decoration is what TD uses internally — it's the mtag that disambiguates info from data when both live in the same name space.

- **One Win32 mutex per mapping** (suffix `Mutex`).
- **Header v2** at offset 0 of the data mapping: magic, version, width, height, format, image-size, pad. Layout matches TD 2025.32280 (cross-checked against `Samples/SharedMem/TOP/TOP_SharedMemHeader.h`).
- **Global flag**: prefixing names with `Global\` lets cross-session writes — we keep `Global = OFF` so naming stays scoped to the current Windows session, matching TD's default.

The TOP on the TD side configured with `Memory Name = TOPamd, Global = OFF` reads exactly this layout. There is no synchronisation beyond the mutex around the `memcpy` — TD polls the header version counter on each cook.

## NDI protocol (`ndi_sender.py`)

`Processing.NDI.Lib.x64.dll` exposes a flat C ABI. We bind the subset we need via ctypes:

- `NDIlib_initialize`, `NDIlib_destroy`
- `NDIlib_send_create_v2(NDIlib_send_create_t*)` → opaque sender handle
- `NDIlib_send_send_video_v2(handle, NDIlib_video_frame_v2_t*)` — synchronous send (returns when NDI has copied the buffer)
- `NDIlib_send_destroy(handle)`

`NDIlib_video_frame_v2_t` is reproduced as a ctypes `Structure`: xres, yres, FourCC (`'RGBA'` packed little-endian = `0x41424752`), frame-rate as numerator/denominator, `picture_aspect_ratio` (0 = derive from xres/yres), `frame_format_type` (1 = progressive), timecode, `p_data` (frame pointer), `line_stride_in_bytes` (= W×4 since we ship contiguous RGBA), timestamp, `p_metadata`.

The `_StrideUnion` anonymous union mirrors NDI's two interpretations of the same field — for `BGRA`/`RGBA` we use `line_stride_in_bytes`. Compressed formats (UYVY, etc.) repurpose it as `data_size_in_bytes`.

Everything happens in-process; NDI runs an internal worker thread that handles mDNS announcement and the actual UDP send.

## Control panel

`control/server.py` runs two servers in daemon threads:

- **HTTP** (default 54321): serves `panel.html` and the JSON schema of the current shader.
- **WebSocket** (default 54322): bidirectional. Browser → state updates per parameter (`{"name": "scale", "value": 1.7}`). State → browser broadcasts (e.g. shader switch confirmation).

`ShaderControlState` is the shared object. It's lock-protected; `snapshot_as_struct(layout, extras)` returns a fresh `bytes` packed in the order the shader's `Uniforms` block expects. The schema JSON drives both the panel UI and the layout — keep them in sync when adding a parameter.

Shader switch is a pop-once queue: the main loop calls `state.pop_pending_shader()` per frame, returns `None` when nothing is pending.

## Frame format conventions

| Surface | Format | Layout | Notes |
|---|---|---|---|
| WGSL storage texture | `rgba8unorm` | (H, W) of `vec4<f32>` (write-only) | sRGB-naive — no automatic gamma |
| Readback ndarray | `np.uint8` | `(H, W, 4)` contiguous | RGBA byte order |
| SHM payload | `R8G8B8A8_UNORM` | row-major `H × W × 4` bytes | same memory the ndarray points at |
| NDI frame | FourCC `RGBA` | row-major, stride = `W × 4` | NDI accepts BGRA/UYVY too — we just pick RGBA |
| cv2 preview | BGR (after `cvtColor`) | `(ph, pw, 3)` | resize first to keep the GUI thread cheap |

## Performance characteristics

Numbers below are 4K (3840 × 2160), Radeon 880M, plasma shader, no preview, no fps cap, measured with `--profile`:

| Stage | Time |
|---|---|
| GPU compute dispatch | ~2 ms |
| GPU texture → staging copy | ~3 ms |
| CPU map + memcpy from staging | ~7 ms |
| `tx.write` (SHM mutex + memcpy) | ~2 ms |
| **Frame total (no preview)** | **~14 ms ≈ 65 fps** |
| `--preview` cv2 overhead | +5 ms |
| `--out ndi` instead of SHM | +3 ms |

Compute-heavy shaders (raymarch, fluid) push GPU dispatch to 10-20 ms — readback and SHM stay flat.

## Why iGPU and not the dGPU

This is *the* point of the project: cross-adapter shared textures (AMD ↔ NVIDIA) don't work on Windows, and even if they did, the round-trip from a discrete GPU through PCIe back into TD's NVIDIA context costs more than rendering the same shader on the iGPU and shipping bytes via SHM (the iGPU has direct system-RAM access, so the readback is essentially `memcpy`). On a hybrid AMD + NVIDIA laptop, generating visuals on the iGPU is *free* compute that the dGPU doesn't have to do.

## Future / non-goals

- **Linux/macOS port**: feasible. `td_shm.py` is the only Win32-specific module. Spout (Windows GPU sharing) and Syphon (macOS) would replace SHM on those platforms — different protocol, similar shape.
- **Discrete GPU support**: trivial — change `pick_igpu_amd()`'s filter. Discouraged for the SHM use case (PCIe round-trip kills the latency win) but fine for NDI output.
- **WebGPU browser frontend**: not planned. The point of `wgsl-shm` is to hand the frame off to a *downstream* renderer/compositor (TouchDesigner being the most common one tested) via zero-copy SHM or NDI. Rendering inside a browser would replace that consumer instead of feeding it.
