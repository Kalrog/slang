// slang/bundle_tool: how `slang build` (slang/build) writes executables,
// built into the VM.
local m = {}

// write_executable(base, out, entries, [options]) -> {{kind, name, size,
// stored_size, encoding, external}}: writes out, the executable base (a
// slang runtime) with entries appended, executable and on macOS signed ad
// hoc. An entry is {kind: "module" | "asset", name, data} or {kind, name,
// file} (read from the file, whose mtime is kept), with compress = true to
// store it gzipped when that saves 10% or more, and external = true for a
// file that stays next to the executable. The module named "<main>" is the
// program. options: {sign: "adhoc" | "external", identifier}; "external"
// leaves a Mach-O unsigned and ready for `codesign`. out is replaced by a
// new file, never rewritten in place.
func m.write_executable(base, out, entries, options){}

// inspect(path) -> {{kind, name, size, stored_size, encoding, external}}:
// the entries of a built executable, or null when it has none
func m.inspect(path){}

return m
