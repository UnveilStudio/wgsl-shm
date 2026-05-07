// voronoi.wgsl — celle Worley animate, workgroup 16x16

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


fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(
        dot(p, vec2<f32>(127.1, 311.7)),
        dot(p, vec2<f32>(269.5, 183.3))
    );
    return fract(sin(q) * 43758.5453);
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    var uv  = (vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height)) - 0.5;
    uv.x   *= uni.width / uni.height;
    let t   = uni.time * uni.speed;

    // warp dolce per distorsione bordi
    let w = uni.warp * 0.35;
    let uvw = uv + w * vec2<f32>(
        sin(uv.y * 3.1 + t * 0.7),
        cos(uv.x * 2.7 - t * 0.6)
    );

    let p = uvw * uni.scale;
    let ip = floor(p);
    let fp = fract(p);

    var d1 = 1.0e9;
    var d2 = 1.0e9;

    for (var j: i32 = -1; j <= 1; j = j + 1) {
        for (var i: i32 = -1; i <= 1; i = i + 1) {
            let g  = vec2<f32>(f32(i), f32(j));
            let o  = hash2(ip + g);
            let wob = 0.5 + 0.5 * sin(t + 6.2831 * (o.x + o.y));
            let r  = g + o * wob - fp;
            let d  = dot(r, r);
            if (d < d1) {
                d2 = d1;
                d1 = d;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }

    d1 = sqrt(d1);
    d2 = sqrt(d2);

    let edge = clamp(d2 - d1, 0.0, 1.0);
    let cell = clamp(d1, 0.0, 1.0);
    let glow = 1.0 - smoothstep(0.0, 0.35, edge);

    let base = mix(uni.col_a.rgb, uni.col_b.rgb, cell);
    let lit  = mix(base, uni.col_c.rgb, glow * uni.color_mix);
    let col  = lit + uni.col_c.rgb * glow * glow * 0.4;

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
