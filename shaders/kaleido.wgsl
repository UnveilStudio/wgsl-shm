// kaleido.wgsl — kaleidoscope N settori su base fbm cheap, workgroup 16x16

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

fn fbm2(p: vec2<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    v += a * vnoise(q); q = q * 2.0 + vec2<f32>(1.7, 9.2); a *= 0.5;
    v += a * vnoise(q); q = q * 2.0 + vec2<f32>(1.7, 9.2); a *= 0.5;
    v += a * vnoise(q);
    return v;
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    var uv  = (vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height)) - 0.5;
    uv.x   *= uni.width / uni.height;
    let t   = uni.time * uni.speed;

    // N settori da octaves_f, clamp 3..12
    let nf      = clamp(uni.octaves_f, 3.0, 12.0);
    let sectors = max(3.0, floor(nf + 0.5));

    let r   = length(uv);
    var ang = atan2(uv.y, uv.x);
    ang    += t * 0.25;

    let seg = 6.28318530718 / sectors;
    // fold simmetrico
    var a = ang - seg * floor(ang / seg);
    a = abs(a - seg * 0.5);

    // warp radiale
    let rw = r + uni.warp * 0.12 * sin(a * sectors * 0.5 + t);

    let p  = vec2<f32>(cos(a), sin(a)) * rw * uni.scale;
    let pw = p + uni.warp * 0.6 * vec2<f32>(
        sin(t * 0.7 + p.y),
        cos(t * 0.5 + p.x)
    );

    let n1 = fbm2(pw);
    let n2 = fbm2(pw * 1.7 + vec2<f32>(3.1, -2.4));

    // blend angolare: color_mix pesa la fetta rispetto al radiale
    let ang_blend = 0.5 + 0.5 * cos(a * sectors);
    let radial    = smoothstep(0.0, 0.8, rw);

    let c_ring = mix(uni.col_a.rgb, uni.col_b.rgb, clamp(n1, 0.0, 1.0));
    let c_star = mix(uni.col_b.rgb, uni.col_c.rgb, clamp(n2, 0.0, 1.0));
    let base   = mix(c_ring, c_star, ang_blend * uni.color_mix + (1.0 - uni.color_mix) * radial);

    // vignetting morbido
    let vg = 1.0 - smoothstep(0.55, 0.95, r);
    let col = base * (0.35 + 0.65 * vg);

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
