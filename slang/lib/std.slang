// slang/std: global functions written in slang: module, run and the
// matcher protocol behind 'm patterns. They are globals; nothing needs to
// require this module.
//
//   local point = module{
//     func make(x, y){ return {x: x, y: y} }
//   }
//   local p = point.make(1, 2)
//   local big = run{ if(p.x > 0){ return "right" } return "left" }
local vm = require("slang/vm")

// module(mfunc: function) -> table
// Runs mfunc (usually a block: module{ ... }) with a fresh table as its
// _ENV and returns that table, so every global defined inside ends up in
// it. While the block runs, names it does not define still read the
// enclosing globals; afterwards the table holds only its own definitions.
func module(mfunc){
  local m = {}
  m.@meta = {__index: _ENV}
  vm.set_upvalue(mfunc, "_ENV", m)
  mfunc()
  m.@meta.__index = null
  return m
}

// __match(m, v) -> any
// The matcher protocol behind 'm patterns: calls the __match metamethod
// of m with (m, v). Its result decides: null means v does not match;
// anything else is what the rest of the pattern sees. Raises an error
// when m has no __match metamethod (strings, numbers, functions and the
// like never do).
func __match(m, v){
  local t = type(m)
  local f = null
  if(t != "null" and t != "string" and t != "int" and t != "double" and
    t != "bool" and t != "function"){
    local meta = m.@meta
    if(meta != null){
      f = meta.__match
    }
  }
  if(f == null){
    error("'", t, " in a pattern: a matcher needs a __match metamethod")
  }
  return f(m, v)
}

// run(rfunc: function) -> any
// Calls rfunc and returns its result: run{ ... } evaluates a block as an
// expression.
func run(rfunc){
  return rfunc()
}

// ------------------------------------------------------------ errors
//
// error is the error library: its functions make and recognise errors,
// and raise raises them (error(...values) still raises an error with the
// values joined as its message, but is going away). An error is
// a table {kind, message, cause?, location, stack, ...data}: kind is what
// a program catches on (`catch({kind: "not_found"})`), message is for
// people, cause the error it wraps; the VM adds location and stack where
// it is raised. Errors have the metatable error.meta (a __tostring; no
// __type, so that table patterns match them), which a raised table
// without a metatable gets too.
//   raise(error.new("not_found", concat("no user ", id), {id: id}))
//   try { load(path) } catch(local e) { raise(error.wrap(e, "loading the config")) }

// a value whose fields can be read: a table (an error is one) or a
// userdata
local func is_record(v){
  local t = raw_type(v)
  return t == "table" or t == "userdata"
}

// error.new(kind: string, message: string, fields?: table) -> Error
// An error, not raised: raise(error.new(...)) raises it. fields are copied
// into it (data for whoever catches it: a path, a status).
func error.new(kind, message, fields){
  local e = {}
  if(fields != null){
    for(let {local k, local v} in entries(fields)){
      e[k] = v
    }
  }
  e.kind = kind
  e.message = message
  e.@meta = error.meta
  return e
}

// error.wrap(cause: any, message: string, fields?: table) -> Error
// An error that adds context to cause: its message, cause as its cause,
// and cause's kind unless fields give one, so that code catching the kind
// still recognises it.
//   raise(error.wrap(e, concat("reading ", path)))
func error.wrap(cause, message, fields){
  local kind = null
  if(fields != null){
    kind = fields.kind
  }
  if(kind == null and is_record(cause)){
    kind = cause.kind
  }
  local e = error.new(kind or "error", message, fields)
  e.cause = cause
  return e
}

// error.is(e: any, kind: string) -> bool
// Whether e, or an error it wraps (its causes), has kind.
func error.is(e, kind){
  for(is_record(e)){
    if(e.kind == kind){
      return true
    }
    e = e.cause
  }
  return false
}

// error.message(e: any) -> string
// The message of e and of the errors it wraps, outermost first:
// "loading the config: cannot read /etc/x: not found".
func error.message(e){
  local text = ""
  for(e != null){
    local part = null
    if(is_record(e)){
      part = e.message
      if(part == null){
        part = string(e.kind or "error")
      }
    } else {
      part = string(e)
    }
    if(text == ""){
      text = part
    } else {
      text = concat(text, ": ", part)
    }
    if(not is_record(e)){
      break
    }
    e = e.cause
  }
  return text
}

error.meta.__tostring = error.message
