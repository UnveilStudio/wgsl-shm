"""
td_shm.py — Shared Memory In TOP (TouchDesigner) nativo da Python su Windows.

Reimplementazione del protocollo UT_SharedMem usato da TD:
- due mapping Win32 (data + info) con decorazioni fisse
- un mutex Win32 per il data mapping
- header TOP_SharedMemHeader v2 all'inizio del data mapping

Serve per scrivere un frame dentro il "Shared Memory In TOP" senza usare
il doppio-mapping manuale di multiprocessing.shared_memory (che non è
compatibile col naming TD).

Riferimenti (TD 2025.32280 Samples/SharedMem):
    TOP/TOP_SharedMemHeader.h
    UT_SharedMem.{h,cpp}
    UT_Mutex.{h,cpp}

Naming Windows (dato shortName="TOPShm"):
    data mapping : "TouchSHMTOPShm"
    data mutex   : "TouchSHMTOPShmMutex"
    info mapping : "TouchSHMTOPShm4jhd783h"
    info mutex   : "TouchSHMTOPShm4jhd783hMutex"
Se TD ha il toggle "Global" acceso, tutti i nomi sono prefissati con "Global\".
"""

import ctypes
from ctypes import wintypes
import struct

# ─── Win32 bindings ──────────────────────────────────────────────────────────
_k32 = ctypes.WinDLL("kernel32", use_last_error=True)

INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
PAGE_READWRITE       = 0x04
FILE_MAP_ALL_ACCESS  = 0xF001F
WAIT_OBJECT_0        = 0x00000000
WAIT_ABANDONED       = 0x00000080
ERROR_ALREADY_EXISTS = 183

_k32.CreateFileMappingW.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    wintypes.DWORD, wintypes.DWORD, wintypes.LPCWSTR,
]
_k32.CreateFileMappingW.restype = wintypes.HANDLE

_k32.MapViewOfFile.argtypes = [
    wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
    wintypes.DWORD, ctypes.c_size_t,
]
_k32.MapViewOfFile.restype = ctypes.c_void_p

_k32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
_k32.UnmapViewOfFile.restype  = wintypes.BOOL

_k32.CloseHandle.argtypes = [wintypes.HANDLE]
_k32.CloseHandle.restype  = wintypes.BOOL

_k32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
_k32.CreateMutexW.restype  = wintypes.HANDLE

_k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
_k32.WaitForSingleObject.restype  = wintypes.DWORD

_k32.ReleaseMutex.argtypes = [wintypes.HANDLE]
_k32.ReleaseMutex.restype  = wintypes.BOOL


# ─── Costanti TD ─────────────────────────────────────────────────────────────
TOP_SHM_MAGIC_NUMBER = 0xd95ef835
TOP_SHM_VERSION      = 2

UT_SHM_INFO_MAGIC    = 0x56ed34ba
UT_SHM_INFO_VERSION  = 2
UT_SHM_INFO_DECORATION = "4jhd783h"
UT_SHM_POSTFIX_SIZE  = 32   # WCHAR count
TOUCH_PREFIX         = "TouchSHM"

# TOP_PixelFormat (sottoinsieme, da TOP_SharedMemHeader.h)
TOP_FORMAT_R8G8B8A8_UNORM        = 37
TOP_FORMAT_B8G8R8A8_UNORM        = 44
TOP_FORMAT_R16G16B16A16_SFLOAT   = 97
TOP_FORMAT_R32G32B32A32_SFLOAT   = 109

# TOP_GamutPrimaries
GAMUT_REC709_SRGB = 2
# TOP_Transfer
TRANSFER_LINEAR = 0
TRANSFER_SRGB   = 1

# ─── Packed layout ───────────────────────────────────────────────────────────
# TOP_SharedMemHeader (56 byte su MSVC x64):
#   0  u32 magicNumber
#   4  u32 version
#   8  i32 width
#  12  i32 height
#  16  f32 aspectx
#  20  f32 aspecty
#  24  u32 pixelFormat
#  28  ---- 4 byte padding per allineare int64 ----
#  32  i64 dataSize
#  40  i32 dataOffset
#  44  u32 gamutPrimaries
#  48  u32 transfer
#  52  ---- 4 byte trailing padding ----
#  56  (dataOffset punta qui)
TOP_HEADER_FMT  = "<IIiiffI4xqiII4x"
TOP_HEADER_SIZE = struct.calcsize(TOP_HEADER_FMT)
assert TOP_HEADER_SIZE == 56, TOP_HEADER_SIZE

# Core (version-agnostic): magic..dataOffset, identico in v1 e v2
# v1 sizeof = 48 (no gamut/transfer), v2 sizeof = 56.
# TD 2025 come sender manda v1; come receiver legge >= v1.
TOP_HEADER_CORE_FMT  = "<IIiiffI4xqi"
TOP_HEADER_CORE_SIZE = struct.calcsize(TOP_HEADER_CORE_FMT)
assert TOP_HEADER_CORE_SIZE == 44, TOP_HEADER_CORE_SIZE

# UT_SharedMemInfo (76 byte su MSVC x64):
#   0  u32 magicNumber
#   4  u32 version
#   8  bool supported
#   9  ---- 1 byte padding (WCHAR alignment=2) ----
#  10  WCHAR[32] namePostFix  (64 byte)
#  74  bool detach
#  75  ---- 1 byte trailing padding ----
#  76
INFO_FMT  = "<II?x64s?x"
INFO_SIZE = struct.calcsize(INFO_FMT)
assert INFO_SIZE == 76, INFO_SIZE


# ─── Win32 helpers ───────────────────────────────────────────────────────────
def _raise_win(msg: str):
    err = ctypes.get_last_error()
    raise OSError(err, f"{msg} (WinError {err})")


def _create_file_mapping(name: str, size: int) -> int:
    """Crea un File Mapping Win32. Torna l'HANDLE.
    Se il mapping esiste già lo chiude e rialza (il sender DEVE essere unico)."""
    size_lo = size & 0xFFFFFFFF
    size_hi = (size >> 32) & 0xFFFFFFFF
    h = _k32.CreateFileMappingW(
        INVALID_HANDLE_VALUE, None, PAGE_READWRITE,
        size_hi, size_lo, name,
    )
    if not h:
        _raise_win(f"CreateFileMappingW('{name}')")
    if ctypes.get_last_error() == ERROR_ALREADY_EXISTS:
        # Qualcuno aveva già creato il mapping con questo nome.
        # Usiamo comunque l'handle che abbiamo (punta allo stesso oggetto),
        # TD può averlo creato per primo (aspetta dati).
        pass
    return h


def _map_view(handle: int, size: int) -> int:
    addr = _k32.MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, size)
    if not addr:
        _raise_win("MapViewOfFile")
    return addr


def _create_mutex(name: str) -> int:
    h = _k32.CreateMutexW(None, False, name)
    if not h:
        _raise_win(f"CreateMutexW('{name}')")
    return h


def _lock(mutex: int, timeout_ms: int = 5000) -> bool:
    r = _k32.WaitForSingleObject(mutex, timeout_ms)
    return r in (WAIT_OBJECT_0, WAIT_ABANDONED)


def _unlock(mutex: int):
    _k32.ReleaseMutex(mutex)


# ─── API principale ──────────────────────────────────────────────────────────
class TopSharedMemSender:
    """
    Sender per il "Shared Memory In TOP" di TouchDesigner.

    Parametri:
        short_name   : nome corto (quello che scrivi in "Memory Name" su TD TOP)
        width,height : dimensioni immagine in pixel
        pixel_format : uno dei TOP_FORMAT_*
        bytes_per_pixel : dipende dal pixel_format (4 per RGBA8, 16 per RGBA32F)
        global_ns    : se True usa "Global\\" prefix (TD toggle Global = ON)

    Uso:
        tx = TopSharedMemSender("TOPamd", 512, 512, TOP_FORMAT_R8G8B8A8_UNORM, 4)
        while True:
            tx.write(frame_hwc_uint8)   # numpy (H,W,4) contiguo
        tx.close()
    """

    def __init__(self, short_name: str, width: int, height: int,
                 pixel_format: int, bytes_per_pixel: int,
                 global_ns: bool = False):
        self.short_name = short_name
        self.w = width
        self.h = height
        self.pixel_format = pixel_format
        self.bpp = bytes_per_pixel
        self.data_size  = width * height * bytes_per_pixel
        self.total_size = TOP_HEADER_SIZE + self.data_size

        prefix = "Global\\" if global_ns else ""
        self._data_name  = f"{prefix}{TOUCH_PREFIX}{short_name}"
        self._data_mutex_name = self._data_name + "Mutex"
        self._info_short = f"{short_name}{UT_SHM_INFO_DECORATION}"
        self._info_name  = f"{prefix}{TOUCH_PREFIX}{self._info_short}"
        self._info_mutex_name = self._info_name + "Mutex"

        # Data mapping + mutex
        self._data_handle = _create_file_mapping(self._data_name, self.total_size)
        self._data_addr   = _map_view(self._data_handle, self.total_size)
        self._data_mutex  = _create_mutex(self._data_mutex_name)

        # Info mapping + mutex
        self._info_handle = _create_file_mapping(self._info_name, INFO_SIZE)
        self._info_addr   = _map_view(self._info_handle, INFO_SIZE)
        self._info_mutex  = _create_mutex(self._info_mutex_name)

        self._write_initial_info()
        self._write_header()

        print(f"[td_shm] SENDER pronto")
        print(f"[td_shm]   data: {self._data_name}  ({self.total_size/1024:.0f} KB)")
        print(f"[td_shm]   info: {self._info_name}  ({INFO_SIZE} B)")
        print(f"[td_shm]   TD 'Memory Name' = '{short_name}'  Global = {'ON' if global_ns else 'OFF'}")

    # ── info ────────────────────────────────────────────────────────────────
    def _write_initial_info(self):
        # supported=False (il receiver TD lo metterà a True quando si connette),
        # namePostFix vuoto (non facciamo resize), detach=False.
        buf = struct.pack(INFO_FMT,
                          UT_SHM_INFO_MAGIC,
                          UT_SHM_INFO_VERSION,
                          False,
                          b"\x00" * 64,
                          False)
        if not _lock(self._info_mutex, 5000):
            raise RuntimeError("timeout lock info mutex")
        try:
            ctypes.memmove(self._info_addr, buf, INFO_SIZE)
        finally:
            _unlock(self._info_mutex)

    # ── header ──────────────────────────────────────────────────────────────
    def _write_header(self):
        hdr = struct.pack(TOP_HEADER_FMT,
                          TOP_SHM_MAGIC_NUMBER,
                          TOP_SHM_VERSION,
                          self.w, self.h,
                          1.0, 1.0,
                          self.pixel_format,
                          self.data_size,         # int64
                          TOP_HEADER_SIZE,        # dataOffset
                          GAMUT_REC709_SRGB,
                          TRANSFER_LINEAR)
        ctypes.memmove(self._data_addr, hdr, TOP_HEADER_SIZE)

    # ── write frame ─────────────────────────────────────────────────────────
    def write(self, frame_bytes) -> bool:
        """frame_bytes: bytes-like oggetto di esattamente self.data_size byte,
        già nel pixel format dichiarato. Torna True se scritto, False se mutex timeout."""
        if not _lock(self._data_mutex, 5000):
            return False
        try:
            # buffer protocol — funziona con numpy array contigui via .tobytes()
            # più efficiente: ctypes.memmove con buffer da ndarray
            if hasattr(frame_bytes, "ctypes"):
                src = frame_bytes.ctypes.data
                ctypes.memmove(self._data_addr + TOP_HEADER_SIZE, src, self.data_size)
            else:
                b = bytes(frame_bytes)
                if len(b) != self.data_size:
                    raise ValueError(f"frame size {len(b)} != expected {self.data_size}")
                ctypes.memmove(self._data_addr + TOP_HEADER_SIZE, b, self.data_size)
        finally:
            _unlock(self._data_mutex)
        return True

    def close(self):
        # Segnaliamo detach per eventuali receiver attaccati.
        try:
            if self._info_addr and _lock(self._info_mutex, 1000):
                try:
                    # detach flag sta al byte 74 (dopo magic+version+supported+pad+postFix[64])
                    detach_offset = 4 + 4 + 1 + 1 + 64
                    ctypes.memmove(self._info_addr + detach_offset, b"\x01", 1)
                finally:
                    _unlock(self._info_mutex)
        except Exception:
            pass

        for addr_attr in ("_data_addr", "_info_addr"):
            addr = getattr(self, addr_attr, None)
            if addr:
                _k32.UnmapViewOfFile(addr)
                setattr(self, addr_attr, 0)

        for h_attr in ("_data_mutex", "_info_mutex", "_data_handle", "_info_handle"):
            h = getattr(self, h_attr, None)
            if h:
                _k32.CloseHandle(h)
                setattr(self, h_attr, 0)


# ─── Receiver ────────────────────────────────────────────────────────────────
_k32.OpenFileMappingW = _k32.OpenFileMappingW
_k32.OpenFileMappingW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
_k32.OpenFileMappingW.restype  = wintypes.HANDLE


def _open_file_mapping(name: str) -> int:
    h = _k32.OpenFileMappingW(FILE_MAP_ALL_ACCESS, False, name)
    return h or 0


class TopSharedMemReceiver:
    """
    Receiver per un "Shared Memory Out TOP" di TouchDesigner.
    Ci attacchiamo al mapping che TD ha già creato come sender.

    Uso:
        rx = TopSharedMemReceiver("TDData", global_ns=False)
        rx.wait_ready(timeout_s=10)    # aspetta che TD abbia creato il mapping
        hdr, frame = rx.read()         # frame: numpy view (H,W,4) uint8 (copy)
        rx.close()
    """
    def __init__(self, short_name: str, global_ns: bool = False,
                 max_size: int = 4096 * 4096 * 16):
        self.short_name = short_name
        self.max_size = max_size

        prefix = "Global\\" if global_ns else ""
        self._data_name        = f"{prefix}{TOUCH_PREFIX}{short_name}"
        self._data_mutex_name  = self._data_name + "Mutex"
        self._info_name        = f"{prefix}{TOUCH_PREFIX}{short_name}{UT_SHM_INFO_DECORATION}"
        self._info_mutex_name  = self._info_name + "Mutex"

        self._data_handle = 0
        self._data_addr   = 0
        self._info_handle = 0
        self._info_addr   = 0
        self._data_mutex  = 0     # creato lazy solo se il sender lo espone
        self._info_mutex  = 0
        self._has_mutex   = False

        self._current_postfix = ""

    def _try_open_info(self) -> bool:
        """Info mapping è OPZIONALE: il TD Out TOP non lo pubblica. Ritorna
        True se c'è, False se il sender non lo usa."""
        if self._info_addr:
            return True
        h = _open_file_mapping(self._info_name)
        if not h:
            return False
        addr = _k32.MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, 0)
        if not addr:
            _k32.CloseHandle(h)
            return False
        self._info_handle = h
        self._info_addr   = addr
        # Il mutex del info lo creiamo solo se c'è l'info
        if not self._info_mutex:
            self._info_mutex = _create_mutex(self._info_mutex_name)
        return True

    def _read_info(self):
        """Ritorna (magic, version, supported, postFix, detach)."""
        if not self._info_addr:
            return None
        buf = ctypes.string_at(self._info_addr, INFO_SIZE)
        magic, version, supported, postfix_bytes, detach = struct.unpack(INFO_FMT, buf)
        # postfix_bytes è 64 byte → 32 WCHAR. Convertiamo a stringa.
        postfix_str = postfix_bytes.decode("utf-16-le", errors="replace").rstrip("\x00")
        return magic, version, supported, postfix_str, detach

    def _write_supported(self, flag: bool):
        """Setta info->supported = flag (offset 8, 1 byte)."""
        if self._info_addr:
            ctypes.memmove(self._info_addr + 8, b"\x01" if flag else b"\x00", 1)

    def _open_data(self, postfix: str) -> bool:
        if self._data_addr and postfix == self._current_postfix:
            return True
        # Detach precedente se postFix è cambiato
        if self._data_addr:
            _k32.UnmapViewOfFile(self._data_addr)
            self._data_addr = 0
        if self._data_handle:
            _k32.CloseHandle(self._data_handle)
            self._data_handle = 0

        full_name = self._data_name + postfix
        h = _open_file_mapping(full_name)
        if not h:
            return False
        addr = _k32.MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, 0)
        if not addr:
            _k32.CloseHandle(h)
            return False
        self._data_handle = h
        self._data_addr   = addr
        self._current_postfix = postfix
        return True

    def wait_ready(self, timeout_s: float = 10.0) -> bool:
        """Aspetta che il sender TD abbia creato info+data mapping."""
        import time as _t
        deadline = _t.monotonic() + timeout_s
        while _t.monotonic() < deadline:
            if self._ensure_connected():
                return True
            _t.sleep(0.1)
        return False

    def _ensure_connected(self) -> bool:
        postfix = ""
        if self._try_open_info():
            info = self._read_info()
            if info is not None:
                magic, version, supported, pf, detach = info
                if magic == UT_SHM_INFO_MAGIC:
                    if detach:
                        return False
                    postfix = pf
                    if not supported and self._info_mutex:
                        if _lock(self._info_mutex, 1000):
                            try:
                                self._write_supported(True)
                            finally:
                                _unlock(self._info_mutex)
        # Se non c'è info (TD Out TOP), apriamo data mapping con postFix vuoto
        return self._open_data(postfix)

    def read_header(self):
        """Ritorna dict con i campi di TOP_SharedMemHeader, o None.
        Parsa solo il core (v1-compatible, 44 byte) e ignora i trailing v2."""
        if not self._ensure_connected():
            return None
        buf = ctypes.string_at(self._data_addr, TOP_HEADER_CORE_SIZE)
        (magic, version, w, h, ax, ay, pixfmt,
         dataSize, dataOffset) = struct.unpack(TOP_HEADER_CORE_FMT, buf)
        if magic != TOP_SHM_MAGIC_NUMBER:
            return None
        return dict(magic=magic, version=version, width=w, height=h,
                    aspectx=ax, aspecty=ay, pixelFormat=pixfmt,
                    dataSize=dataSize, dataOffset=dataOffset)

    def read(self, out: "np.ndarray | None" = None, timeout_ms: int = 100):
        """
        Legge un frame. Torna (header_dict, frame_copy_uint8_HxWx4) oppure (None, None).
        Il lock del data mutex è preso per minimizzare il tempo di copia.
        """
        import numpy as _np
        hdr = self.read_header()
        if hdr is None:
            return None, None
        w, h = hdr["width"], hdr["height"]
        fmt = hdr["pixelFormat"]
        offs = hdr["dataOffset"]

        if fmt in (TOP_FORMAT_R8G8B8A8_UNORM, TOP_FORMAT_B8G8R8A8_UNORM):
            bpp = 4
            dtype = _np.uint8
        elif fmt == TOP_FORMAT_R16G16B16A16_SFLOAT:
            bpp = 8
            dtype = _np.float16
        elif fmt == TOP_FORMAT_R32G32B32A32_SFLOAT:
            bpp = 16
            dtype = _np.float32
        else:
            return hdr, None   # formato non gestito

        nbytes = w * h * bpp
        if nbytes > self.max_size:
            return hdr, None

        # Se il sender espone un data mutex lo usiamo; altrimenti lettura diretta.
        # TD Out TOP non ha mutex, ma il "Download Type: Next frame (Fast)" fa
        # atomic swap del buffer → leggere raw è safe.
        locked = False
        if self._data_mutex:
            locked = _lock(self._data_mutex, timeout_ms)
            if not locked:
                return hdr, None
        try:
            raw = ctypes.string_at(self._data_addr + offs, nbytes)
        finally:
            if locked:
                _unlock(self._data_mutex)

        frame = _np.frombuffer(raw, dtype=dtype).reshape(h, w, 4).copy()
        return hdr, frame

    def close(self):
        for addr_attr in ("_data_addr", "_info_addr"):
            a = getattr(self, addr_attr, 0)
            if a:
                _k32.UnmapViewOfFile(a)
                setattr(self, addr_attr, 0)
        for h_attr in ("_data_handle", "_info_handle", "_data_mutex", "_info_mutex"):
            h = getattr(self, h_attr, 0)
            if h:
                _k32.CloseHandle(h)
                setattr(self, h_attr, 0)


def pixel_format_name(fmt: int) -> str:
    return {
        TOP_FORMAT_R8G8B8A8_UNORM:       "R8G8B8A8_UNORM",
        TOP_FORMAT_B8G8R8A8_UNORM:       "B8G8R8A8_UNORM",
        TOP_FORMAT_R16G16B16A16_SFLOAT:  "R16G16B16A16_SFLOAT",
        TOP_FORMAT_R32G32B32A32_SFLOAT:  "R32G32B32A32_SFLOAT",
    }.get(fmt, f"unknown({fmt})")
