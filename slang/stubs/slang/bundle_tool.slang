// slang/bundle_tool: how `slang build` (slang/build) writes executables,
// built into the VM. A built executable is a slang runtime with the
// program's modules and assets appended; slang/bundle reads them back at
// run time.
//
//   local tool = require("slang/bundle_tool")
//   tool.write_executable(base, "out/app", {
//     {kind: "module", name: "<main>", data: compiled},
//     {kind: "asset", name: "static/index.html", file: "static/index.html",
//      compress: true},
//   })

// What goes into an executable: data, or a file to read it from (whose
// mtime is kept).
// type Entry = {kind: string, name: string, data?: string, file?: string,
//   compress?: bool, external?: bool}
// [kind]: "module" (compiled code) or "asset"
// [name]: the module's name or the asset's path; the module "<main>" is the program
// [compress]: store it gzipped when that saves 10% or more
// [external]: keep the file next to the executable instead of inside it

// An entry of a built executable, as [write_executable] wrote it.
// type EntryInfo = {kind: string, name: string, size: int,
//   stored_size: int, encoding?: string, external: bool}
// [size]: the entry's length
// [stored_size]: what the executable holds; smaller when gzipped
// [encoding]: "gzip", or null when stored as it is

// How [write_executable] signs.
// type Options = {sign?: string, identifier?: string}
// [sign]: "adhoc" (the default) signs a Mach-O ad hoc; "external" leaves it unsigned and ready for `codesign`
// [identifier]: the signing identifier; the name of out by default
local m = {}

// write_executable(base: string, out: string, entries: {Entry},
//                  options?: Options) -> {EntryInfo}
// Writes out: the executable base (a slang runtime) with entries
// appended, made executable and on macOS signed. out is replaced by a new
// file, never rewritten in place. Raises on an entry with neither data
// nor file, or when a file cannot be read.
func m.write_executable(base, out, entries, options){}

// inspect(path: string) -> {EntryInfo}?
// The entries of a built executable, or null when it has none.
func m.inspect(path){}

return m
