"""
spout_sender.py — Spout transport for wgsl-shm.

Drop-in compatible with the .write(frame)/.close() API used by td_shm.py and
ndi_sender.py, so the main loop is transport-agnostic.

Why Spout: TouchDesigner's Shared Memory In TOP isn't available in TD
Non-Commercial, but `Spout In TOP` is. Spout also gives Resolume / OBS /
Notch / Magic / vMix native zero-copy GPU sharing on Windows.

Cost model:
- CPU side: zero copies. We pass the numpy buffer directly via
  `ctypes.data_as(POINTER(c_ubyte))` — Spout reads from our memory.
- GPU side: SpoutLibrary uploads the CPU buffer into a DX11 shared texture
  internally (it has to — Spout shares DX11 NT handles, not memory). That
  upload + GL/DX11 interop costs about 2 ms at 4K headless on a Radeon
  880M (Win11, recent AMD drivers) and is inherent to the protocol; we
  cannot remove it without making wgpu render directly into a DX11 texture
  and doing a native wgpu↔DX11 interop, which wgpu-py does not currently
  expose.

Trade-off: SHM stays the fastest path (zero overhead, system RAM only).
Spout is for receivers that don't speak SHM (TD Non-Commercial, OBS,
Resolume, Notch, Magic, vMix, Unreal/Unity).

Input frame: np.ndarray uint8, shape (h, w, 4), RGBA byte order — matches
what wgpu's rgba8unorm produces.

Install (one-shot):
    pip install git+https://github.com/UnveilStudio/SPOUT2ForPython.git
"""
from __future__ import annotations

import ctypes

import numpy as np


class SpoutOut:
    """Spout sender wrapping UnveilStudio/SPOUT2ForPython."""

    def __init__(self, short_name: str, width: int, height: int):
        try:
            from spout import SpoutSender
            from spout._lib import GL_RGBA
        except ImportError as exc:
            raise ImportError(
                "spout package not installed. Install with:\n"
                "  pip install git+https://github.com/UnveilStudio/SPOUT2ForPython.git"
            ) from exc

        self.name = short_name
        self.w, self.h = width, height
        self._GL_RGBA = GL_RGBA

        sender = SpoutSender(short_name)
        sender.__enter__()
        try:
            sender.create_opengl()
        except Exception:
            sender.__exit__(None, None, None)
            raise
        self._sender = sender

        print(f"[spout] SENDER '{short_name}'  {width}x{height}  RGBA")

    def write(self, frame_rgba: np.ndarray):
        if not frame_rgba.flags["C_CONTIGUOUS"]:
            frame_rgba = np.ascontiguousarray(frame_rgba)
        ptr = frame_rgba.ctypes.data_as(ctypes.POINTER(ctypes.c_ubyte))
        self._sender.send_image(ptr, self.w, self.h, self._GL_RGBA)

    def close(self):
        try:
            self._sender.close_opengl()
        except Exception:
            pass
        try:
            self._sender.__exit__(None, None, None)
        except Exception:
            pass
        print("[spout] SENDER closed.")
