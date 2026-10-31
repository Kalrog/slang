// extensions/json: a dialect that makes JSON files modules, so data
// files load with require like code.
//
//   // slang.project
//   {dialects: {[".json"]: {compile: "extensions/json"}}}
//
//   // then, with a config.json next to the program:
//   local config = require("config")
//   print(config.name, "\n")
//
// A dialect module gives `compile(source, origin)`, which the loader calls
// for every file with the dialect's extension: here it decodes the JSON
// once, when the file is loaded, and every require of it returns that same
// value (a table that the requiring modules share). `slang run data.json`
// works too, which checks that the file decodes. Malformed JSON raises
// slang/json's error, naming the file. `decode` and `encode` are
// slang/json's [json.decode] and [json.encode], for code that loads the
// dialect module itself.
local json = require("slang/json")

local m = {decode: json.decode, encode: json.encode}

// compile(source: string, origin?: string) -> func(): any
// Decodes source (raising on malformed JSON, with origin naming it) and
// returns a function that returns the decoded value: the module's body.
func m.compile(source, origin){
  local v = json.decode(source, origin)
  return func(){
    return v
  }
}

return m
