"""
amd_generator.py — compute shader pipeline su iGPU AMD via wgpu-py.

Carica un WGSL compute shader, esegue dispatch su iGPU AMD, e fa il readback
del frame RGBA8 UNORM in un numpy array. Doppio staging buffer MAP_READ per
permettere overlap GPU/CPU (la CPU legge il frame N mentre la GPU calcola N+1).

Layout uniform: configurabile da fuori (`uniform_size` + `write_uniforms`).
"""

import struct

import numpy as np
import wgpu


def make_uniform_buf(device, *floats):
    data = struct.pack(f"{len(floats)}f", *floats)
    return device.create_buffer_with_data(
        data=data,
        usage=wgpu.BufferUsage.UNIFORM | wgpu.BufferUsage.COPY_DST,
    )


def update_uniform_buf(device, buf, *floats):
    data = struct.pack(f"{len(floats)}f", *floats)
    device.queue.write_buffer(buf, 0, data)


def make_storage_texture(device, w, h):
    return device.create_texture(
        size=(w, h, 1),
        format=wgpu.TextureFormat.rgba8unorm,
        usage=wgpu.TextureUsage.STORAGE_BINDING | wgpu.TextureUsage.COPY_SRC,
    )


class AMDGenerator:
    """
    Compute shader pipeline iGPU + persistent staging buffer.

    Parametri:
      device         : wgpu device (iGPU AMD)
      w, h           : risoluzione output RGBA8 UNORM
      shader_code    : WGSL string (alternativa a shader_path)
      shader_path    : se specificato, leggi il WGSL dal file (override shader_code)
      uniform_size   : bytes dell'uniform buffer (default 16)
      workgroup      : (wx, wy) del compute (default (8,8); la maggior parte degli
                       shader della collection usa (16,16))
      enable_profile : se True, crea query set timestamp e `render()` ritorna
                       (numpy_frame, metrics_dict) con breakdown GPU-side.
    """
    def __init__(self, device, w, h, *,
                 shader_code: str | None = None,
                 shader_path: str | None = None,
                 uniform_size: int = 16,
                 workgroup: tuple[int, int] = (8, 8),
                 enable_profile: bool = False):
        self.device = device
        self.w, self.h = w, h
        self.uniform_size = uniform_size
        self.workgroup = workgroup
        self._shader_path = shader_path
        self._profile = enable_profile

        if shader_path:
            with open(shader_path, "r", encoding="utf-8") as f:
                shader_code = f.read()
        if shader_code is None:
            raise ValueError("AMDGenerator: shader_code o shader_path richiesto")

        self.uni_buf = device.create_buffer(
            size=max(16, uniform_size),
            usage=wgpu.BufferUsage.UNIFORM | wgpu.BufferUsage.COPY_DST,
        )
        if uniform_size == 16:
            update_uniform_buf(device, self.uni_buf, 0.0, float(w), float(h), 0.0)

        self.out_tex = make_storage_texture(device, w, h)

        self._bgl = device.create_bind_group_layout(entries=[
            {"binding": 0, "visibility": wgpu.ShaderStage.COMPUTE,
             "buffer": {"type": wgpu.BufferBindingType.uniform}},
            {"binding": 1, "visibility": wgpu.ShaderStage.COMPUTE,
             "storage_texture": {"access": wgpu.StorageTextureAccess.write_only,
                                 "format": wgpu.TextureFormat.rgba8unorm,
                                 "view_dimension": wgpu.TextureViewDimension.d2}},
        ])
        self.bg = device.create_bind_group(layout=self._bgl, entries=[
            {"binding": 0, "resource": {"buffer": self.uni_buf}},
            {"binding": 1, "resource": self.out_tex.create_view()},
        ])
        self._pipeline_layout = device.create_pipeline_layout(bind_group_layouts=[self._bgl])
        self._build_pipeline(shader_code)

        # Double-buffer staging (MAP_READ). Padding righe a 256 byte (DX12 requirement).
        self.row_pitch = ((w * 4) + 255) & ~255
        staging_size = self.row_pitch * h
        self._staging = [
            device.create_buffer(size=staging_size,
                usage=wgpu.BufferUsage.COPY_DST | wgpu.BufferUsage.MAP_READ),
            device.create_buffer(size=staging_size,
                usage=wgpu.BufferUsage.COPY_DST | wgpu.BufferUsage.MAP_READ),
        ]
        self._write_idx = 0
        self._has_prev = False

        self._out_arr = np.empty((h, w, 4), dtype=np.uint8)

        self._qset = None
        self._ts_resolve_buf = None
        self._ts_readback_buf = None
        if enable_profile:
            try:
                self._qset = device.create_query_set(type="timestamp", count=4)
                self._ts_resolve_buf = device.create_buffer(
                    size=8 * 4,
                    usage=wgpu.BufferUsage.QUERY_RESOLVE | wgpu.BufferUsage.COPY_SRC,
                )
                self._ts_readback_buf = device.create_buffer(
                    size=8 * 4,
                    usage=wgpu.BufferUsage.COPY_DST | wgpu.BufferUsage.MAP_READ,
                )
            except Exception as e:
                print(f"[AMDGenerator] timestamp query non disponibile ({e!r}), profile CPU-only")
                self._qset = None

    def _build_pipeline(self, shader_code: str):
        module = self.device.create_shader_module(code=shader_code)
        self.pipeline = self.device.create_compute_pipeline(
            layout=self._pipeline_layout,
            compute={"module": module, "entry_point": "main"},
        )
        self._shader_code = shader_code

    def reload_shader(self, shader_code: str | None = None) -> bool:
        """Ricompila lo shader. Se compile-fail, tiene il vecchio e torna False."""
        if shader_code is None and self._shader_path:
            with open(self._shader_path, "r", encoding="utf-8") as f:
                shader_code = f.read()
        if shader_code is None:
            return False
        try:
            self._build_pipeline(shader_code)
            return True
        except Exception as e:
            print(f"[AMDGenerator] reload_shader FAILED: {e}")
            return False

    def write_uniforms(self, data: bytes):
        """Scrive l'intero uniform buffer. data viene paddato a uniform_size se serve."""
        assert len(data) >= 16, "uniform troppo piccolo"
        if len(data) < self.uniform_size:
            data = data + b"\x00" * (self.uniform_size - len(data))
        self.device.queue.write_buffer(self.uni_buf, 0, data[:self.uniform_size])

    def render(self, t: float | None = None):
        """
        Double-buffered dispatch + readback.
        GPU writes to staging[write_idx], CPU reads from staging[read_idx].
        First frame blocks (no previous buffer). After that, GPU/CPU overlap.

        Ritorna numpy (H,W,4) uint8; se enable_profile=True ritorna
        (frame, {'dispatch_ms': x, 'copy_ms': y, 'gpu_total_ms': x+y}).
        """
        device = self.device
        if t is not None and self.uniform_size == 16:
            update_uniform_buf(device, self.uni_buf, t, float(self.w), float(self.h), 0.0)

        wx, wy = self.workgroup
        dx = (self.w + wx - 1) // wx
        dy = (self.h + wy - 1) // wy

        write_buf = self._staging[self._write_idx]
        read_idx  = 1 - self._write_idx
        read_buf  = self._staging[read_idx]

        enc = device.create_command_encoder()

        if self._qset is not None:
            from wgpu.backends.wgpu_native.extras import write_timestamp as _wts
            _wts(enc, self._qset, 0)
            cp = enc.begin_compute_pass()
            cp.set_pipeline(self.pipeline)
            cp.set_bind_group(0, self.bg)
            cp.dispatch_workgroups(dx, dy)
            cp.end()
            _wts(enc, self._qset, 1)

            _wts(enc, self._qset, 2)
            enc.copy_texture_to_buffer(
                {"texture": self.out_tex, "mip_level": 0, "origin": (0, 0, 0)},
                {"buffer": write_buf, "offset": 0,
                 "bytes_per_row": self.row_pitch, "rows_per_image": self.h},
                (self.w, self.h, 1),
            )
            _wts(enc, self._qset, 3)
            enc.resolve_query_set(self._qset, 0, 4, self._ts_resolve_buf, 0)
            enc.copy_buffer_to_buffer(
                self._ts_resolve_buf, 0, self._ts_readback_buf, 0, 8 * 4)
        else:
            cp = enc.begin_compute_pass()
            cp.set_pipeline(self.pipeline)
            cp.set_bind_group(0, self.bg)
            cp.dispatch_workgroups(dx, dy)
            cp.end()
            enc.copy_texture_to_buffer(
                {"texture": self.out_tex, "mip_level": 0, "origin": (0, 0, 0)},
                {"buffer": write_buf, "offset": 0,
                 "bytes_per_row": self.row_pitch, "rows_per_image": self.h},
                (self.w, self.h, 1),
            )

        device.queue.submit([enc.finish()])

        if self._has_prev:
            read_buf.map_sync(wgpu.MapMode.READ)
            mv = read_buf.read_mapped(copy=False)
            raw = np.frombuffer(mv, dtype=np.uint8)
            if self.row_pitch == self.w * 4:
                np.copyto(self._out_arr, raw.reshape(self.h, self.w, 4))
            else:
                np.copyto(self._out_arr,
                          raw.reshape(self.h, self.row_pitch)[:, : self.w * 4]
                             .reshape(self.h, self.w, 4))
            read_buf.unmap()
        else:
            write_buf.map_sync(wgpu.MapMode.READ)
            mv = write_buf.read_mapped(copy=False)
            raw = np.frombuffer(mv, dtype=np.uint8)
            if self.row_pitch == self.w * 4:
                np.copyto(self._out_arr, raw.reshape(self.h, self.w, 4))
            else:
                np.copyto(self._out_arr,
                          raw.reshape(self.h, self.row_pitch)[:, : self.w * 4]
                             .reshape(self.h, self.w, 4))
            write_buf.unmap()
            self._has_prev = True

        self._write_idx = read_idx

        if self._qset is None:
            return self._out_arr

        self._ts_readback_buf.map_sync(wgpu.MapMode.READ)
        ts_bytes = self._ts_readback_buf.read_mapped(copy=True)
        self._ts_readback_buf.unmap()
        ts = np.frombuffer(ts_bytes, dtype=np.uint64)
        dispatch_ns = int(ts[1] - ts[0]) if ts[1] > ts[0] else 0
        copy_ns     = int(ts[3] - ts[2]) if ts[3] > ts[2] else 0
        metrics = {
            "dispatch_ms":  dispatch_ns / 1e6,
            "copy_ms":      copy_ns / 1e6,
            "gpu_total_ms": (dispatch_ns + copy_ns) / 1e6,
        }
        return self._out_arr, metrics
