// truchet.wgsl — curve Truchet rotanti con subdivision, workgroup 16x16

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

// distanza al pattern Truchet per una singola cella (due quarti di cerchio)
fn truchet_cell(f: vec2<f32>, h: f32) -> f32 {
    var uv = f;
    if (h > 0.5) {
        uv.x = 1.0 - uv.x;
    }
    let d1 = abs(length(uv) - 0.5);
    let d2 = abs(length(uv - vec2<f32>(1.0, 1.0)) - 0.5);
    return min(d1, d2);
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    var uv  = (vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height)) - 0.5;
    uv.x   *= uni.width / uni.height;
    let t   = uni.time * uni.speed;

    // rotazione globale lenta
    let ang = t * 0.15;
    let cs  = cos(ang);
    let sn  = sin(ang);
    let rot = mat2x2<f32>(cs, -sn, sn, cs);
    uv = rot * uv;

    // warp: spinta radiale ondulata
    let rlen = length(uv);
    uv += uni.warp * 0.25 * vec2<f32>(
        sin(uv.y * 4.0 + t),
        cos(uv.x * 4.0 - t)
    ) * (0.2 + rlen);

    let oct = max(1, i32(uni.octaves_f + 0.5));

    var accum = 0.0;
    var amp   = 1.0;
    var p     = uv * uni.scale;

    for (var i: i32 = 0; i < oct; i = i + 1) {
        let ip = floor(p);
        let fp = fract(p);
        let h  = hash(ip + f32(i) * 7.13);
        let d  = truchet_cell(fp, h);
        let line = 1.0 - smoothstep(0.02, 0.08, d);
        accum += line * amp;
        p = p * 2.0 + vec2<f32>(1.7, 9.2);
        amp *= 0.55;
    }

    accum = clamp(accum, 0.0, 1.5);

    let bg  = mix(uni.col_a.rgb, uni.col_b.rgb, 0.5 + 0.5 * sin(rlen * 6.0 - t));
    let fg  = mix(uni.col_c.rgb, uni.col_b.rgb, uni.color_mix);
    let col = mix(bg, fg, clamp(accum, 0.0, 1.0));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
