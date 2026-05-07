"""
ndi_sender.py — NDIlib sender via ctypes.

Carica Processing.NDI.Lib.x64.dll bundled con TouchDesigner e espone
un'API .write(frame)/.close() identica a TopSharedMemSender così può
sostituirlo drop-in in 05_amd_4k_out.py.

Input frame atteso: np.ndarray uint8 contigua, shape (h, w, 4), formato RGBA
(stesso layout che wgpu produce con rgba8unorm).
"""
import ctypes
import os
from ctypes import (
    POINTER, Structure, Union, byref, c_bool, c_char_p, c_float,
    c_int, c_int64, c_uint8, c_void_p,
)

import numpy as np


# FourCC packed little-endian: i 4 byte in memoria sono R,G,B,A
FOURCC_RGBA = 0x41424752  # bytes: 'R','G','B','A'
FOURCC_BGRA = 0x41524742
FRAME_FORMAT_PROGRESSIVE = 1


class _SendCreate(Structure):
    _fields_ = [
        ("p_ndi_name",  c_char_p),
        ("p_groups",    c_char_p),
        ("clock_video", c_bool),
        ("clock_audio", c_bool),
    ]


class _StrideUnion(Union):
    _fields_ = [
        ("line_stride_in_bytes", c_int),
        ("data_size_in_bytes",   c_int),
    ]


class _VideoFrameV2(Structure):
    _anonymous_ = ("_u",)
    _fields_ = [
        ("xres",                 c_int),
        ("yres",                 c_int),
        ("FourCC",               c_int),
        ("frame_rate_N",         c_int),
        ("frame_rate_D",         c_int),
        ("picture_aspect_ratio", c_float),
        ("frame_format_type",    c_int),
        ("timecode",             c_int64),
        ("p_data",               POINTER(c_uint8)),
        ("_u",                   _StrideUnion),
        ("p_metadata",           c_char_p),
        ("timestamp",            c_int64),
    ]


def _find_ndi_dll() -> str:
    env = os.environ.get("NDI_RUNTIME_DIR_V5") or os.environ.get("NDI_RUNTIME_DIR_V4")
    candidates = []
    if env:
        candidates.append(os.path.join(env, "Processing.NDI.Lib.x64.dll"))
    for root in [
        r"C:\Program Files\Derivative\TouchDesigner\bin",
        r"C:\Program Files\Derivative\TouchDesigner.2025.32280\bin",
        r"C:\Program Files\Derivative\TouchDesigner.2023.12600\bin",
        r"C:\Program Files\NDI\NDI 5 Runtime\v5",
        r"C:\Program Files\NDI\NDI 6 Runtime\v6",
    ]:
        candidates.append(os.path.join(root, "Processing.NDI.Lib.x64.dll"))
    for p in candidates:
        if os.path.exists(p):
            return p
    raise RuntimeError("Processing.NDI.Lib.x64.dll non trovata")


_dll: ctypes.CDLL | None = None
_dll_path: str | None = None


def _load_dll() -> ctypes.CDLL:
    global _dll, _dll_path
    if _dll is not None:
        return _dll
    _dll_path = _find_ndi_dll()
    dll_dir = os.path.dirname(_dll_path)
    # Windows: garantire che dipendenze della DLL siano risolvibili
    try:
        os.add_dll_directory(dll_dir)
    except (AttributeError, FileNotFoundError):
        pass
    dll = ctypes.CDLL(_dll_path)

    dll.NDIlib_initialize.restype = c_bool
    dll.NDIlib_initialize.argtypes = []

    dll.NDIlib_destroy.restype = None
    dll.NDIlib_destroy.argtypes = []

    dll.NDIlib_send_create.restype  = c_void_p
    dll.NDIlib_send_create.argtypes = [POINTER(_SendCreate)]

    dll.NDIlib_send_destroy.restype  = None
    dll.NDIlib_send_destroy.argtypes = [c_void_p]

    dll.NDIlib_send_send_video_v2.restype  = None
    dll.NDIlib_send_send_video_v2.argtypes = [c_void_p, POINTER(_VideoFrameV2)]

    dll.NDIlib_send_send_video_async_v2.restype  = None
    dll.NDIlib_send_send_video_async_v2.argtypes = [c_void_p, POINTER(_VideoFrameV2)]

    if not dll.NDIlib_initialize():
        raise RuntimeError("NDIlib_initialize() fallita (CPU senza SSSE3?)")

    _dll = dll
    return dll


class NdiSender:
    """Drop-in per TopSharedMemSender: .write(frame) / .close()."""

    def __init__(self, short_name: str, width: int, height: int,
                 fps_n: int = 60, fps_d: int = 1,
                 fourcc: int = FOURCC_RGBA, async_send: bool = True):
        dll = _load_dll()
        self._dll = dll
        self._name   = short_name
        self._w      = width
        self._h      = height
        self._stride = width * 4
        self._async  = async_send

        cfg = _SendCreate(
            p_ndi_name  = short_name.encode("utf-8"),
            p_groups    = None,
            clock_video = False,
            clock_audio = False,
        )
        self._sender = dll.NDIlib_send_create(byref(cfg))
        if not self._sender:
            raise RuntimeError(f"NDIlib_send_create('{short_name}') ha fallito")

        self._frame = _VideoFrameV2(
            xres                 = width,
            yres                 = height,
            FourCC               = fourcc,
            frame_rate_N         = fps_n,
            frame_rate_D         = fps_d,
            picture_aspect_ratio = width / height,
            frame_format_type    = FRAME_FORMAT_PROGRESSIVE,
            timecode             = 0,
            p_data               = ctypes.cast(0, POINTER(c_uint8)),
            p_metadata           = None,
            timestamp            = 0,
        )
        self._frame.line_stride_in_bytes = self._stride

        # Double buffer per async send: la DLL è autorizzata a leggere
        # il puntatore del frame precedente finché non chiamiamo la
        # prossima send_async. Tenere 2 buffer alternati evita tearing.
        self._buffers = [np.empty((height, width, 4), dtype=np.uint8),
                         np.empty((height, width, 4), dtype=np.uint8)]
        self._buf_idx = 0
        self._last_ptr_keep = None  # ref anti-GC per il numpy in volo

        print(f"[ndi] SENDER '{short_name}'  {width}x{height} @ {fps_n}/{fps_d}  "
              f"async={async_send}  dll={_dll_path}")

    def write(self, frame) -> bool:
        """frame = np.ndarray uint8 contigua RGBA. Ritorna sempre True."""
        if self._async:
            # copia nel back buffer (zero-copy end-to-end non è possibile con
            # wgpu che ci restituisce _out_arr riusato a ogni frame).
            buf = self._buffers[self._buf_idx]
            if frame.shape != buf.shape or frame.dtype != np.uint8:
                # fallback lento (shape mismatch) — non dovrebbe mai capitare
                buf = np.ascontiguousarray(frame, dtype=np.uint8).reshape(self._h, self._w, 4)
                self._buffers[self._buf_idx] = buf
            else:
                np.copyto(buf, frame)
            self._frame.p_data = buf.ctypes.data_as(POINTER(c_uint8))
            self._dll.NDIlib_send_send_video_async_v2(self._sender, byref(self._frame))
            self._last_ptr_keep = buf
            self._buf_idx ^= 1
        else:
            arr = frame if (frame.dtype == np.uint8 and frame.flags.c_contiguous) \
                        else np.ascontiguousarray(frame, dtype=np.uint8)
            self._frame.p_data = arr.ctypes.data_as(POINTER(c_uint8))
            self._dll.NDIlib_send_send_video_v2(self._sender, byref(self._frame))
        return True

    def close(self):
        if getattr(self, "_sender", None):
            if self._async:
                # flush: pass NULL per liberare il buffer precedente
                empty = _VideoFrameV2()  # tutti zero
                try:
                    self._dll.NDIlib_send_send_video_async_v2(self._sender, byref(empty))
                except Exception:
                    pass
            self._dll.NDIlib_send_destroy(self._sender)
            self._sender = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass
