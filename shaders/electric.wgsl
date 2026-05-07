// electric.wgsl — electric arcs / lightning bolts with branching and glow
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

// distance to a lightning bolt between two points
// bolt is distorted by noise; warp controls chaos
fn bolt_dist(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, t: f32,
             chaos: f32, detail: i32) -> f32 {
    let ab = b - a;
    let ab_len = length(ab);
    if (ab_len < 0.001) { return length(p - a); }

    let ab_dir = ab / ab_len;
    let ap = p - a;
    let proj = clamp(dot(ap, ab_dir), 0.0, ab_len);
    let frac_along = proj / ab_len;

    // perpendicular vector
    let perp = vec2<f32>(-ab_dir.y, ab_dir.x);

    // noise displacement along the bolt — flickers with time
    let noise_coord = vec2<f32>(frac_along * 8.0, t * 12.0);
    let displacement = (fbm(noise_coord, detail) - 0.5) * chaos * ab_len * 0.4;

    // the point on the ideal line
    let line_pt = a + ab_dir * proj + perp * displacement;
    return length(p - line_pt);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv  = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let t   = uni.time * uni.speed;
    let oct = max(1, i32(uni.octaves_f + 0.5));

    let aspect = uni.width / uni.height;
    let p = (uv - 0.5) * vec2<f32>(aspect, 1.0);

    // number of bolt sources (2-8 from scale)
    let num_bolts = max(2, i32(uni.scale + 0.5));
    let chaos = uni.warp * 1.5;

    var glow = 0.0;
    var bright_glow = 0.0;

    // generate bolt endpoints that orbit/move
    for (var i = 0; i < num_bolts; i = i + 1) {
        if (i >= 8) { break; }
        let fi = f32(i);
        let angle_a = fi * 2.3998 + t * 0.4;
        let angle_b = fi * 2.3998 + 3.14159 + t * 0.3;
        let ra = 0.25 + 0.1 * sin(t * 0.7 + fi);
        let rb = 0.25 + 0.1 * cos(t * 0.5 + fi * 1.3);

        let pa = vec2<f32>(cos(angle_a) * ra, sin(angle_a) * ra);
        let pb = vec2<f32>(cos(angle_b) * rb, sin(angle_b) * rb);

        // main bolt
        let d = bolt_dist(p, pa, pb, t + fi * 7.13, chaos, oct);

        // core glow — sharp bright center
        let core = exp(-d * d * 8000.0) * 1.5;
        // medium glow
        let med  = exp(-d * d * 800.0) * 0.7;
        // wide glow
        let wide = exp(-d * d * 80.0) * 0.2;

        // flicker: random intensity per bolt per frame
        let flicker = 0.5 + 0.5 * sin(t * 30.0 + fi * 17.3 + sin(t * 7.0 + fi));

        bright_glow += core * flicker;
        glow += (med + wide) * flicker;

        // secondary branch bolt (from midpoint outward)
        if (oct >= 3) {
            let mid = (pa + pb) * 0.5;
            let branch_angle = t * 0.6 + fi * 4.1;
            let branch_end = mid + vec2<f32>(cos(branch_angle), sin(branch_angle)) * 0.15;
            let d2 = bolt_dist(p, mid, branch_end, t + fi * 3.7 + 100.0, chaos * 1.3, max(oct - 1, 1));
            let branch_core = exp(-d2 * d2 * 4000.0) * 0.8;
            let branch_wide = exp(-d2 * d2 * 200.0) * 0.3;
            bright_glow += branch_core * flicker * 0.6;
            glow += branch_wide * flicker * 0.5;
        }
    }

    // spark particles near bolts
    let spark_grid = floor(p * 60.0);
    let spark_hash = hash21(spark_grid + vec2<f32>(floor(t * 15.0)));
    let spark = step(0.96, spark_hash) * glow * 5.0;

    // color: white-blue electric vs purple-pink plasma
    let electric_color = vec3<f32>(0.7, 0.8, 1.0);
    let plasma_color   = mix(uni.col_b.rgb, uni.col_c.rgb, 0.5);
    let bolt_color = mix(electric_color, plasma_color, uni.color_mix);

    // white hot core
    let white = vec3<f32>(1.0, 1.0, 1.0);

    var col = uni.col_a.rgb;
    col += bolt_color * glow;
    col += white * bright_glow;
    col += bolt_color * spark;

    // subtle background electrical haze
    let haze = fbm(p * 3.0 + vec2<f32>(t * 0.1), 2) * 0.03;
    col += bolt_color * haze;

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
