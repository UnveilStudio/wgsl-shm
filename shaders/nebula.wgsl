// nebula.wgsl — volumetric raymarched nebula, workgroup 16x16 (RDNA3.5 wave32 × 8 waves)

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

// ---- hash & noise primitives ------------------------------------------------

fn hash3(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q += dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);

    let n000 = hash3(i + vec3<f32>(0.0, 0.0, 0.0));
    let n100 = hash3(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = hash3(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = hash3(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = hash3(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = hash3(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = hash3(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = hash3(i + vec3<f32>(1.0, 1.0, 1.0));

    let x0 = mix(n000, n100, u.x);
    let x1 = mix(n010, n110, u.x);
    let x2 = mix(n001, n101, u.x);
    let x3 = mix(n011, n111, u.x);
    let y0 = mix(x0, x1, u.y);
    let y1 = mix(x2, x3, u.y);
    return mix(y0, y1, u.z);
}

// ---- fBm with turbulence warp -----------------------------------------------

fn fbm(pos: vec3<f32>, octaves: i32) -> f32 {
    var p = pos;
    var amp = 0.5;
    var val = 0.0;
    var freq = 1.0;
    let t = uni.time * uni.speed;

    for (var i = 0; i < octaves; i++) {
        let warp_offset = vec3<f32>(
            noise3(p * 0.7 + t * 0.13),
            noise3(p * 0.7 + 43.0 + t * 0.11),
            noise3(p * 0.7 + 87.0 + t * 0.09)
        ) * uni.warp;

        val += amp * noise3((p + warp_offset) * freq);
        freq *= 2.03;
        amp *= 0.52;
        // rotate domain for anisotropy
        p = vec3<f32>(
            p.z * 0.8 + p.x * 0.6,
            p.y,
            p.z * 0.6 - p.x * 0.8
        );
    }
    return val;
}

// ---- density field ----------------------------------------------------------

fn density(p: vec3<f32>, octaves: i32) -> f32 {
    let s = p * uni.scale;
    let d = fbm(s, octaves);
    // shape into cloud-like falloff from center
    let r = length(p.xy) * 0.5;
    let falloff = exp(-r * r * 0.3);
    return clamp(d * falloff * 2.0 - 0.15, 0.0, 1.0);
}

// ---- star hotspots ----------------------------------------------------------

fn stars(p: vec3<f32>) -> f32 {
    let n = noise3(p * 12.0 + uni.time * uni.speed * 0.05);
    let s = smoothstep(0.92, 1.0, n);
    return s * s * 4.0;
}

// ---- main -------------------------------------------------------------------

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv = (vec2<f32>(f32(gid.x), f32(gid.y)) - vec2<f32>(uni.width, uni.height) * 0.5)
             / min(uni.width, uni.height);

    let t = uni.time * uni.speed;
    let octaves = clamp(i32(uni.octaves_f), 1, 7);

    // ---- ray setup (camera looks into volume) ----
    let ro = vec3<f32>(0.0, 0.0, -3.0 + sin(t * 0.07) * 0.3);
    let rd = normalize(vec3<f32>(uv, 0.8));

    // ---- volumetric raymarch: absorption + emission ----
    let STEPS = 40;
    let step_size = 6.0 / f32(STEPS);
    var pos = ro;
    var transmittance = 1.0;
    var light = vec3<f32>(0.0);
    let absorption = 1.8;

    for (var i = 0; i < STEPS; i++) {
        let d = density(pos, octaves);
        if (d > 0.001) {
            // depth parameter [0..1] along ray
            let depth = f32(i) / f32(STEPS);

            // emission color: blend col_a -> col_b -> col_c by depth + color_mix
            let blend = clamp(depth + uni.color_mix * 0.5 - 0.25, 0.0, 1.0);
            var emission: vec3<f32>;
            if (blend < 0.5) {
                emission = mix(uni.col_a.rgb, uni.col_b.rgb, blend * 2.0);
            } else {
                emission = mix(uni.col_b.rgb, uni.col_c.rgb, (blend - 0.5) * 2.0);
            }

            // intensity boost for bright cores
            let core = smoothstep(0.45, 0.9, d);
            emission *= (1.0 + core * 5.0);

            // star hotspots
            let star = stars(pos);
            emission += vec3<f32>(1.0, 0.95, 0.8) * star;

            // beer-lambert absorption
            let dt = d * absorption * step_size;
            let tr = exp(-dt);
            light += transmittance * (1.0 - tr) * emission;
            transmittance *= tr;

            if (transmittance < 0.01) { break; }
        }
        pos += rd * step_size;
    }

    // ---- background deep space glow ----
    let bg_n = noise3(vec3<f32>(uv * 5.0, t * 0.02)) * 0.15;
    let bg = uni.col_a.rgb * 0.3 * (1.0 + bg_n);
    light += transmittance * bg;

    // ---- tonemap + gamma ----
    let mapped = light / (light + vec3<f32>(1.0));
    let col = pow(mapped, vec3<f32>(1.0 / 2.2));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
