// fluid.wgsl — ink-in-water psychedelic fluid with curl noise and vortex shedding
// workgroup 16x16 (RDNA3.5 wave32 × 8 waves)

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

// --- helpers ----------------------------------------------------------------

fn hash21(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(127.1, 311.7));
    q += dot(q, q + 19.19);
    return fract(q.x * q.y);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i + vec2<f32>(0.0, 0.0)), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

fn fbm(p: vec2<f32>, oct: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < oct; i = i + 1) {
        v += a * noise(q);
        q = q * 2.0 + vec2<f32>(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

// curl noise: returns a 2D divergence-free vector field
fn curl_noise(p: vec2<f32>, oct: i32) -> vec2<f32> {
    let eps = 0.01;
    let dx = fbm(p + vec2<f32>(eps, 0.0), oct) - fbm(p - vec2<f32>(eps, 0.0), oct);
    let dy = fbm(p + vec2<f32>(0.0, eps), oct) - fbm(p - vec2<f32>(0.0, eps), oct);
    // curl = (dF/dy, -dF/dx) — perpendicular to gradient
    return vec2<f32>(dy, -dx) / (2.0 * eps);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv  = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let t   = uni.time * uni.speed;
    let oct = max(1, i32(uni.octaves_f + 0.5));

    let aspect = uni.width / uni.height;
    var p = (uv - 0.5) * vec2<f32>(aspect, 1.0) * uni.scale;

    // multi-pass curl noise advection — simulates fluid transport
    // each pass warps the coordinates through the curl field
    let vorticity = uni.warp * 2.0;

    // pass 1: large-scale flow
    let curl1 = curl_noise(p * 0.5 + vec2<f32>(t * 0.05, 0.0), max(oct - 2, 1));
    var q = p + curl1 * vorticity * 0.8;

    // pass 2: medium-scale vortices
    let curl2 = curl_noise(q * 1.0 + vec2<f32>(0.0, t * 0.08), max(oct - 1, 1));
    q = q + curl2 * vorticity * 0.4;

    // pass 3: fine turbulence
    let curl3 = curl_noise(q * 2.0 + vec2<f32>(t * 0.12, t * 0.06), oct);
    q = q + curl3 * vorticity * 0.2;

    // ink density layers — multiple "ink drops" at different phases
    let ink1 = fbm(q + vec2<f32>(0.0, 0.0), oct);
    let ink2 = fbm(q + vec2<f32>(5.2, 1.3), oct);
    let ink3 = fbm(q + vec2<f32>(2.8, 7.1), oct);

    // sharp ink boundaries — use smoothstep for that ink-in-water look
    let edge1 = smoothstep(0.35, 0.5, ink1);
    let edge2 = smoothstep(0.40, 0.55, ink2);
    let edge3 = smoothstep(0.30, 0.45, ink3);

    // vortex shedding: periodic detachment pattern
    let shed_freq = 3.0 + vorticity * 2.0;
    let shed = 0.5 + 0.5 * sin(q.x * shed_freq + t * 2.0) *
                             cos(q.y * shed_freq * 0.7 + t * 1.3);

    // color mixing: each ink layer gets its own color
    let mix_t = uni.color_mix;
    let color1 = mix(uni.col_a.rgb, uni.col_b.rgb, mix_t);
    let color2 = mix(uni.col_b.rgb, uni.col_c.rgb, mix_t);
    let color3 = mix(uni.col_c.rgb, uni.col_a.rgb * 2.0, mix_t);

    // composite ink layers with sharp boundaries
    var col = uni.col_a.rgb * 0.3;
    col = mix(col, color1, edge1 * 0.7);
    col = mix(col, color2, edge2 * 0.6);
    col = mix(col, color3, edge3 * 0.5);

    // add luminous highlights at ink boundaries (where gradient is steep)
    let grad = abs(ink1 - ink2) + abs(ink2 - ink3);
    let boundary_glow = smoothstep(0.1, 0.4, grad) * 0.3;
    col += mix(uni.col_b.rgb, uni.col_c.rgb, shed) * boundary_glow;

    // subtle iridescence from vortex shedding
    let iridescence = vec3<f32>(
        0.5 + 0.5 * sin(shed * 6.28 + 0.0),
        0.5 + 0.5 * sin(shed * 6.28 + 2.09),
        0.5 + 0.5 * sin(shed * 6.28 + 4.18)
    );
    col = mix(col, col * iridescence, 0.15 * vorticity);

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
