// A program under a slang.project: the custom operators extension is ambient
// (no extension statement needed) and require("config") loads config.json
// through the project's .json dialect. Run with
//     bin/slang run examples/project/main.slang
// or with --explain to see the project, the units and their extensions.
local config = require("config")

infix _x_ before _*_ (a, b){
  return a * b
}

local area = config.scale[0] x config.scale[1]
print(config.name, " v", config.version, ": ", area, "\n")
return {
  name: config.name,
  version: config.version,
  area: area,
  deep: config.nested.deep,
}
