// flowfield.wgsl — curl-noise flow field con streamline packate, workgroup 16x16

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


fn hash(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(127.1, 311.7));
    q += dot(q, q + 19.19);
    return fract(q.x * q.y);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i + vec2<f32>(0.0, 0.0)), hash(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash(i + vec2<f32>(0.0, 1.0)), hash(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

// potenziale scalare — la curl 2D è ( dφ/dy, -dφ/dx )
fn potential(p: vec2<f32>, t: f32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p + vec2<f32>(0.13 * t, -0.09 * t);
    v += a * vnoise(q); q = q * 2.0 + vec2<f32>(1.7, 9.2); a *= 0.5;
    v += a * vnoise(q); q = q * 2.0 + vec2<f32>(1.7, 9.2); a *= 0.5;
    v += a * vnoise(q);
    return v;
}

fn curl2(p: vec2<f32>, t: f32) -> vec2<f32> {
    let e = 0.01;
    let dx = potential(p + vec2<f32>(e, 0.0), t) - potential(p - vec2<f32>(e, 0.0), t);
    let dy = potential(p + vec2<f32>(0.0, e), t) - potential(p - vec2<f32>(0.0, e), t);
    let inv = 1.0 / (2.0 * e);
    return vec2<f32>(dy, -dx) * inv;
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    var uv  = (vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height)) - 0.5;
    uv.x   *= uni.width / uni.height;
    let t   = uni.time * uni.speed;

    let p0 = uv * uni.scale;

    // integrazione indietro per scolpire streamline: la posizione attuale
    // scorre nel campo. Il phase = phase0 + offset, i bordi delle streamline
    // escono da sin(phase * density).
    var p   = p0;
    var acc = 0.0;
    let step = 0.04;
    // 6 passi: fissi, no branching dinamico
    for (var i: i32 = 0; i < 6; i = i + 1) {
        let v = curl2(p, t);
        p = p - v * step;
        acc += dot(v, v);
    }

    // "phase" lungo linee di corrente: usa la coord longitudinale trasportata
    let v0    = curl2(p0, t);
    let speed0 = length(v0) + 1e-3;
    let dir    = v0 / speed0;
    // proietta p0 sulla direzione principale come coordinata lungo il flusso
    let s_along = dot(p0, dir);
    let phase   = s_along * 18.0 + t * 2.0 + acc * 4.0;

    let line = abs(sin(phase));
    // streamline: banda sottile quando line ~ 0
    let stream = 1.0 - smoothstep(0.0, 0.12, line);

    // densità controllata da scale; warp perturba la phase
    let perturb = uni.warp * 0.6 * vnoise(p0 * 2.3 + t * 0.5);
    let phase2  = phase + perturb * 6.28318530718;
    let line2   = abs(sin(phase2));
    let stream2 = 1.0 - smoothstep(0.0, 0.14, line2);

    // colore base dal campo
    let mag  = clamp(speed0 * 0.8, 0.0, 1.0);
    let base = mix(uni.col_a.rgb, uni.col_b.rgb, mag);
    let lit  = mix(base, uni.col_c.rgb, stream2);
    let col  = mix(lit, uni.col_c.rgb, stream * uni.color_mix);

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
