// dsp/build: a program's definitions to kernel source, and to slang code
// that loads it: what the `dsp name { }` statement (dsp.slang) and .dsp
// files (dsp/file) expand to.
//
//   local build = require("dsp/build")
//   local r = build.program(items, "synth")      // {source, info}
//   print(r.source)                              // the kernel
local ast = require("slang/ast")
local os = require("slang/os")
local path = require("slang/path")
local str = require("slang/string")
local grammar = require("dsp/grammar")
local eval = require("dsp/eval")
local codegen = require("dsp/codegen")

local build = {}

// load(module, line) -> items: the definitions of an imported .dsp file,
// found as require finds modules; on_file(path, module) hears of every
// file read
func build.loader(on_file){
  local cache = {}
  return func(module, line){
    local find = __PACKAGES.find_source
    local found = null
    if(find != null){
      found = find(module)
    }
    if(found == null or found.suffix != ".dsp"){
      raise(
        error.new(
          error.kinds.compile,
          concat("import: no .dsp file ", module),
          {
            line: line,
          },
        ),
      )
    }
    found.path = path.clean(found.path)
    if(on_file != null){
      on_file(found.path, module)
    }
    local items = cache[found.path]
    if(items == null){
      items = grammar.parse(os.read_file(found.path), found.path)
      // errors in the file's definitions are reported in it (and in the
      // definitions of their with)
      local func mark(list){
        for(let local item in values(list)){
          item.origin = found.path
          if(item.with != null){
            mark(item.with)
          }
        }
      }
      mark(items)
      cache[found.path] = items
    }
    return items
  }
}

// program(items, name?, load?) -> {source, info}
// The kernel source of a program and what running it needs (see
// dsp/codegen). Raises errors of kind compile with the line of the
// mistake (and origin, when it is in an imported file).
func build.program(items, name, load){
  local r = eval.signals(items, load or build.loader())
  return build.generate(r, name)
}

// generate(signals, name, options?) -> {source, info}: dsp/codegen's code
// of a program's signals (eval.signals), options as codegen takes them
func build.generate(r, name, options){
  local out = codegen.generate(r, name, options)
  out.info.name = name
  out.info.source = out.source
  out.signals = r
  return out
}

// the ways to generate a program, tried in order until its kernel fits in
// the kernel VM's registers: one register per value (the fastest), the
// temporaries in a reused pool, the values computed once a block in the
// instance, the state and the constants in the instance as well
local ATTEMPTS = {
  {},
  {pool: true},
  {pool: true, spill_controls: true},
  {pool: true, spill_controls: true, spill_state: true},
}
// then more and more of the constants in the instance, the least used
// first
for(let local k in values({16, 32, 48, 64, 96, 128})){
  append(ATTEMPTS, {
    pool: true,
    spill_controls: true,
    spill_state: true,
    spill_constants: true,
    constants: k,
  })
}
// then fewer and fewer of the temporaries in registers, the rest in the
// scratch array
for(let local k in values({64, 48, 40, 32, 24, 16, 8, 0})){
  append(ATTEMPTS, {
    pool: true,
    spill_controls: true,
    spill_state: true,
    spill_constants: true,
    registers: k,
  })
}

// the AST of a value: a literal, or a table literal of its elements and
// fields
local func value_ast(v, token){
  if(type(v) != "table"){
    return ast.literal(token, v)
  }
  local fields = {}
  local n = len(v)
  for(local i = 0; i < n; i = i + 1){
    append(fields, ast.node(
      "Field", {key: null, value: value_ast(v[i], token)}, token
    ))
  }
  for(let local e in entries(v)){
    local key = e[0]
    if(type(key) == "int" and key >= 0 and key < n){
      continue
    }
    append(fields, ast.node("Field", {
      key: ast.literal(token, key),
      value: value_ast(e[1], token),
    }, token))
  }
  return ast.node("Table", {fields: fields}, token)
}

// expand(items, g, token, name) -> ast.Node
// The code of a program in the unit g is parsing: an expression that
// makes the program's [dsp/runtime.Dsp] when it runs, its kernel compiled
// now. A mistake is a compile error at its line (g:error_at); token is
// where errors without a line of their own are reported.
// covered: the modules already in the unit's cache key (a dialect's
// sources): importing only those keeps the unit's bytecode cacheable.
func build.expand(items, g, token, name, covered){
  local origin = g:origin() or "dsp"
  local r = null
  local imported = false
  try {
    r = build.program(items, name, build.loader(func(path, module){
      if((covered or {})[module] != true){
        imported = true
      }
    }))
  } catch(local e) {
    if(e.kind != error.kinds.compile){
      raise(e)
    }
    local msg = e.message
    if(e.origin != null and e.origin != origin){
      g:error_at(token, concat(e.origin, ":", string(e.line or 0), ": ", msg))
    }
    if(e.line != null){
      g:error_at({line: e.line, column: e.column or 1}, msg)
    }
    g:error_at(token, msg)
  }
  if(imported){
    // the code depends on the imported files too
    g:no_cache()
  }
  // the kernel, through kernel/lower; its own errors would be dsp's bugs,
  // but for a program too big for the registers, which is generated again
  // with fewer
  local kgrammar = require("kernel/grammar")
  local lower = require("kernel/lower")
  local proxy = {
    origin: func(self){ return g:origin() },
    error_at: func(self, at, ...message){
      raise(error.new(error.kinds.compile, concat("", ...message), {
        kernel: true,
      }))
    },
    unit_local: func(self, key, e){ return g:unit_local(key, e) },
    no_cache: func(self){ g:no_cache() },
  }
  local k = null
  for(local a = 0; k == null; a = a + 1){
    if(a > 0){
      r = build.generate(r.signals, name, ATTEMPTS[a])
    }
    try {
      local kitems = kgrammar.parse(r.source, concat(origin, " (generated)"))
      k = lower.compile(kitems, proxy, token)
    } catch(local e) {
      local too_big = str.contains(e.message or "", "registers")
      if(not too_big or a + 1 >= len(ATTEMPTS)){
        g:error_at(
          token,
          "the generated kernel does not compile (a bug of dsp): ",
          e.message or string(e),
        )
      }
    }
  }
  local runtime = g:unit_local("dsp/runtime", +{require("dsp/runtime")})
  return +{-{runtime}.new(-{value_ast(r.info, token)}, -{k.call})}
}

return build
