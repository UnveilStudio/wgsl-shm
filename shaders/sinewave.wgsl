// sinewave.wgsl — layered sine wave interference patterns with standing wave nodes
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

fn hash21(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(127.1, 311.7));
    q += dot(q, q + 19.19);
    return fract(q.x * q.y);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv  = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let t   = uni.time * uni.speed;
    let num_sources = max(2, i32(uni.octaves_f + 0.5));

    let aspect = uni.width / uni.height;
    let p = (uv - 0.5) * vec2<f32>(aspect, 1.0);

    let freq = uni.scale * 15.0;    // frequency/wavelength
    let amp  = uni.warp;            // wave amplitude — perfect for audio!

    // --- wave field from multiple point sources ---
    var wave_sum   = 0.0;
    var wave_abs   = 0.0;
    var wave_color = 0.0;

    for (var i = 0; i < num_sources; i = i + 1) {
        if (i >= 7) { break; }
        let fi = f32(i);

        // source positions orbit slowly
        let angle = fi * 2.3998 + t * 0.2 * (1.0 + fi * 0.1);
        let radius = 0.15 + 0.1 * sin(t * 0.3 + fi * 1.7);
        let source = vec2<f32>(cos(angle) * radius, sin(angle) * radius);

        let d = length(p - source);

        // circular wave from this source
        let wave = sin(d * freq - t * 5.0 + fi * 1.5) * amp;

        // accumulate for interference
        wave_sum += wave;
        wave_abs += abs(wave);

        // per-source color contribution (for moire effect)
        wave_color += wave * (fi + 1.0) / f32(num_sources);
    }

    // normalize by number of sources
    let n = f32(num_sources);
    wave_sum /= n;
    wave_abs /= n;

    // --- interference pattern modes (blended by color_mix) ---

    // mode 1: constructive/destructive interference — raw wave sum
    let interference = 0.5 + 0.5 * wave_sum / max(amp, 0.01);

    // mode 2: energy pattern (absolute interference)
    let energy = wave_abs / max(amp, 0.01);

    // mode 3: standing wave nodes — where amplitude is near zero
    let node_proximity = 1.0 - smoothstep(0.0, 0.15 * amp, abs(wave_sum));

    // blend modes with color_mix
    let pattern = mix(interference, energy, uni.color_mix);

    // --- coloring ---

    // base color from interference pattern
    let t1 = clamp(pattern, 0.0, 1.0);
    var col = mix(uni.col_a.rgb, uni.col_b.rgb, t1);

    // add col_c at high-energy constructive interference
    let constructive = smoothstep(0.7, 1.0, interference);
    col = mix(col, uni.col_c.rgb, constructive * 0.6);

    // standing wave nodes glow — bright white/highlight at nodes
    let node_color = mix(uni.col_c.rgb, vec3<f32>(1.0, 1.0, 1.0), 0.5);
    col = mix(col, node_color, node_proximity * 0.8);

    // moire-like banding from wave_color phase
    let moire = 0.5 + 0.5 * sin(wave_color * 20.0);
    col = mix(col, col * (0.8 + 0.4 * moire), 0.2);

    // radial dimming — waves decay from center area
    let r = length(p);
    let vignette = 1.0 - smoothstep(0.3, 0.8, r);
    col *= 0.4 + 0.6 * vignette;

    // subtle scan-line / oscilloscope aesthetic
    let scanline = 0.95 + 0.05 * sin(uv.y * uni.height * 0.5);
    col *= scanline;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
