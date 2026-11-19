// sim/shaders: the swarm's WGSL, one program in a `wgsl` block (the
// extension gpu/syntax). Its structs are what main.slang fills the buffers
// with (Uniforms by its members' names), its variables are bound by their
// names, and each pipeline runs one of its entry points.
extension "gpu/syntax"

wgsl swarm {
  struct Particle {
    pos: vec2f,
    vel: vec2f,
  }

  struct Uniforms {
    mouse: vec2f, // the cursor, in world units (x from -aspect to aspect)
    aspect: f32,
    time: f32,
    dt: f32,
    force: f32, // 1 pulls toward the cursor, -1 pushes away
    burst: f32, // > 0 for one frame: a shock wave from the cursor
    flow: f32, // how strongly the flow field steers
    exposure: f32,
    palette: f32,
    size: f32,
  }

  @group(0) @binding(0) var<uniform> u: Uniforms;
  // the particles: written by the simulation, read (as `shown`) to draw them
  @group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
  @group(0) @binding(2) var<storage, read> shown: array<Particle>;
  @group(0) @binding(3) var<storage, read_write> energy: atomic<u32>;
  @group(0) @binding(4) var hdr: texture_2d<f32>;

  // ---- the simulation: `seed` scatters the particles, `step` moves them
  // through a flow field toward or away from the cursor and adds up their
  // kinetic energy (one particle in 64) for the sound

  fn hash(n: u32) -> f32 {
    var x = n * 747796405u + 2891336453u;
    x = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    x = (x >> 22u) ^ x;
    return f32(x) / 4294967295.0;
  }

  @compute @workgroup_size(256)
  fn seed(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    if (i >= arrayLength(&particles)) {
      return;
    }
    if (i == 0u) {
      atomicStore(&energy, 0u);
    }
    let s = u32(u.time * 1000.0);
    let angle = hash(i * 2u + s) * 6.2831853;
    let radius = sqrt(hash(i * 2u + 1u + s)) * 0.9;
    particles[i].pos = vec2f(cos(angle) * radius, sin(angle) * radius);
    particles[i].vel = vec2f(0.0);
  }

  // a cheap divergence-free-looking field of drifting sine waves
  fn flow_at(p: vec2f, t: f32) -> vec2f {
    return vec2f(
      sin(p.y * 3.1 + t * 0.40) + 0.5 * sin(p.y * 7.3 - t * 0.90 + p.x),
      cos(p.x * 2.7 - t * 0.30) + 0.5 * cos(p.x * 6.1 + t * 0.70 - p.y),
    );
  }

  @compute @workgroup_size(256)
  fn step(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    if (i >= arrayLength(&particles)) {
      return;
    }
    var p = particles[i];
    var acc = flow_at(p.pos, u.time) * u.flow;
    let d = u.mouse - p.pos;
    let r2 = dot(d, d) + 0.002;
    acc += u.force * d / r2 * 0.25;
    if (u.burst > 0.0) {
      acc -= d / r2 * u.burst / (1.0 + r2 * 30.0);
    }
    p.vel = p.vel * exp(-1.6 * u.dt) + acc * u.dt;
    p.pos += p.vel * u.dt;
    // the edges wrap around
    let half = vec2f(u.aspect, 1.0);
    p.pos = (fract((p.pos + half) / (2.0 * half)) * 2.0 - 1.0) * half;
    particles[i] = p;
    if ((i & 63u) == 0u) {
      atomicAdd(&energy, u32(min(dot(p.vel, p.vel), 50.0) * 1000.0));
    }
  }

  // ---- drawing: every particle an additive soft dot, an instance of a
  // 4-vertex strip read straight from the simulation's storage buffer, into
  // an HDR (rgba16float) target

  struct Out {
    @builtin(position) position: vec4f,
    @location(0) corner: vec2f,
    @location(1) color: vec3f,
  }

  fn palette(speed: f32, which: f32) -> vec3f {
    let s = clamp(speed * 0.6, 0.0, 1.0);
    if (which < 0.5) {
      return mix(vec3f(0.10, 0.25, 1.00), vec3f(1.00, 0.55, 0.15), s); // ember
    } else if (which < 1.5) {
      return mix(vec3f(0.05, 0.80, 0.55), vec3f(0.95, 0.20, 0.80), s); // aurora
    }
    return mix(vec3f(0.60, 0.65, 0.70), vec3f(1.00, 1.00, 1.00), s); // silver
  }

  @vertex
  fn draw_vs(
    @builtin(vertex_index) v: u32,
    @builtin(instance_index) i: u32,
  ) -> Out {
    let p = shown[i];
    let corner = vec2f(f32(v & 1u), f32(v >> 1u)) * 2.0 - 1.0;
    let at = p.pos + corner * u.size;
    var out: Out;
    out.position = vec4f(at.x / u.aspect, at.y, 0.0, 1.0);
    out.corner = corner;
    out.color = palette(length(p.vel), u.palette);
    return out;
  }

  @fragment
  fn draw_fs(in: Out) -> @location(0) vec4f {
    let falloff = max(1.0 - dot(in.corner, in.corner), 0.0);
    return vec4f(in.color * falloff * falloff * 0.06, 1.0);
  }

  // ---- the HDR target onto the screen: exposure, a filmic curve, a
  // vignette

  @vertex
  fn tone_vs(@builtin(vertex_index) v: u32) -> @builtin(position) vec4f {
    let p = array(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    return vec4f(p[v], 0.0, 1.0);
  }

  @fragment
  fn tone_fs(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let size = vec2f(textureDimensions(hdr));
    let c = textureLoad(hdr, vec2i(at.xy), 0).rgb * u.exposure;
    let mapped = vec3f(1.0) - exp(-c);
    let q = at.xy / size - 0.5;
    let vignette = 1.0 - dot(q, q) * 0.8;
    return vec4f(mapped * vignette, 1.0);
  }
}

return swarm
