// ripple.wgsl — onde concentriche multiple con chaos, workgroup 16x16

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


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    var uv  = (vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height)) - 0.5;
    uv.x   *= uni.width / uni.height;
    let t   = uni.time * uni.speed;

    // chaos warp: sposta le sorgenti nello spazio
    let cw = uni.warp * 0.35;
    let n  = vnoise(uv * 3.0 + t * 0.3);
    let uw = uv + cw * (vec2<f32>(n, vnoise(uv * 3.0 - t * 0.27)) - 0.5);

    // 3 sorgenti in rotazione
    let src0 = 0.28 * vec2<f32>(cos(t * 0.31),            sin(t * 0.31));
    let src1 = 0.34 * vec2<f32>(cos(t * 0.23 + 2.094),    sin(t * 0.23 + 2.094));
    let src2 = 0.30 * vec2<f32>(cos(t * 0.19 + 4.188),    sin(t * 0.19 + 4.188));

    let r0 = length(uw - src0);
    let r1 = length(uw - src1);
    let r2 = length(uw - src2);

    let k  = uni.scale * 6.28318530718;
    let w0 = sin(r0 * k - t * 3.0);
    let w1 = sin(r1 * k * 1.13 - t * 2.4 + 1.1);
    let w2 = sin(r2 * k * 0.87 - t * 3.5 + 2.3);

    let sum = (w0 + w1 + w2) * 0.3333;           // [-1, 1]
    let env = 0.5 + 0.5 * sum;                   // [0, 1]
    let crest = env * env * env;                 // picchi accentuati, no pow()

    // color palette con col_c come highlight sulle creste
    let base = mix(uni.col_a.rgb, uni.col_b.rgb, env);
    let mixed = mix(base, uni.col_c.rgb, crest * uni.color_mix);

    // riga sottile di interferenza
    let edge = 1.0 - smoothstep(0.0, 0.08, abs(sum));
    let col  = mixed + uni.col_c.rgb * edge * 0.25;

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
