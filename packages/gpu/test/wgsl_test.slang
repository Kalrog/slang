// WGSL in slang files: the grammar (gpu/wgsl) on what is hard to parse in
// the language, and `wgsl name { }` blocks (gpu/syntax): run, formatted,
// highlighted, and their compiler's errors at the file's lines.
extension "gpu/syntax"
local t = require("slang/test")
local os = require("slang/os")
local path = require("slang/path")
local str = require("slang/string")
local format = require("slang/format")
local compiler = require("slang/compiler")
local wgsl = require("gpu/wgsl")
local gpu = require("gpu")
local buffer = require("slang/buffer")

// the package's directory (where the tests run), and this file
local here = __PACKAGES.search_paths[0]
local this_file = path.join(here, "test/wgsl_test.slang")
if(not os.exists(this_file)){
  this_file = path.join(here, "wgsl_test.slang")
}

wgsl doubler {
  /* the numbers, doubled /* in place */ */
  @group(0) @binding(0) var<storage, read_write> v: array<f32>;

  @compute @workgroup_size(64)
  fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x < arrayLength(&v)) {
      v[id.x] = v[id.x] * 2.0; // each of them
    }
  }
}

wgsl mistaken {
  @compute @workgroup_size(1)
  fn main() {
    let wrong: u32 = 1.5;
  }
}

// a program with what slang reads of one: structs of every shape, a
// constant, resources, and entry points of every stage
wgsl scene {
  const LIGHTS = 2;
  const N: u32 = LIGHTS + 1u;

  struct Light {
    position: vec3f,
    power: f32,
    color: vec3f,
  }
  struct Uniforms {
    size: vec2f,
    time: f32,
    view: mat4x4f,
    normal: mat3x3f,
    lights: array<Light, N>,
    counts: array<u32, 2>,
  }
  struct Particle {
    pos: vec2f,
    vel: vec2f,
  }
  struct Vertex {
    @location(0) position: vec2f,
    @location(1) color: vec3f,
  }
  struct Switches {
    on: bool,
  }

  // (storage: a uniform's arrays must be 16 bytes apart)
  @group(0) @binding(0) var<storage, read> u: Uniforms;
  @group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
  @group(0) @binding(2) var<storage, read_write> total: array<f32>;
  @group(0) @binding(3) var tex: texture_2d<f32>;
  @group(0) @binding(4) var smp: sampler;

  fn moved(i: u32) -> vec2f {
    return particles[i].pos + particles[i].vel * u.time;
  }

  @compute @workgroup_size(4)
  fn step(@builtin(global_invocation_id) id: vec3u) {
    if (id.x < arrayLength(&particles)) {
      particles[id.x].pos = moved(id.x);
    }
  }

  @compute @workgroup_size(1)
  fn sum() {
    var s = 0.0;
    for (var i = 0u; i < arrayLength(&particles); i++) {
      s += particles[i].pos.x;
    }
    total[0] = s;
  }

  struct Colored {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
  }

  @vertex
  fn vs(v: Vertex) -> Colored {
    var out: Colored;
    out.position = vec4f(v.position, 0.0, 1.0);
    out.color = v.color;
    return out;
  }

  @fragment
  fn fs(in: Colored) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
  }

  @fragment
  fn textured() -> @location(0) vec4f {
    return textureSample(tex, smp, vec2f(0.5));
  }
}

// the categories of a source's tokens: "text=category text=category ..."
local func categories(source, file){
  local h = compiler.highlight(source, path.join(here, file), {
    find_project: true,
  })
  local out = {}
  for(let local tk in values(h.tokens)){
    append(out, concat(
      str.substring(source, tk.start, tk.start + tk.length), "=", tk.category
    ))
  }
  return concat(" ", str.join(out, " "), " ")
}

t.group("wgsl: the grammar"){
  t.test("declarations, with their attributes and types"){
    local items = wgsl.parse("""
      enable f16;
      struct Light { @align(16) position: vec3f, color: vec3<f32>, }
      @group(1) @binding(2) var<uniform> lights: array<Light, 4>;
      override scale: f32 = 2.0;
      const N = 4u;
      alias Lights = array<Light, N>;
      @vertex fn vs(@location(0) p: vec3f) -> @builtin(position) vec4f {
        return vec4f(p, 1.0);
      }""")
    local kinds = {}
    for(let local it in values(items)){
      append(kinds, concat(it.k, ":", it.name))
    }
    assert(kinds == {
        "directive:enable",
        "struct:Light",
        "var:lights",
        "override:scale",
        "const:N",
        "alias:Lights",
        "fn:vs",
      }, kinds)
    local light = items[1]
    assert(light.members[0].attributes[0].name == "align")
    assert(light.members[1].type.args[0].name == "f32")
    local lights = items[2]
    assert(lights.attributes[1].name == "binding")
    assert(lights.template[0].name == "uniform" and lights.type.name == "array")
    local vs = items[6]
    assert(vs.attributes[0].name == "vertex" and vs.params[0].name == "p")
    assert(
      vs.ret.name == "vec4f" and vs.ret_attributes[0].args[0].name == "position",
    )
  }
  t.test("< and > are template brackets or operators, as the text says"){
    // (the specification's template list discovery)
    local body = wgsl.parse("""
      fn f() {
        let a = vec2<f32>(1.0, 2.0);
        let b = i < n && n > 1u;
        let c = array<vec4<f32>, 2>();
        let d = x < y;
        let e = (x < y) > false;
        let g = i >> 1u;
        var h: array<u32, (1 << 2)>;
      }""")[0].body.body
    assert(
      body[0].init.k == "call" and body[0].init.callee.args[0].name == "f32",
    )
    assert(
      body[1].init.op == "&&" and body[1].init.l.op == "<" and
        body[1].init.r.op == ">",
    )
    assert(body[2].init.callee.args[0].args[0].name == "f32")
    assert(
      body[3].init.op == "<" and body[4].init.op == ">" and
        body[5].init.op == ">>",
    )
    assert(body[6].type.args[1].k == "paren")
  }
  t.test("comments nest; names are Unicode's; numbers have their suffixes"){
    local items = wgsl.parse("""
      /* a /* nested */ comment */ const Δέλτα = 0x1p4f; // and one to the line's end
      const b = 1.5e3 + 2u - 3i + 0xFFu + .5 + 5.;""")
    assert(items[0].name == "Δέλτα" and items[0].init.text == "0x1p4f")
    assert(len(items) == 2)
  }
  t.test("a mistake is a compile error at its line"){
    local e = t.raises(func(){
      wgsl.parse("struct A { x: f32 }\nfn f() {\n  let = 3;\n}", "shader")
    })
    assert(e.kind == error.kinds.compile and e.line == 3, e)
    assert(str.starts_with(e.message, "shader:3: "), e.message)
  }
}

t.group("wgsl: blocks in slang files"){
  t.test("a block is a program for the device"){
    local device = gpu.device()
    local pipeline = device:compute_pipeline({shader: device:shader(doubler)})
    local data = device:buffer({contents: {1, 2, 3}, usage: "storage|copy_src"})
    local encoder = device:encoder()
    local pass = encoder:compute_pass()
    pass:set_pipeline(pipeline)
    pass:set_bind_group(0, device:bind_group({
      layout: pipeline:bind_group_layout(0),
      entries: {{binding: 0, resource: data}},
    }))
    pass:dispatch_workgroups(1)
    pass:finish()
    device.queue:submit(encoder:finish())
    assert(data:read("float"):to_list() == {2.0, 4.0, 6.0})
  }
  t.test("the WGSL compiler speaks of the file's lines and columns"){
    // (wgpu's compiler says where; a browser's says so later and elsewhere)
    if(gpu.version() != "browser"){
      local source = str.split(os.read_file(this_file), "\n")
      local line = 0
      for(local i = 0; i < len(source); i = i + 1){
        if(str.contains(source[i], "let wrong: u32") and line == 0){
          line = i + 1
        }
      }
      local e = t.raises(func(){
        gpu.device():shader(mistaken)
      })
      local column = str.index_of(source[line - 1], "wrong") + 1
      assert(str.contains(
        e.message,
        concat("wgsl:", string(line), ":", string(column)),
      ), e.message)
    }
  }
  t.test("a block is laid out by the grammar's marks"){
    local messy = "extension \"gpu/syntax\"\nwgsl   demo{\n  struct P{pos:vec2f,vel:vec2<f32>};\n  /* them */ @group(0)@binding(0)var<storage,read_write>ps:array<P>;\n  @compute@workgroup_size(64)fn step(@builtin(global_invocation_id)id:vec3u){\n    let i=id.x;let ok=i<4u&&4u>1u; /* inline */ ps[i].vel+=vec2<f32>(1.0,2.0)*f32(i>>1u); // done\n    switch i{case 0u,1u:{discard;}default:{}}\n  }\n}\n"
    local want = "extension \"gpu/syntax\"\nwgsl demo {\n  struct P { pos: vec2f, vel: vec2<f32> }\n  /* them */\n  @group(0) @binding(0) var<storage, read_write> ps: array<P>;\n  @compute @workgroup_size(64)\n  fn step(@builtin(global_invocation_id) id: vec3u) {\n    let i = id.x;\n    let ok = i < 4u && 4u > 1u; /* inline */\n    ps[i].vel += vec2<f32>(1.0, 2.0) * f32(i >> 1u); // done\n    switch i {\n      case 0u, 1u: {\n        discard;\n      }\n      default: {}\n    }\n  }\n}\n"
    local out = format.source(messy, path.join(here, "messy.slang"), {
      find_project: true,
    })
    assert(out == want, out)
    assert(format.source(out, path.join(here, "messy.slang"), {
      find_project: true,
    }) == out)
  }
  t.test("this file is formatted"){
    local text = os.read_file(this_file)
    assert(format.source(text, this_file, {find_project: true}) == text)
  }
  t.test("tokens carry WGSL's categories"){
    local all = categories(
      "extension \"gpu/syntax\"\nwgsl demo {\n  /* c */ @group(0) @binding(0) var<storage, read_write> ps: array<Particle>;\n  fn f(n: u32) -> f32 {\n    let ok = n < 4u && vec2<f32>(1.0).x > 0.5; // d\n    return dot(a, b);\n  }\n}\n",
      "h.slang",
    )
    for(let local want in values({
      "wgsl=keyword",
      "demo=variable.declaration",
      "/* c */=comment",
      "@=decorator",
      "group=decorator",
      "var=keyword",
      "storage=enumMember",
      "read_write=enumMember",
      "ps=variable.declaration",
      "array=type.defaultLibrary",
      "Particle=type",
      "fn=keyword",
      "f=function.declaration",
      "n=parameter",
      "u32=type.defaultLibrary",
      "let=keyword",
      "<=operator",
      "4u=number",
      "&&=operator",
      "vec2=type.defaultLibrary",
      "<=punctuation",
      ">=punctuation",
      ">=operator",
      "x=property",
      "// d=comment",
      "dot=function.defaultLibrary",
    })){
      assert(
        str.contains(all, concat(" ", want, " ")),
        concat(want, " not in ", all),
      )
    }
  }
}

t.group("wgsl: a program's declarations in slang"){
  t.test("a program has what it declares, by name"){
    assert(type(scene) == "gpu.Program" and scene.label == "scene")
    assert(scene.LIGHTS == 2 and scene.N == 3)
    assert(type(scene.Uniforms) == "gpu.Struct")
    local step = scene.step
    assert(type(step) == "gpu.Entry" and step.stage == "compute")
    assert(step.workgroup_size == {4, 1, 1})
    // what an entry point uses, through the functions it calls
    assert(step.uses == {"u", "particles"}, step.uses)
    assert(scene.sum.uses == {"particles", "total"}, scene.sum.uses)
    assert(scene.textured.uses == {"tex", "smp"} and scene.fs.uses == {})
    assert(scene.vs.inputs == {
        {name: "position", location: 0, format: "float32x2"},
        {name: "color", location: 1, format: "float32x3"},
      }, scene.vs.inputs)
    local particles = scene.particles
    assert(type(particles) == "gpu.Variable" and particles.binding == 1)
    assert(particles.kind == "storage" and particles.access == "read_write")
    assert(particles.struct == scene.Particle)
    assert(scene.tex.kind == "texture" and scene.smp.kind == "sampler")
  }
  t.test("structs are laid out as WGSL lays them out"){
    local places = {}
    for(let local m in values(scene.Uniforms.members)){
      append(places, concat(m.name, "@", string(m.offset)))
    }
    assert(places == {
        "size@0",
        "time@8",
        "view@16",
        "normal@80",
        "lights@128",
        "counts@224",
      }, places)
    assert(scene.Uniforms.size == 240 and scene.Uniforms.align == 16)
    assert(scene.Light.size == 32 and scene.Particle.stride == 16)
    // a vec3f is 12 bytes at a multiple of 16: a float fits behind it
    assert(scene.Light.members[1].offset == 12)
  }
  t.test("a struct's value is set by its members' names"){
    local u = scene.Uniforms:new({size: {800, 600}, time: 1.5})
    assert(buffer.is_struct(u) and u.size.x == 800 and u.time == 1.5)
    u.size = {x: 1, y: 2}
    u.view = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
    // nine numbers, column after column (the columns are 16 bytes apart)
    u.normal = {1, 2, 3, 4, 5, 6, 7, 8, 9}
    u.lights[2] = {position: {1, 2, 3}, power: 4, color: {5, 6, 7}}
    u.counts = {7, 8}
    assert(u.size.y == 2 and u.view[3].w == 1 and u.normal[2].z == 9)
    assert(u.lights[2].color.y == 6 and u.lights[2].power == 4)
    assert(u.counts[1] == 8)
    local floats = buffer.wrap(u, 60, "float")
    assert(floats:slice(20, 32):to_list() == {
        1.0,
        2.0,
        3.0,
        0.0,
        4.0,
        5.0,
        6.0,
        0.0,
        7.0,
        8.0,
        9.0,
        0.0,
      })
    // what does not fit raises
    t.raises(func(){ u.size = {1, 2, 3} }, "vec2f has 2 fields, got 3 values")
    t.raises(func(){ u.normal = {1, 2, 3} }, "takes 9 numbers, got 3")
    t.raises(func(){ u.tiem = 1 }, "Uniforms has no field tiem")
    t.raises(func(){ scene.Uniforms:new({tiem: 1}) }, "has no field tiem")
    local e = t.raises(func(){ scene.Switches:new() })
    assert(e.kind == error.kinds.unsupported, e)
    assert(str.contains(e.message, "its member on is bool"), e.message)
  }
  t.test("pipelines of entry points, resources by name, typed buffers"){
    local device = gpu.device()
    local ps = scene.Particle:array({
      {pos: {0, 0}, vel: {1, 2}},
      {pos: {10, 10}, vel: {-1, 0}},
      {pos: {5, 5}},
    })
    local particles = device:buffer({contents: ps, usage: "storage|copy_src"})
    local uniforms = device:buffer({
      contents: scene.Uniforms:new({time: 0.5}),
      usage: "storage",
    })
    local total = device:buffer({
      type: "float", count: 1, usage: "storage|copy_src"
    })
    assert(uniforms.size == scene.Uniforms.size and total.size == 4)
    // one table of resources: each pipeline binds what its entry point uses
    local resources = {particles: particles, u: uniforms, total: total}
    local step = device:compute_pipeline(scene.step)
    local sum = device:compute_pipeline({
      shader: scene,
      compute: {entry_point: "sum"},
    })
    local encoder = device:encoder()
    local pass = encoder:compute_pass()
    pass:set_pipeline(step)
    pass:set_bind_group(0, step:bind(resources))
    pass:dispatch(len(ps))
    pass:set_pipeline(sum)
    pass:set_bind_group(0, sum:bind(resources))
    pass:dispatch(1)
    pass:finish()
    device.queue:submit(encoder:finish())
    local back = particles:read(scene.Particle)
    assert(len(back) == 3 and back[0].pos.x == 0.5 and back[0].pos.y == 1)
    assert(back[1].pos.x == 9.5 and total:read("float")[0] == 15)
    t.raises(func(){
      step:bind({particles: particles})
    }, "nothing is given for u")
    t.raises(func(){ step:bind({nope: total}) }, "no variable nope")
    t.raises(func(){
      device:compute_pipeline(scene)
    }, "2 compute stages (step, sum)")
    t.raises(func(){
      device:compute_pipeline(scene.fs)
    }, "fs is a fragment stage")
  }
  t.test("a vertex buffer's layout is its struct's"){
    local device = gpu.device()
    local target = device:texture({
      size: {4, 4},
      format: "rgba8_unorm",
      usage: "render_attachment|copy_src",
    })
    local pipeline = device:render_pipeline({
      vertex: {module: scene.vs, buffers: {scene.Vertex}},
      fragment: {module: scene.fs, targets: {{format: "rgba8_unorm"}}},
    })
    // a triangle over the whole target
    local vertices = device:buffer({
      contents: scene.Vertex:array({
        {position: {-1, -1}, color: {1, 0.5, 0}},
        {position: {3, -1}, color: {1, 0.5, 0}},
        {position: {-1, 3}, color: {1, 0.5, 0}},
      }),
      usage: "vertex",
    })
    assert(vertices.size == 3 * scene.Vertex.stride)
    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {{view: target:view(), clear_value: {0, 0, 1, 1}}},
    })
    pass:set_pipeline(pipeline)
    pass:set_vertex_buffer(0, vertices)
    pass:draw(3)
    pass:finish()
    local readback = device:buffer({size: 256 * 4, usage: "copy_dst|map_read"})
    encoder:copy_texture_to_buffer(
      {texture: target},
      {buffer: readback, layout: {bytes_per_row: 256, rows_per_image: 4}},
      {4, 4},
    )
    device.queue:submit(encoder:finish())
    local pixels = readback:read()
    assert({pixels[0], pixels[1], pixels[2], pixels[3]} == {255, 128, 0, 255})
  }
  t.test("WGSL text is a program too"){
    local program = require("gpu/program")
    local p = program.parse(
      "struct P { a: vec3f, b: f32 }\n@compute @workgroup_size(8) fn main() {}",
      "text",
    )
    assert(program.is(p) and p.P.size == 16 and p.main.workgroup_size[0] == 8)
    assert(type(gpu.device():compute_pipeline(p)) == "gpu.ComputePipeline")
  }
  t.test("a program's fields are found where the WGSL declares them"){
    // (what the language server goes by: the block is a table written out,
    // its keys at the names in the WGSL)
    local source = "extension \"gpu/syntax\"\nwgsl shade {\n  const LIGHTS = 3;\n  // every frame\n  struct Uniforms { time: f32 }\n  @group(0) @binding(0) var<uniform> u: Uniforms;\n  @fragment fn fs() -> @location(0) vec4f { return vec4f(u.time); }\n}\nlocal a = shade.Uniforms\nlocal b = shade.fs\nlocal c = shade.u\nlocal d = shade.LIGHTS\n"
    local h = compiler.highlight(source, path.join(here, "fields.slang"), {
      find_project: true, symbols: true
    })
    local symbols = require("slang/symbols")
    for(let local want in values({
      {"shade.Uniforms", "struct Uniforms", 7},
      {"shade.fs", "fn fs", 3},
      {"shade.u\n", "> u:", 2},
      {"shade.LIGHTS", "const LIGHTS", 6},
    })){
      local use = str.index_of(source, want[0]) + 6
      local found = symbols.at(h.symbols, use)
      assert(found != null and found.def != null, want[0])
      assert(
        found.def.start == str.index_of(source, want[1]) + want[2],
        concat(want[0], " is found at ", string(found.def.start)),
      )
    }
    // and the comment above a declaration is its doc
    local uniforms = symbols.at(
      h.symbols,
      str.index_of(source, "shade.Uniforms") + 6,
    )
    assert(
      str.contains(uniforms.def.doc or "", "every frame"),
      uniforms.def.doc,
    )
  }
}
