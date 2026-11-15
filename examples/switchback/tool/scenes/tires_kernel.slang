// tool/scenes/tires_kernel: the kernels the tire's programs were compiled
// to, written beside the WAV (a moment of silence) as <program>.kernel.txt,
// with what each needs of the kernel VM's 256 registers: a program that
// does not fit is generated with its values kept in memory, and runs
// several times slower (see packages/dsp). Arguments: the directory to
// write to.
local kernel = require("kernel")
local os = require("slang/os")
local str = require("slang/string")
local regex = require("slang/regex")

return func(kit, args){
  local dir = args[0] or "."
  local programs = {
    {"tire", require("sound/tire")},
  }
  for(let local name in values({"ground", "water"})){
    local ok = true
    local p = null
    try {
      p = require(concat("sound/tire/", name))
    } catch(local e) {
      ok = false
    }
    if(ok){
      append(programs, {name, p})
    }
  }
  for(let local e in values(programs)){
    local source = e[1].source
    os.write_file(concat(dir, "/", e[0], ".kernel.txt"), source)
    local lines = str.split(source, "\n")
    local in_loop = false
    local loop = 0
    local before = 0
    for(let local line in values(lines)){
      if(str.contains(line, "for(local i = 0")){
        in_loop = true
      } else if(in_loop){
        loop = loop + 1
      } else {
        before = before + 1
      }
    }
    local constants = {}
    local count = 0
    for(let local found in values(
      regex.compile("\\b[0-9]+\\.[0-9]+(e[-+]?[0-9]+)?"):find_all(source),
    )){
      if(constants[found.text] == null){
        constants[found.text] = true
        count = count + 1
      }
    }
    local how = "every value in a register"
    if(str.contains(source, "tmp[")){
      how = "SPILLED: temporaries in memory"
    } else if(str.contains(source, "d.k")){
      how = "SPILLED: constants in memory"
    } else if(str.contains(source, " = d.m") == false and
      str.contains(source, "d.m")){
      how = "SPILLED: state in memory"
    } else if(str.contains(source, "d.c")){
      how = "SPILLED: block values in memory"
    } else if(str.contains(source, "local t0 = 0.0")){
      how = "temporaries pooled (as fast)"
    }
    print(
      e[0], ": ", len(e[1].controls), " controls, ", before,
      " lines before the loop, ", loop, " in it, ", count, " constants; ", how,
      "\n"
    )
  }
  return {channels: {kernel.float:array(kit.BLOCK)}, load: 0}
}
