// ── SDF Raymarcher — Morphing Geometric Sculpture ────────────────────
// Smooth-blended SDF primitives (sphere, torus, octahedron) with
// Phong lighting, AO approximation, rim light, and shape repetition.
// Designed for sound-reactive performance on Radeon 880M @ 4K.
// ─────────────────────────────────────────────────────────────────────

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

// ── SDF primitives ───────────────────────────────────────────────────

fn sd_sphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn sd_torus(p: vec3<f32>, major: f32, minor: f32) -> f32 {
    let q = vec2<f32>(length(p.xz) - major, p.y);
    return length(q) - minor;
}

fn sd_octahedron(p: vec3<f32>, s: f32) -> f32 {
    let ap = abs(p);
    let m  = ap.x + ap.y + ap.z - s;
    var q: vec3<f32>;
    if (3.0 * ap.x < m) {
        q = ap;
    } else if (3.0 * ap.y < m) {
        q = vec3<f32>(ap.y, ap.z, ap.x);
    } else if (3.0 * ap.z < m) {
        q = vec3<f32>(ap.z, ap.x, ap.y);
    } else {
        return m * 0.57735027;
    }
    let k = clamp(0.5 * (q.z - q.y + s), 0.0, s);
    return length(vec3<f32>(q.x, q.y - s + k, q.z - k));
}

fn sd_box(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// smooth minimum for organic blending
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// rotation matrices
fn rot2(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, s, -s, c);
}

// ── scene SDF ────────────────────────────────────────────────────────

fn map(pos: vec3<f32>, t: f32) -> f32 {
    let warp = uni.warp;
    let reps = max(i32(uni.octaves_f), 1);

    // morphing rotation
    var p = pos;
    let r_xz = rot2(t * 0.3 + warp * sin(t * 0.7));
    let r_yz = rot2(t * 0.2 + warp * cos(t * 0.5));
    let pxz  = r_xz * p.xz;
    p = vec3<f32>(pxz.x, p.y, pxz.y);
    let pyz  = r_yz * p.yz;
    p = vec3<f32>(p.x, pyz.x, pyz.y);

    // morph weights cycle over time
    let phase  = t * 0.4;
    let w_sph  = smoothstep(-0.3, 0.3, sin(phase));
    let w_tor  = smoothstep(-0.3, 0.3, sin(phase + 2.094));
    let w_oct  = smoothstep(-0.3, 0.3, sin(phase + 4.189));
    let w_sum  = w_sph + w_tor + w_oct + 0.001;

    // base primitives
    let d_sph = sd_sphere(p, 0.8);
    let d_tor = sd_torus(p, 0.6, 0.25);
    let d_oct = sd_octahedron(p, 1.0);

    // weighted smooth blend
    let blend_k = 0.3 + warp * 0.5;
    var d = d_sph;
    d = smin(d, d_tor, blend_k);
    d = smin(d, d_oct, blend_k);

    // mix based on morph weights for bias
    let biased = (d_sph * w_sph + d_tor * w_tor + d_oct * w_oct) / w_sum;
    d = mix(d, biased, 0.5);

    // domain repetition for arrayed shapes
    if (reps > 1) {
        let spacing = 3.5;
        for (var i = 1; i < reps; i++) {
            if (i >= 6) { break; } // cap for perf
            let fi    = f32(i);
            let angle = fi * 6.2831853 / f32(reps);
            let offset = vec3<f32>(cos(angle), sin(angle * 0.5 + t * 0.2), sin(angle)) * spacing * 0.5;
            let rep_p = pos - offset;

            let rxz = rot2(t * 0.2 + fi);
            let rp_xz = rxz * rep_p.xz;
            let rp = vec3<f32>(rp_xz.x, rep_p.y, rp_xz.y);

            let rd = smin(sd_sphere(rp, 0.5), sd_octahedron(rp, 0.6), blend_k);
            d = smin(d, rd, blend_k * 0.7);
        }
    }

    // subtle displacement for organic feel
    d += sin(pos.x * 4.0 + t) * sin(pos.y * 4.0 + t * 1.3) * sin(pos.z * 4.0 + t * 0.7) * warp * 0.04;

    return d;
}

// ── normal via central differences ───────────────────────────────────

fn calc_normal(p: vec3<f32>, t: f32) -> vec3<f32> {
    let e = 0.001;
    let d = map(p, t);
    return normalize(vec3<f32>(
        map(p + vec3<f32>(e, 0.0, 0.0), t) - d,
        map(p + vec3<f32>(0.0, e, 0.0), t) - d,
        map(p + vec3<f32>(0.0, 0.0, e), t) - d
    ));
}

// ── approximate AO ───────────────────────────────────────────────────

fn calc_ao(p: vec3<f32>, n: vec3<f32>, t: f32) -> f32 {
    var occ = 0.0;
    var w   = 1.0;
    for (var i = 1; i <= 5; i++) {
        let dist = f32(i) * 0.06;
        let d    = map(p + n * dist, t);
        occ += (dist - d) * w;
        w *= 0.6;
    }
    return clamp(1.0 - occ * 3.0, 0.0, 1.0);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= u32(uni.width) || gid.y >= u32(uni.height)) { return; }

    let res = vec2<f32>(uni.width, uni.height);
    let uv  = (vec2<f32>(f32(gid.x), f32(gid.y)) - 0.5 * res) / min(res.x, res.y);
    let t   = uni.time * uni.speed;

    // camera setup — scale controls distance
    let cam_dist = 2.5 + uni.scale * 0.5;
    let cam_angle = t * 0.15;
    let ro = vec3<f32>(
        cos(cam_angle) * cam_dist,
        sin(t * 0.1) * 0.8,
        sin(cam_angle) * cam_dist
    );
    let ta = vec3<f32>(0.0, 0.0, 0.0);

    // camera matrix
    let ww = normalize(ta - ro);
    let uu = normalize(cross(ww, vec3<f32>(0.0, 1.0, 0.0)));
    let vv = cross(uu, ww);
    let rd = normalize(uv.x * uu + uv.y * vv + 1.5 * ww);

    // raymarch (max 80 steps for 4K perf)
    var ray_t  = 0.0;
    var hit    = false;
    for (var i = 0; i < 80; i++) {
        let p = ro + rd * ray_t;
        let d = map(p, t);
        if (d < 0.001) {
            hit = true;
            break;
        }
        if (ray_t > 20.0) { break; }
        ray_t += d;
    }

    var col = uni.col_a.rgb * 0.08; // background

    if (hit) {
        let p = ro + rd * ray_t;
        let n = calc_normal(p, t);

        // light setup
        let light_dir  = normalize(vec3<f32>(1.0, 1.2, 0.8));
        let light_dir2 = normalize(vec3<f32>(-0.8, 0.3, -0.6));
        let view_dir   = normalize(ro - p);
        let half_dir   = normalize(light_dir + view_dir);

        // diffuse
        let diff  = max(dot(n, light_dir), 0.0);
        let diff2 = max(dot(n, light_dir2), 0.0) * 0.3;

        // specular — metallicness from color_mix
        let spec_power = mix(16.0, 128.0, uni.color_mix);
        let spec = pow(max(dot(n, half_dir), 0.0), spec_power) * mix(0.5, 2.0, uni.color_mix);

        // fresnel / rim light
        let fresnel = pow(1.0 - max(dot(n, view_dir), 0.0), 3.0);
        let rim     = fresnel * 1.5;

        // AO
        let ao = calc_ao(p, n, t);

        // material color — blend based on normal direction for variety
        let mat_blend = dot(n, vec3<f32>(0.577)) * 0.5 + 0.5;
        let mat_col   = mix(uni.col_b.rgb, uni.col_c.rgb, mat_blend);

        // metallic reflection tint
        let refl_col = mix(vec3<f32>(1.0), mat_col, uni.color_mix);

        // compose
        col = mat_col * (diff + diff2) * ao * 0.6;
        col += refl_col * spec * ao;
        col += uni.col_c.rgb * rim * 0.4;
        col += mat_col * 0.05; // ambient

        // depth fade
        let depth_fade = exp(-ray_t * 0.15);
        col *= depth_fade;
        col = mix(uni.col_a.rgb * 0.08, col, depth_fade);
    } else {
        // background: subtle gradient
        let bg_grad = uv.y * 0.5 + 0.5;
        col = mix(uni.col_a.rgb * 0.06, uni.col_a.rgb * 0.15, bg_grad);

        // faint background glow toward center
        let bg_glow = exp(-dot(uv, uv) * 3.0) * 0.08;
        col += mix(uni.col_b.rgb, uni.col_c.rgb, 0.5) * bg_glow;
    }

    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(col, 1.0));
}
