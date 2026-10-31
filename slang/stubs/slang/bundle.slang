// slang/bundle: the files of a program built by `slang build`, built into
// the VM. Paths are relative and '/'-separated, as they were in the
// project. slang/os already reads bundled files transparently (read_file,
// exists, is_dir, list_dir) and slang/web serves them (app:static); this
// module tells what os cannot: whether a file is bundled, how it is stored
// and its stat at build time. Outside a built program, active() is false
// and the rest find nothing.
local m = {}

// active() -> whether this program runs from an executable built by slang
// build
func m.active(){}

// exists(path) -> whether path is a bundled file or a directory of them
func m.exists(path){}

// is_dir(path) -> whether bundled files lie under path
func m.is_dir(path){}

// read(path) -> the contents of a bundled file (uncompressed), or null when
// the bundle has no file at path
func m.read(path){}

// read_raw(path) -> {data, encoding}: the file as stored, encoding "gzip"
// or null; {path} for a file kept next to the executable (slang build
// --dir); null when not bundled
func m.read_raw(path){}

// stat(path) -> {is_file, is_dir, size, stored_size, mtime, encoding,
// path}, or null when not bundled. size is the file's length, stored_size
// the bundle's (smaller when gzipped); mtime is the source file's, in
// seconds, at build time; path is set for a file next to the executable.
func m.stat(path){}

// list(path) -> the sorted names of the bundled files and directories
// directly under path, or null when path is not a bundled directory
func m.list(path){}

// files() -> the paths of all bundled files, sorted
func m.files(){}

// module(name) -> the bundled module's function (not yet run), or null;
// require finds bundled modules first
func m.module(name){}

// dir() -> the directory of the running executable when bundled, else null
func m.dir(){}

return m
