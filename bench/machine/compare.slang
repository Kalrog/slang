// bench/machine/compare.slang: two machines' reports (bench/machine/run.slang)
// side by side.
//
//   slang run bench/machine/compare.slang <a.json> <b.json>
//
// For each measurement both have: a's value, b's, and b/a (above 1: b takes
// longer). Then each relative to the interpreter yardstick: how much
// slower b runs Lua (the geometric mean of the Lua programs' b/a) is what
// a slower CPU alone explains; "vs lua" is b/a divided by that. Above 1:
// slang loses more on b than an interpreter in general does, which is
// where to look. Rows are sorted by it, the worst first.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local math = require("slang/math")
local tbl = require("slang/table")

local argv = args()
if(len(argv) < 2){
  os.write_stderr("usage: slang run bench/machine/compare.slang <a.json> <b.json>\n")
  os.exit(2)
}
local a = json.decode(os.read_file(argv[0]))
local b = json.decode(os.read_file(argv[1]))

local func by_key(report){
  local t = {}
  for(let local r in values(report.results)){
    t[concat(r.group, "/", r.name)] = r
  }
  return t
}
local ra = by_key(a)
local rb = by_key(b)

local func geomean(list){
  if(len(list) == 0){
    return null
  }
  local s = 0
  for(let local x in values(list)){
    s = s + math.log(x)
  }
  return math.exp(s / len(list))
}

// the rows both have, with their ratio
local rows = {}
for(let local r in values(a.results)){
  local other = rb[concat(r.group, "/", r.name)]
  if(other != null and r.value > 0){
    append(rows, {group: r.group, name: r.name, a: r.value, b: other.value, unit: r.unit, ratio: other.value / r.value})
  }
}

local lua_ratios = {}
local slang_ratios = {}
for(let local r in values(rows)){
  if(r.group == "interp" and str.ends_with(r.name, " lua")){
    append(lua_ratios, r.ratio)
  } else if(r.group == "interp" and str.ends_with(r.name, " slang")){
    append(slang_ratios, r.ratio)
  }
}
local lua_ratio = geomean(lua_ratios)

print("a: ", a.label, " (", a.machine.cpu, ", slang ", a.machine.slang, ")\n")
print("b: ", b.label, " (", b.machine.cpu, ", slang ", b.machine.slang, ")\n\n")
if(lua_ratio != null){
  print(str.format("Lua runs %.2fx as long on b: the yardstick (a slower CPU alone)\n", lua_ratio))
  local s = geomean(slang_ratios)
  if(s != null){
    print(str.format("slang runs %.2fx as long on b: %.2fx the yardstick\n", s, s / lua_ratio))
  }
} else {
  print("(no Lua in both reports: no yardstick, vs lua is left out)\n")
}

for(let local group in values({"native", "interp", "micro"})){
  local list = tbl.filter(rows, func(r){ return r.group == group })
  if(len(list) > 0){
    for(let local r in values(list)){
      r.vs = if(lua_ratio != null){ r.ratio / lua_ratio } else { r.ratio }
    }
    tbl.sort(list, func(x, y){ return x.vs > y.vs })
    print(str.format("\n%-6s %-44s %12s %12s %7s %8s\n", group, "", "a", "b", "b/a", "vs lua"))
    for(let local r in values(list)){
      print(str.format("       %-44s %12.3f %12.3f %7.2f %8.2f  %s\n", r.name, r.a, r.b, r.ratio, r.vs, r.unit))
    }
  }
}
