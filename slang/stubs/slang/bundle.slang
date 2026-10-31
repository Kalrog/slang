// slang/bundle: the files of a program built by `slang build`, built into
// the VM.
//
//   local bundle = require("slang/bundle")
//   if(bundle.active()){
//     for(let local path in values(bundle.files())){
//       print(path, " ", bundle.stat(path).size, "\n")
//     }
//   }
//
// Paths are relative and '/'-separated, as they were in the project.
// slang/os already reads bundled files transparently (read_file, exists,
// is_dir, list_dir) and slang/web serves them (app:static); this module
// tells what os cannot: whether a file is bundled, how it is stored and
// its stat at build time. Outside a built program, [active] is false and
// the rest find nothing.

// A bundled file or directory, from [stat]. A directory has only is_file
// and is_dir.
// type Stat = {is_file: bool, is_dir: bool, size?: int, stored_size?: int,
//   mtime?: int, encoding?: string, path?: string}
// [size]: the file's length
// [stored_size]: what the bundle holds; smaller when gzipped
// [mtime]: the source file's modification time at build time, in seconds
// [encoding]: "gzip", or null when stored as it is
// [path]: where the file is on disk, for one kept next to the executable

// A bundled file as stored, from [read_raw]: data and encoding, or path
// alone for a file kept next to the executable (slang build --dir).
// type Raw = {data?: string, encoding?: string, path?: string}
// [encoding]: "gzip", or null when data is the file as it is
local m = {}

// active() -> bool
// Whether this program runs from an executable built by slang build.
func m.active(){}

// exists(path: string) -> bool
// Whether path is a bundled file or a directory of them.
func m.exists(path){}

// is_dir(path: string) -> bool
// Whether bundled files lie under path.
func m.is_dir(path){}

// read(path: string) -> string?
// The contents of a bundled file (uncompressed), or null when the bundle
// has no file at path. Raises when a file kept next to the executable
// cannot be read.
func m.read(path){}

// read_raw(path: string) -> Raw?
// The file as stored, or null when it is not bundled.
func m.read_raw(path){}

// stat(path: string) -> Stat?
// What the bundle knows of a file or directory, or null when it is not
// bundled.
func m.stat(path){}

// list(path: string) -> {string}?
// The sorted names of the bundled files and directories directly under
// path, or null when path is not a bundled directory.
func m.list(path){}

// files() -> {string}
// The paths of all bundled files, sorted.
func m.files(){}

// module(name: string) -> function?
// The bundled module's function (not yet run), or null; require finds
// bundled modules first.
func m.module(name){}

// dir() -> string?
// The directory of the running executable when bundled, else null.
func m.dir(){}

return m
