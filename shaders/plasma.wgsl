// plasma.wgsl — fbm plasma parametrico, workgroup 16x16 (RDNA3.5 wave32 × 8 waves)

struct Uni {
    time        : f32,
    width       : f32,
    height      : f32,
    scale       : f32,

    warp        : f32,
    speed       : f32,
    color_mix   : f32,
    octaves_f   : f32,   // cast a int dentro shader (allineamento 16B)

    col_a       : vec4<f32>,
    col_b       : vec4<f32>,
    col_c       : vec4<f32>,
};
// sizeof = 16 + 16 + 16 + 16 + 16 = 80 byte? Let me recount:
//   time,width,height,scale        = 16
//   warp,speed,color_mix,octaves_f = 16
//   col_a (vec4)                    = 16
//   col_b (vec4)                    = 16
//   col_c (vec4)                    = 16
// total = 80 byte

@group(0) @binding(0) var<uniform>              uni     : Uni;
@group(0) @binding(1) var                       out_tex : texture_storage_2d<rgba8unorm, write>;


fn hash(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(127.1, 311.7));
    q += dot(q, q + 19.19);
    return fract(q.x * q.y);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i + vec2<f32>(0.0, 0.0)), hash(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash(i + vec2<f32>(0.0, 1.0)), hash(i + vec2<f32>(1.0, 1.0)), u.x),
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


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv  = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let t   = uni.time * uni.speed;
    let oct = max(1, i32(uni.octaves_f + 0.5));

    let p = uv * uni.scale;

    let q = vec2<f32>(
        fbm(p + vec2<f32>(0.0, 0.0), oct),
        fbm(p + vec2<f32>(5.2, 1.3), oct)
    );
    let r = vec2<f32>(
        fbm(p + uni.warp * 4.0 * q + vec2<f32>(1.7, 9.2) + 0.15  * t, oct),
        fbm(p + uni.warp * 4.0 * q + vec2<f32>(8.3, 2.8) + 0.126 * t, oct)
    );
    let f = fbm(p + 4.0 * r, oct);

    let col = mix(
        mix(uni.col_a.rgb, uni.col_b.rgb, clamp(f * f * 4.0, 0.0, 1.0)),
        mix(uni.col_b.rgb, uni.col_c.rgb, clamp(length(q), 0.0, 1.0)),
        clamp(f * 2.5 - 0.5 + uni.color_mix - 0.5, 0.0, 1.0)
    );

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
