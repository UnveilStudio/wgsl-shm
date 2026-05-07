<p align="center">
  <img src="assets/banner.png" alt="wgsl-shm — Real-time WGSL compute shaders on AMD iGPU → SHM / NDI" width="100%" />
</p>

<p align="center">
  <img alt="Python" src="https://img.shields.io/badge/python-3.10%2B-3776AB?logo=python&logoColor=white">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Windows%20x64-0078D6?logo=windows">
  <img alt="GPU" src="https://img.shields.io/badge/gpu-wgpu--py-ff7f50?logo=webgpu&logoColor=white">
  <img alt="TouchDesigner" src="https://img.shields.io/badge/TouchDesigner-friendly-2bbc8a">
  <img alt="NDI Runtime" src="https://img.shields.io/badge/NDI%20Runtime-5%20%2F%206-5ac8e6">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
  <a href="AGENTS.md"><img alt="Agent-friendly" src="https://img.shields.io/badge/agent--friendly-yes-7c3aed"></a>
</p>

# wgsl-shm

> **Live performance, no compromise.**

Real-time **WGSL compute shaders** on **AMD integrated GPU** → **Shared Memory** (Win32, zero-copy) or **NDI**.
Built for AMD Ryzen AI 300 / Radeon 880M, runs on any AMD iGPU supported by [wgpu-py](https://github.com/pygfx/wgpu-py). 4K @ 60+ fps with a live HTML/WebSocket control panel and 16 included shaders.

The SHM transport is **byte-compatible with TouchDesigner's Shared Memory In TOP** (UT_SharedMem protocol), tested live — but any consumer that can map a Win32 file mapping can read the frames.

> Why? Cross-GPU shared textures (AMD → NVIDIA) don't work, and NDI eats 15-25% CPU. Local SHM is zero-copy on Windows and free.

## Built and tested on a hybrid AMD + NVIDIA performance laptop

Developed and benchmarked on a **[Razer Blade 14 (2025)](https://www.razer.com/gaming-laptops/razer-blade-14)** — a deliberate hybrid setup that exposes exactly what `wgsl-shm` is designed to exploit:

| Component | Role in the pipeline |
|---|---|
| **AMD Ryzen AI 9 365** (Zen 5 + XDNA2 NPU 50 TOPS) | CPU + the AMD APU that hosts the iGPU we run shaders on |
| **AMD Radeon 880M iGPU** | Compute target — runs every WGSL kernel, writes directly into system RAM |
| **NVIDIA GeForce RTX 5070 Laptop** (up to 115 W TGP) | Frees up downstream — TouchDesigner / Resolume compositing, ML inference, real-time encoding |
| **32 GB LPDDR5X-8000** (up to 64 GB) | Unified ultra-low-latency memory shared by CPU and iGPU — readback is essentially `memcpy` |

This combo is *the* sweet spot for **live performance with zero compromise**:

- The **AMD iGPU writes into the same LPDDR5X memory the CPU reads** — `dispatch + copy_texture_to_buffer` lands in system RAM, no PCIe round-trip, no cross-adapter sync. That's why we hit **4K @ 60+ fps with headroom to spare**.
- The **NVIDIA dGPU stays free** for the work it's actually best at — final compositing, generative models, encoding the show out to disk or to streaming. `wgsl-shm` never touches it.
- The **XDNA2 NPU** is available for whatever generative model you want to stack on top of the visuals (50 TOPS sitting idle is too good not to use).
- **LPDDR5X-8000 latency** is what makes the SHM hand-off vanishingly cheap — on a non-unified laptop you'd lose this entirely.

In short: you get **discrete-GPU-class compute on the iGPU for free**, the dGPU does what it's good at, and the system memory is fast enough that the bridge between them is a no-op. That's how you ship a live show without dropping frames.

> Same shader, same code, runs on **any AMD iGPU** that `wgpu-py` supports — but the Ryzen AI + LPDDR5X + dGPU combo is what makes `wgsl-shm` realistic for a touring live rig.

**Windows x64 only** at the moment (the SHM transport uses `CreateFileMappingW` + Win32 mutex). NDI output is optional.

## How it works

```mermaid
flowchart LR
    UI[HTML control panel<br/>browser @ 127.0.0.1:54321] -- WebSocket --> STATE[ShaderControlState<br/>uniforms + shader switch]
    STATE --> GEN[AMDGenerator<br/>wgpu compute pipeline]
    SHADER[shaders/*.wgsl<br/>16 included] -.hot reload.-> GEN
    GEN --> TEX[(rgba8unorm<br/>storage texture)]
    TEX --> RB[double-buffered<br/>staging readback]
    RB --> FRAME[numpy uint8<br/>H × W × 4 RGBA]
    FRAME --> SHM[td_shm<br/>UT_SharedMem protocol]
    FRAME --> NDI[ndi_sender<br/>libndi via ctypes]
    FRAME --> CV2[cv2 preview<br/>--preview]
    SHM -.-> TD[TouchDesigner<br/>Shared Memory In TOP]
    NDI -.-> EXT[OBS / Resolume / vMix /<br/>any NDI receiver on LAN]

    classDef py fill:#0e2233,stroke:#5ac8e6,stroke-width:2px,color:#fff
    classDef gpu fill:#3a1a5c,stroke:#aa6eff,stroke-width:2px,color:#fff
    classDef sys fill:#0d1117,stroke:#444,color:#fff
    class UI,STATE,GEN,RB,FRAME,SHM,NDI,CV2 py
    class TEX gpu
    class TD,EXT sys
```

Compute shaders run **on the iGPU** (system RAM, no PCIe round-trip), readback uses two persistent staging buffers so GPU and CPU overlap (frame N writes while frame N-1 reads). The HTML panel pushes uniforms over WebSocket — slider tweaks land within a frame.

## Agent-friendly

Designed to be picked up by AI coding agents (Claude Code, Cursor, Copilot, …) on the first try without spelunking the source:

- [`AGENTS.md`](AGENTS.md) — TL;DR + how to add a shader, run pipeline, common pitfalls.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module map, frame data model, uniform layout convention, SHM protocol cross-checked against TouchDesigner's `UT_SharedMem`.

## Install

```bash
git clone https://github.com/UnveilStudio/wgsl-shm.git
cd wgsl-shm
pip install -r requirements.txt
```

Optional extras:

```bash
pip install opencv-python      # for --preview (cv2 window)
```

## Quick start

```bash
python wgsl_shm.py --preview
```

`--preview` opens a local cv2 window so you can see the output without TouchDesigner. The HTML control panel is served at **http://127.0.0.1:54321/?ws=54322** — open it in any browser to tweak the live shader uniforms.

For a downstream consumer (TouchDesigner shown here, but anything that maps a Win32 file mapping works):

```bash
python wgsl_shm.py
```

In TouchDesigner add a **Shared Memory In TOP**:

| Parameter | Value |
|---|---|
| Memory Name | `TOPamd` |
| Global | OFF |

That's it — the TOP shows your shader at native resolution, zero-copy.

## CLI

```
--shader PATH         WGSL to load (default shaders/plasma.wgsl)
--schema PATH         JSON schema of parameters exposed to the panel
--width / --height    output resolution (default 3840 × 2160)
--fps N               cap fps (0 = unlimited)
--profile             GPU dispatch / copy timestamps
--no-ui               disable HTTP / WS server
--port N              HTTP port (WS = port + 1)
--shm-name NAME       SHM name for TD (default TOPamd)
--out shm | ndi       transport (default shm)
--ndi-name NAME       NDI source name (default = --shm-name)
--ndi-fps N/D         declared NDI frame rate (default 60/1)
--preview             local cv2 window
--preview-scale F     preview window scale (default 0.5 = 1080p on 4K)
```

Hot reload: save any `shaders/*.wgsl` file, the pipeline recompiles without restart.
Shader switch live: dropdown in the HTML panel.

## Included shaders

| | | | |
|---|---|---|---|
| `plasma` | `voronoi` | `truchet` | `kaleido` |
| `ripple` | `flowfield` | `tunnel` | `nebula` |
| `particles` | `galaxy` | `fractal` | `electric` |
| `raymarch` | `blackhole` | `fluid` | `sinewave` |

Add a new one: drop `myshader.wgsl` + `myshader.json` (parameter schema) into `shaders/` and run:

```bash
python wgsl_shm.py --shader shaders/myshader.wgsl --schema shaders/myshader.json
```

## NDI output (proprietary DLL required)

`--out ndi` uses the **NDI Runtime/SDK** by NewTek/Vizrt. The DLL is **closed-source proprietary** — it cannot be redistributed in this repo. You install it once, free of charge:

1. Go to **https://ndi.video/download-ndi-sdk/**
2. Download and install **"NDI 6 Tools"** (or "NDI 5/6 Runtime" if you only need to run NDI clients)
3. The installer drops `Processing.NDI.Lib.x64.dll` in:

   ```
   C:\Program Files\NDI\NDI 6 SDK\Bin\x64\
   ```

   (or `NDI 5 Runtime\v5\`, or the `Bin\` folder of TouchDesigner). `ndi_sender.py` auto-detects the standard locations and honours `NDI_RUNTIME_DIR_V6` / `NDI_RUNTIME_DIR_V5`.

If you `--out ndi` without the runtime installed you get a clear error pointing back here.

> ⚠️ The NDI DLL is **not** MIT — it has its own EULA. This repo is MIT only for the original code. If you redistribute builds of this project, **do not** include the DLL — users have to install it themselves.

## Performance notes

- **Resolution**: 4K @ 60+ fps on Radeon 880M with the included shaders. Raymarch / fluid drop to ~30 fps depending on iteration count.
- **Preview cost**: `--preview` adds ~5 ms / frame for the cv2 imshow GUI thread on Windows. Headless (default) is faster.
- **`--profile`**: prints separate dispatch / copy ms via WGPU timestamp queries. Useful when authoring a new shader to see whether you're compute-bound or readback-bound.
- **Workgroup size**: shaders default to `(16, 16)`. Override the `workgroup` kwarg in `AMDGenerator(...)` if a particular kernel prefers another layout.

## Hardware / software requirements

- **GPU**: AMD iGPU (tested on Radeon 880M). Discrete AMD also works but the package explicitly picks the integrated one — edit `pick_igpu_amd()` in `wgsl_shm.py` for other targets.
- **OS**: Windows. Linux/macOS need a port of `td_shm.py` (TD SHM is Win32-specific).
- **Python**: 3.10+
- **TouchDesigner**: optional — only needed to consume the SHM. 2023.x+ recommended.

## Repo layout

```
wgsl-shm/
├── wgsl_shm.py          # entry point CLI
├── amd_generator.py     # compute shader pipeline + double-buffered readback
├── td_shm.py            # Shared Memory In TOP protocol (UT_SharedMem)
├── ndi_sender.py        # NDI sender via libndi (DLL not bundled)
├── control/
│   ├── server.py        # HTTP + WebSocket control panel
│   └── panel.html       # browser UI
├── shaders/             # 16 .wgsl + matching .json schemas
├── docs/ARCHITECTURE.md # module map, dataflow, formats
├── AGENTS.md            # TL;DR for AI coding agents
└── requirements.txt
```

## Built on top of

- **[wgpu-py](https://github.com/pygfx/wgpu-py)** by Almar Klein et al. — the WebGPU Python bindings doing the heavy lifting (compute pipeline, buffer mapping, validation). BSD-2.

`td_shm.py` is a clean-room Python implementation of the publicly documented `UT_SharedMem` wire format used by TouchDesigner's Shared Memory In TOP. No proprietary Derivative source code was used or referenced — only the protocol shape, which is the explicit contract any third-party producer must implement.

## Support this project

If `wgsl-shm` saves you time or makes its way into something cool, you can throw a beer 🍺 at the maintainer:

- 🟧 **Patreon** — [patreon.com/unveil_studio](https://www.patreon.com/unveil_studio)
- 💸 **PayPal** — [paypal.me/Unveilstudio](https://paypal.me/Unveilstudio)

Every tip is genuinely appreciated and goes straight into keeping this and similar tools alive.

## License

This project is released under the **MIT License** — see [`LICENSE`](LICENSE).

Third-party components have their own licences:

- [`wgpu-py`](https://github.com/pygfx/wgpu-py) — BSD-2
- `numpy`, `websockets` — BSD-3 / MIT
- `opencv-python` (optional, only for `--preview`) — Apache 2.0
- **NDI Runtime** (optional, only for `--out ndi`) — proprietary EULA by **Vizrt** / NewTek; not part of this project, see the section above. NDI® is a registered trademark of Vizrt Group.
