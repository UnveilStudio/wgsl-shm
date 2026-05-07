// ── Infinite Warp Tunnel ─────────────────────────────────────────────
// Demoscene-style infinite tunnel with morphing cross-section,
// glowing neon edges, depth fog, and procedural wall texture.
// Designed for sound-reactive performance on Radeon 880M @ 4K.
// ─────────────────────────────────────────────────────────────────────

struct Uni {
    time        : f32,
    width       : f32,
    height      : f32,
    scale       : f32,
    warp        : f32,
    speed       : f32,
    color_mix   : f32,
    octaves_f   : f32,
    col_a       : vec4<f32>,
    col_b       : vec4<f32>,
    col_c       : vec4<f32>,
};

@group(0) @binding(0) var<uniform>              uni     : Uni;
@group(0) @binding(1) var                       out_tex : texture_storage_2d<rgba8unorm, write>;

// ── helpers ──────────────────────────────────────────────────────────

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, vec3<f32>(p3.y + 33.33, p3.z + 33.33, p3.x + 33.33));
    return fract((p3.x + p3.y) * p3.z);
}

fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p_in: vec2<f32>, oct: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var p = p_in;
    let rot = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    for (var i = 0; i < oct; i++) {
        v += a * noise2(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

// morphing cross-section radius: blend circle with polygon shapes
fn tunnel_radius(angle: f32, t: f32, warp_amt: f32) -> f32 {
    let n3 = sin(angle * 3.0 + t * 0.7) * 0.15;
    let n5 = sin(angle * 5.0 - t * 1.1) * 0.08;
    let n7 = sin(angle * 7.0 + t * 0.5) * 0.04;
    return 1.0 + warp_amt * (n3 + n5 + n7);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let res = vec2<f32>(uni.width, uni.height);
    let uv  = (vec2<f32>(f32(gid.x), f32(gid.y)) - 0.5 * res) / min(res.x, res.y);
    let t   = uni.time * uni.speed;
    let oct = clamp(i32(uni.octaves_f), 1, 7);

    // polar coords
    let angle = atan2(uv.y, uv.x);
    let r     = length(uv) + 0.0001;

    // tunnel mapping: depth from inverse radius
    let tr    = tunnel_radius(angle, t, uni.warp);
    let depth = uni.scale / (r / tr);

    // texture coordinates on tunnel wall
    let tx = angle / 3.14159265 * 2.0 + t * 0.1;
    let ty = depth * 0.5 - t * 0.8;
    let wall_uv = vec2<f32>(tx, ty);

    // wall texture with fbm
    let tex = fbm(wall_uv * uni.scale, oct);

    // edge glow: brighter near tunnel walls (large depth = far, small r = edge)
    let edge_dist   = abs(r - tr * uni.scale * 0.12);
    let edge_glow   = exp(-edge_dist * 8.0) * 1.5;

    // neon ring pulses travelling along the tunnel
    let ring_phase = fract(depth * 0.15 - t * 0.6);
    let ring       = smoothstep(0.02, 0.0, abs(ring_phase - 0.5) - 0.48) * 2.0;

    // depth fog
    let fog = exp(-depth * 0.04);

    // base color from texture
    let base = mix(uni.col_a.rgb, uni.col_b.rgb, tex);

    // combine
    var col = base * (0.3 + tex * 0.7) * fog;

    // add neon edges and rings
    let neon_col = mix(uni.col_b.rgb, uni.col_c.rgb, sin(angle * 2.0 + t) * 0.5 + 0.5);
    col += neon_col * edge_glow * fog;
    col += neon_col * ring * fog * 0.6;

    // center glow (looking down the tunnel)
    let center_glow = exp(-r * r * 12.0) * 0.15;
    col += uni.col_c.rgb * center_glow;

    // color_mix blends between raw texture and neon-dominant look
    col = mix(col, neon_col * (tex * 0.5 + edge_glow + ring * 0.3) * fog, uni.color_mix);

    // subtle vignette
    let vig = 1.0 - dot(uv, uv) * 0.4;
    col *= vig;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
