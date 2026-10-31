// Modules and the library
//
// `require("name")` loads a module once and returns what it returns,
// usually a table of functions. The standard library lives under
// `slang/`: strings, tables, JSON, math, time, HTML, tests, and an async
// runtime with HTTP for programs on your machine. The API docs on this
// site cover every module.
//
// (The playground runs slang as WebAssembly in your browser, so modules
// that need the operating system, like files, networking or the FFI,
// only work in a local install.)
local str = require("slang/string")
local json = require("slang/json")
local tbl = require("slang/table")

print(str.upper("loud"), " ", str.split("a,b,c", ","), "\n")
local text = json.encode({name: "slang", tags: {"small", "fast"}})
print(text, "\n")
print(json.decode(text).tags[1], "\n")
print(tbl.map({1, 2, 3}, func(x) => x * x), "\n")
