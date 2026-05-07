// blackhole.wgsl — gravitational lensing + accretion disk, workgroup 16x16 (RDNA3.5 wave32 × 8 waves)

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

// ---- hash & noise for star field --------------------------------------------

fn hash2(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(123.34, 456.21));
    q += dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash2(i);
    let b = hash2(i + vec2<f32>(1.0, 0.0));
    let c = hash2(i + vec2<f32>(0.0, 1.0));
    let d = hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm_stars(p: vec2<f32>, octaves: i32) -> f32 {
    var val = 0.0;
    var amp = 0.5;
    var pos = p;
    for (var i = 0; i < octaves; i++) {
        val += amp * noise2(pos);
        pos *= 2.07;
        amp *= 0.48;
    }
    return val;
}

// ---- star field background --------------------------------------------------

fn star_field(dir: vec2<f32>, octaves: i32) -> vec3<f32> {
    // layered stars at different scales
    var stars = vec3<f32>(0.0);
    let p = dir * 8.0;

    // dense tiny stars
    let n1 = hash2(floor(p * 30.0));
    let bright1 = smoothstep(0.97, 1.0, n1);
    stars += bright1 * 0.6;

    // medium stars
    let n2 = hash2(floor(p * 12.0));
    let bright2 = smoothstep(0.95, 1.0, n2);
    stars += bright2 * vec3<f32>(0.8, 0.85, 1.0);

    // large bright stars (rare)
    let n3 = hash2(floor(p * 5.0));
    let bright3 = smoothstep(0.985, 1.0, n3);
    let star_col = mix(vec3<f32>(1.0, 0.8, 0.6), vec3<f32>(0.6, 0.8, 1.0), hash2(floor(p * 5.0) + 100.0));
    stars += bright3 * star_col * 2.0;

    // nebula background glow
    let nebula = fbm_stars(p * 0.5, octaves) * 0.15;
    stars += uni.col_a.rgb * nebula;

    return stars;
}

// ---- accretion disk ---------------------------------------------------------

fn disk_density(r: f32, angle: f32, t: f32) -> f32 {
    let inner = 2.0 * uni.scale;
    let outer = 6.0 * uni.scale;

    // radial profile: sharp inner edge, gradual outer falloff
    let radial = smoothstep(inner, inner + 0.5, r) * exp(-(r - inner) * 0.4 / uni.scale);

    // spiral arm structure
    let spiral_angle = angle - r * 1.5 + t * 2.0;
    let arms = 0.6 + 0.4 * sin(spiral_angle * 3.0) * sin(spiral_angle * 1.7 + 1.0);

    // turbulence in disk
    let turb = noise2(vec2<f32>(r * 4.0, angle * 2.0 + t)) * 0.4;

    return clamp(radial * arms + turb * radial, 0.0, 1.0);
}

fn disk_color(r: f32, angle: f32, t: f32) -> vec3<f32> {
    let inner = 2.0 * uni.scale;

    // temperature gradient: hotter near center
    let temp = exp(-(r - inner) * 0.5 / uni.scale);

    // hot inner disk (white-blue) -> cooler outer (orange-red)
    let hot = vec3<f32>(1.0, 0.95, 0.9);
    let warm = uni.col_b.rgb;
    let cool = uni.col_c.rgb;

    var col: vec3<f32>;
    if (temp > 0.5) {
        col = mix(warm, hot, (temp - 0.5) * 2.0);
    } else {
        col = mix(cool, warm, temp * 2.0);
    }

    // doppler-like shift: approaching side brighter, receding dimmer
    let doppler = 1.0 + 0.4 * sin(angle + t * uni.speed * 3.0);
    col *= doppler * (0.5 + uni.color_mix * 1.5);

    return col;
}

// ---- gravitational lensing (simplified Schwarzschild) -----------------------

fn lens_deflection(r: f32) -> f32 {
    // Schwarzschild-like deflection angle
    // Stronger near the photon sphere (r ~ 1.5 * rs)
    let rs = 1.0 * uni.warp;  // Schwarzschild radius scales with warp
    let deflection = rs * rs / (r * r + 0.01);
    return deflection;
}

// ---- photon ring glow -------------------------------------------------------

fn photon_ring(r: f32) -> f32 {
    let ring_r = 1.5 * uni.warp;  // photon sphere
    let dist = abs(r - ring_r);
    return exp(-dist * dist * 20.0) * 2.0;
}

// ---- main -------------------------------------------------------------------

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let aspect = uni.width / uni.height;
    let uv = (vec2<f32>(f32(gid.x), f32(gid.y)) / vec2<f32>(uni.width, uni.height) - 0.5)
             * vec2<f32>(aspect, 1.0) * 8.0;

    let t = uni.time * uni.speed;
    let octaves = clamp(i32(uni.octaves_f), 1, 7);

    // ---- ray from pixel ----
    let r = length(uv);
    let angle = atan2(uv.y, uv.x);

    // ---- gravitational deflection ----
    let deflect = lens_deflection(r);
    let deflected_r = r + deflect * 3.0;

    // bent direction for background lookup
    let bent_angle = angle + deflect * 1.2 * sign(sin(angle * 2.0 + t * 0.1));
    let bent_uv = vec2<f32>(cos(bent_angle), sin(bent_angle)) * deflected_r;

    // ---- accumulate color ----
    var col = vec3<f32>(0.0);

    // ---- black hole shadow (event horizon) ----
    let event_horizon = 1.0 * uni.warp;
    let shadow = smoothstep(event_horizon, event_horizon + 0.3, r);

    // ---- background star field (gravitationally lensed) ----
    let bg_stars = star_field(bent_uv * 0.15, octaves);
    col += bg_stars * shadow;

    // ---- einstein ring glow at critical deflection ----
    let einstein_r = 2.5 * uni.warp;
    let einstein_glow = exp(-pow(r - einstein_r, 2.0) * 4.0) * 0.6;
    col += (uni.col_b.rgb + uni.col_c.rgb) * 0.5 * einstein_glow * shadow;

    // ---- accretion disk ----
    // disk is in the plane: we see it from a slight inclination
    let incline = 0.35;  // viewing angle from disk plane
    let disk_y = uv.y / (incline + 0.01);
    let disk_r = length(vec2<f32>(uv.x, disk_y));
    let disk_angle = atan2(disk_y, uv.x);

    // front of disk (above BH)
    let d_front = disk_density(disk_r, disk_angle, t);
    let c_front = disk_color(disk_r, disk_angle, t);
    col += c_front * d_front * shadow * 2.0;

    // back of disk (gravitationally lensed over the top)
    let back_y = -uv.y / (incline + 0.01);
    let back_r = length(vec2<f32>(uv.x, back_y));
    let back_angle = atan2(back_y, uv.x);
    let lens_boost = smoothstep(event_horizon, event_horizon + 2.0, r);
    let d_back = disk_density(back_r + 1.0, back_angle + 3.14159, t) * lens_boost;
    let c_back = disk_color(back_r + 1.0, back_angle + 3.14159, t);
    // lensed back-disk appears compressed near the top
    let back_vis = smoothstep(0.0, 0.5, abs(uv.y)) * (1.0 - smoothstep(1.5 * uni.warp, 3.0 * uni.warp, r));
    col += c_back * d_back * 0.7 * back_vis;

    // ---- photon ring ----
    let pr = photon_ring(r);
    col += (uni.col_b.rgb * 0.7 + vec3<f32>(1.0, 0.9, 0.7) * 0.3) * pr * shadow;

    // ---- inner glow at event horizon edge ----
    let horizon_glow = exp(-(r - event_horizon) * (r - event_horizon) * 10.0);
    col += uni.col_c.rgb * horizon_glow * 0.5;

    // ---- subtle bloom via radial desaturation ----
    let bloom = exp(-r * 0.15) * 0.08;
    col += (uni.col_b.rgb + uni.col_c.rgb) * bloom;

    // ---- tonemap + gamma ----
    col = max(col, vec3<f32>(0.0));
    let mapped = 1.0 - exp(-col * 1.5);
    let final_col = pow(mapped, vec3<f32>(1.0 / 2.2));

    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(final_col, 1.0));
}
