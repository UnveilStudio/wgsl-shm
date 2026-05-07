// ── 3D Particle Starfield / Hyperspace ───────────────────────────────
// Multi-layer warp-speed particle field with motion blur trails,
// depth-based size variation, and color shifts.
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

fn hash31(p: vec3<f32>) -> f32 {
    var p3 = fract(p * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn hash33(p: vec3<f32>) -> vec3<f32> {
    var p3 = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// single particle layer contribution
fn particle_layer(
    uv: vec2<f32>, t: f32, layer: f32,
    density: f32, warp_amt: f32
) -> vec4<f32> {
    // each layer has its own depth and speed
    let layer_hash  = hash31(vec3<f32>(layer, layer * 7.13, layer * 13.7));
    let layer_depth = 0.3 + layer_hash * 0.7;
    let layer_speed = 0.6 + layer_hash * 0.8;

    // grid for this layer
    let cell_size = mix(0.04, 0.15, layer_depth) / max(density * 0.25, 0.5);
    let grid_uv   = uv / cell_size;
    let cell_id   = floor(grid_uv);
    let cell_frac = fract(grid_uv) - 0.5;

    var total_col   = vec3<f32>(0.0);
    var total_alpha = 0.0;

    // check 3x3 neighbourhood for smooth edges
    for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
            let neighbor = vec2<f32>(f32(dx), f32(dy));
            let cid      = cell_id + neighbor;
            let seed     = vec3<f32>(cid, layer);
            let rnd      = hash33(seed);

            // particle exists?  density controls probability
            if (rnd.z > density * 0.14) { continue; }

            // position within cell (with warp chaos)
            var p_pos = rnd.xy - 0.5;
            let chaos = sin(t * layer_speed + rnd.x * 6.28) * warp_amt * 0.3;
            p_pos.x += chaos;
            p_pos.y += sin(t * layer_speed * 0.7 + rnd.y * 6.28) * warp_amt * 0.2;

            let delta = cell_frac - neighbor - p_pos;

            // motion blur: stretch along flight direction (y axis = forward)
            let trail_len = uni.speed * layer_speed * 0.15;
            var stretch = delta;
            stretch.y /= max(1.0 + trail_len * 3.0, 1.0);

            let dist = length(stretch);

            // particle size varies with depth and randomness
            let base_size = mix(0.06, 0.2, layer_depth) * (0.5 + rnd.x * 0.5);
            let glow      = exp(-dist * dist / (base_size * base_size * 0.02)) * layer_depth;

            if (glow < 0.001) { continue; }

            // color per particle
            let hue_shift = rnd.y * 0.5 + layer * 0.1 + t * 0.05;
            let p_col = mix(
                mix(uni.col_b.rgb, uni.col_c.rgb, fract(hue_shift)),
                vec3<f32>(1.0),
                glow * 0.3
            );

            total_col   += p_col * glow;
            total_alpha += glow;
        }
    }
    return vec4<f32>(total_col, total_alpha);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let res = vec2<f32>(uni.width, uni.height);
    let uv  = (vec2<f32>(f32(gid.x), f32(gid.y)) - 0.5 * res) / min(res.x, res.y);
    let t   = uni.time * uni.speed;
    let layers = clamp(i32(uni.octaves_f), 1, 7);

    // warp the UV for tunnel-like convergence
    let r       = length(uv);
    let angle   = atan2(uv.y, uv.x);
    let warp_r  = r + uni.warp * sin(r * 8.0 - t * 2.0) * 0.05;
    let w_uv    = vec2<f32>(cos(angle), sin(angle)) * warp_r;

    // scroll UVs forward in time (flight effect)
    var fly_uv = w_uv;
    fly_uv.y -= t * 0.5;

    var col = uni.col_a.rgb * 0.05; // deep background

    // accumulate particle layers
    for (var i = 0; i < layers; i++) {
        let fi = f32(i);
        let layer_uv = fly_uv * (1.0 + fi * 0.3) + vec2<f32>(fi * 1.7, fi * 2.3);
        let layer_result = particle_layer(layer_uv, t, fi, uni.scale, uni.warp);
        col += layer_result.rgb;
    }

    // radial streaks (speed lines)
    let streak_angle = atan2(uv.y, uv.x) * 40.0;
    let streak = pow(abs(sin(streak_angle + t * 3.0)), 40.0) * uni.speed * 0.15;
    let streak_fade = smoothstep(0.0, 0.3, r) * exp(-r * 2.0);
    col += mix(uni.col_b.rgb, uni.col_c.rgb, uni.color_mix) * streak * streak_fade;

    // central glow
    let center = exp(-r * r * 6.0) * 0.2;
    col += mix(uni.col_b.rgb, uni.col_c.rgb, 0.5) * center;

    // color_mix shifts overall palette temperature
    col = mix(col, col * uni.col_c.rgb * 2.0, uni.color_mix * 0.3);

    // vignette
    let vig = 1.0 - r * r * 0.5;
    col *= vig;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
