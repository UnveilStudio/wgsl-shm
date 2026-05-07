// galaxy.wgsl — spiral galaxy with rotating arms, star particles, glowing core
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

// --- hash / noise helpers ---------------------------------------------------

fn hash21(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(127.1, 311.7));
    q += dot(q, q + 19.19);
    return fract(q.x * q.y);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)),
                      dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
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

// --- galaxy core ------------------------------------------------------------

fn spiral_density(r: f32, theta: f32, arms: f32, tightness: f32, t: f32) -> f32 {
    // logarithmic spiral: theta = tightness * ln(r)
    let spiral_angle = tightness * log(max(r, 0.001));
    let arm_phase = theta * arms - spiral_angle + t;
    // smooth arm shape
    let arm = pow(0.5 + 0.5 * cos(arm_phase), 3.0);
    return arm;
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let uv  = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let t   = uni.time * uni.speed;
    let oct = max(1, i32(uni.octaves_f + 0.5));

    // center and aspect-correct
    let aspect = uni.width / uni.height;
    var p = (uv - 0.5) * vec2<f32>(aspect, 1.0);

    // polar coords
    let r     = length(p);
    let theta = atan2(p.y, p.x);

    // number of arms from scale (2-6 range mapped nicely)
    let arms = floor(uni.scale + 0.5);
    // tightness from warp (higher = tighter wound spiral)
    let tightness = 2.0 + uni.warp * 8.0;

    // galaxy rotation
    let rot_angle = t * 0.3;
    let rot_theta = theta + rot_angle;

    // spiral arm density
    let arm_density = spiral_density(r, rot_theta, arms, tightness, 0.0);

    // add secondary thin arms offset by half
    let arm2 = spiral_density(r, rot_theta, arms, tightness * 1.3, 3.14159 / arms);

    // combined arm structure
    let arm_total = max(arm_density, arm2 * 0.4);

    // star field noise — detail controlled by octaves
    let star_noise = fbm(p * 20.0 + vec2<f32>(t * 0.1, 0.0), oct);

    // individual bright stars: use high-frequency hash
    let star_grid = floor(p * 80.0);
    let star_hash = hash21(star_grid);
    let star_pos  = hash22(star_grid);
    let star_dist = length(fract(p * 80.0) - star_pos);
    let star_brightness = smoothstep(0.05, 0.0, star_dist) * step(0.92, star_hash);

    // dust lanes between arms (darkening in between)
    let dust = fbm(p * 12.0 + vec2<f32>(t * 0.05), max(oct - 1, 1));
    let dust_lane = smoothstep(0.3, 0.6, dust) * 0.6;

    // radial falloff — galaxy has finite extent
    let radial_falloff = exp(-r * r * 3.5);
    // bright core
    let core_glow = exp(-r * r * 40.0) * 2.0;
    // intermediate bulge
    let bulge = exp(-r * r * 12.0) * 0.8;

    // density combines arms + core + stars
    let arm_contrib = arm_total * radial_falloff * (1.0 - dust_lane * 0.5);
    let star_contrib = (star_noise * 0.3 + star_brightness * 2.0) * radial_falloff;
    let density = arm_contrib * 0.7 + star_contrib * 0.3 + core_glow + bulge;

    // color: core is warm (col_b toward gold), outer is cool (col_c toward blue)
    // color_mix shifts the balance
    let core_color = mix(uni.col_b.rgb, uni.col_b.rgb * vec3<f32>(1.2, 1.0, 0.6), 0.5);
    let arm_color  = mix(uni.col_c.rgb, uni.col_b.rgb, uni.color_mix);
    let bg_color   = uni.col_a.rgb;

    // blend based on radius and density
    let color_t = smoothstep(0.0, 0.3, r);
    var galaxy_color = mix(core_color, arm_color, color_t);

    // stars are always bright white-blue
    let star_color = vec3<f32>(0.8, 0.85, 1.0);
    galaxy_color = mix(galaxy_color, star_color, clamp(star_brightness * 3.0, 0.0, 0.7));

    // final composite
    var col = bg_color + galaxy_color * density;

    // subtle tonal shift with fbm for organic feel
    let tone_shift = fbm(p * 5.0 + vec2<f32>(t * 0.02), 2);
    col = mix(col, col * mix(vec3<f32>(1.0, 0.9, 0.8), vec3<f32>(0.8, 0.9, 1.0), tone_shift), 0.15);

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
