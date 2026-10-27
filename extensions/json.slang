// A dialect: JSON files as modules. In slang.project
//     dialects: {[".json"]: {compile: "extensions/json"}}
// makes require("config") load config.json; compile(source, origin) returns a
// function yielding the decoded value, so `slang run data.json` works too.
// The parser is slang/json.
local json = require("slang/json")

local m = {decode: json.decode, encode: json.encode}

// compile(source, origin) -> function returning the decoded value
func m.compile(source, origin){
  local v = json.decode(source, origin)
  return func(){
    return v
  }
}

return m
