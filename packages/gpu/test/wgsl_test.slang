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
