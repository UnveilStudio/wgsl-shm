// fractal.wgsl — animated Julia set with orbit traps, workgroup 16x16 (RDNA3.5 wave32 × 8 waves)

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
// sizeof = 16 + 16 + 16 + 16 + 16 = 80 byte

@group(0) @binding(0) var<uniform>              uni     : Uni;
@group(0) @binding(1) var                       out_tex : texture_storage_2d<rgba8unorm, write>;

// ---- complex math helpers ---------------------------------------------------

fn cmul(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

fn cabs2(z: vec2<f32>) -> f32 {
    return dot(z, z);
}

// ---- palette ----------------------------------------------------------------

fn palette_a(t: f32) -> vec3<f32> {
    // smooth cosine palette: a + b*cos(2π(c*t+d))
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.00, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

fn palette_b(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 0.5);
    let d = vec3<f32>(0.80, 0.90, 0.30);
    return a + b * cos(6.28318 * (c * t + d));
}

// ---- main -------------------------------------------------------------------

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let aspect = uni.width / uni.height;
    let uv = (vec2<f32>(f32(gid.x), f32(gid.y)) / vec2<f32>(uni.width, uni.height) - 0.5)
             * vec2<f32>(aspect, 1.0);

    let t = uni.time * uni.speed;
    let max_iter = clamp(i32(uni.octaves_f) * 32, 32, 224);

    // ---- Julia c parameter: animated + warp-modulated ----
    let c = vec2<f32>(
        -0.76 + sin(t * 0.37) * 0.12 + uni.warp * cos(t * 0.53) * 0.3,
        0.15  + cos(t * 0.41) * 0.10 + uni.warp * sin(t * 0.67) * 0.3
    );

    // ---- zoom into fractal ----
    let zoom = exp(-uni.scale * 0.5 + 1.0);
    // slow drift of center for visual interest
    let center = vec2<f32>(sin(t * 0.11) * 0.1, cos(t * 0.13) * 0.1);
    var z = uv * zoom + center;

    // ---- iterate Julia set ----
    var smooth_iter = 0.0;
    var escaped = false;
    var orbit_trap = 1e10;
    var orbit_trap_cross = 1e10;
    let bail2 = 256.0;

    for (var i = 0; i < max_iter; i++) {
        z = cmul(z, z) + c;
        let m2 = cabs2(z);

        // orbit traps: distance to origin and to axes
        orbit_trap = min(orbit_trap, m2);
        orbit_trap_cross = min(orbit_trap_cross, min(abs(z.x), abs(z.y)));

        if (m2 > bail2) {
            // smooth iteration count (continuous potential)
            let log_z = log(m2) * 0.5;
            let nu = log(log_z / log(2.0)) / log(2.0);
            smooth_iter = f32(i) + 1.0 - nu;
            escaped = true;
            break;
        }
    }

    var col: vec3<f32>;

    if (escaped) {
        // ---- exterior coloring: palette cycling ----
        let base_t = smooth_iter * 0.02 + t * 0.15;
        let pa = palette_a(base_t);
        let pb = palette_b(base_t + 0.3);
        col = mix(pa, pb, uni.color_mix);

        // modulate brightness by orbit trap proximity
        let trap_glow = exp(-orbit_trap * 2.0) * 0.5;
        col += uni.col_b.rgb * trap_glow;

        // edge glow near boundary
        let edge = exp(-smooth_iter * 0.08);
        col += uni.col_c.rgb * edge * 0.6;
    } else {
        // ---- interior coloring: orbit trap technique ----
        let trap_val = sqrt(orbit_trap);
        let cross_val = sqrt(orbit_trap_cross) * 4.0;

        // rich interior pattern from orbit traps
        let interior_t = trap_val * 3.0 + t * 0.2;
        let base_col = mix(uni.col_a.rgb, uni.col_b.rgb, sin(interior_t) * 0.5 + 0.5);

        // cross trap creates veins/structure
        let vein = exp(-cross_val * 8.0);
        col = base_col * (0.3 + trap_val * 2.0) + uni.col_c.rgb * vein * 0.8;

        // subtle pulsing glow in interior
        col *= 0.8 + sin(t * 1.5) * 0.2;
    }

    // ---- tonemap + gamma ----
    col = clamp(col, vec3<f32>(0.0), vec3<f32>(8.0));
    let mapped = col / (col + vec3<f32>(1.0));
    let final_col = pow(mapped, vec3<f32>(1.0 / 2.2));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(final_col, 1.0));
}
