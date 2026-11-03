// slang/os: files, the process and its environment, built into the VM.
// Everything here blocks; slang/async has non-blocking files and
// processes.
//
//   local os = require("slang/os")
//   if(not os.exists("out")){ os.mkdir_all("out") }
//   os.write_file("out/hello.txt", concat("from ", os.cwd(), "\n"))
//   for(let local line in os.open("out/hello.txt"):lines()){ print(line, "\n") }
//   local r = os.exec({"ls", "out"})
//   print(r.stdout)
//
// Relative paths are relative to the current directory. In a program built
// by `slang build`, a relative path that names a bundled file or directory
// reads from the bundle first ([exists], [is_dir], [read_file],
// [list_dir]; see slang/bundle); writes always go to the disk, so a
// program that writes a bundled path still reads the bundled file there.
local m = {}

local file_methods = {}
local file_get = {}

// An open file, from [open]; type() of it is "file". It is closed when it
// is collected.
// type File
local file_meta = {__index: file_methods, __get: file_get, __type: "file"}

// name(self) -> string
// The path the file was opened with.
func file_get.name(self){}

// What [stat] gives back.
// type FileInfo = {size: int, mtime: int, is_dir: bool, mode: int}
// [size]: the length in bytes
// [mtime]: when it was last modified, in milliseconds since the epoch
// [mode]: the permission bits, like 0o644 (420)

// ------------------------------------------------------------ files

// open(path: string, mode?: string) -> File
// Opens a file. Writing and appending create a missing file, together with
// its directory. Raises "cannot open <path>" when the file cannot be
// opened.
// [mode]: "r" (the default) to read, "w" to write (truncating), "a" to append, "rw" to read and write (truncating), "ra" to read and append
//   local f = os.open("out.txt", "w")
//   f:write("hello\n")
//   f:close()
func m.open(path, mode){
  return {@meta: file_meta}
}

// read(n?: int) -> string
// The next n bytes, fewer at the end of the file, or the rest of the file
// when n is left out.
func file_methods.read(file, n){}

// read_line() -> string?
// The next line without its line ending ("\n" or "\r\n"), or null at the
// end of the file.
func file_methods.read_line(file){}

// lines() -> function
// An iterator over the remaining lines of the file, as [File.read_line]
// gives them.
//   for(let local line in f:lines()){ print(line, "\n") }
func file_methods.lines(file){}

// read_bytes(n?: int) -> {int}
// Like [File.read], but a list of byte values (ints 0-255).
func file_methods.read_bytes(file, n){}

// write(s: string)
// Writes s.
func file_methods.write(file, s){}

// write_bytes(bytes: {int})
// Writes a list of byte values; each int is cut to its low 8 bits.
func file_methods.write_bytes(file, bytes){}

// flush()
// Writes out what the file buffers.
func file_methods.flush(file){}

// close()
// Closes the file; closing it again does nothing. Reading or writing a
// closed file raises an error.
func file_methods.close(file){}

// exists(path: string) -> bool
// Whether a file or directory exists at path.
func m.exists(path){}

// is_dir(path: string) -> bool
// Whether path is a directory.
func m.is_dir(path){}

// read_file(path: string) -> string
// The whole content of the file. Raises an error when it cannot be read.
func m.read_file(path){}

// write_file(path: string, content: string)
// Writes content to the file, replacing what was there. Raises an error
// when it cannot be written.
func m.write_file(path, content){}

// append_file(path: string, content: string)
// Adds content at the end of the file, creating it when it is missing.
// Raises an error when it cannot be written.
func m.append_file(path, content){}

// stat(path: string) -> FileInfo?
// Size, modification time, kind and permissions of what is at path, or
// null when nothing is.
func m.stat(path){}

// list_dir(path: string) -> {string}
// The sorted names of the entries of the directory. Raises an error when
// it cannot be listed.
func m.list_dir(path){}

// rename(from: string, to: string)
// Moves a file or directory, replacing to. Raises an error when it cannot.
func m.rename(from, to){}

// copy_file(from: string, to: string)
// Copies a file with its permissions, replacing to (whose directory must
// exist). Raises an error when it cannot.
func m.copy_file(from, to){}

// mkdir_all(path: string)
// Creates the directory and any missing parents. Raises an error when it
// cannot.
func m.mkdir_all(path){}

// remove(path: string)
// Deletes a file or an empty directory. Raises an error when it cannot,
// also when nothing is there.
func m.remove(path){}

// remove_all(path: string)
// Deletes path and everything under it; nothing there is not an error.
func m.remove_all(path){}

// temp_dir() -> string
// The directory for temporary files: TMPDIR (TEMP on Windows), else /tmp.
func m.temp_dir(){}

// ------------------------------------------------------------ process

// read_line() -> string?
// The next line of standard input without its line ending, or null at the
// end of the input. Flushes standard output first.
func m.read_line(){}

// cwd() -> string
// The current directory.
func m.cwd(){}

// executable() -> string
// The path of the running executable.
func m.executable(){}

// getenv(name: string) -> string?
// The value of the environment variable, or null when it is not set.
func m.getenv(name){}

// write_stderr(text: string)
// Writes text to standard error, after flushing standard output.
func m.write_stderr(text){}

// exit(code?: int)
// Flushes standard output and ends the process with code (0 by default).
func m.exit(code){}

// ------------------------------------------------------------ programs

// What [exec] gives back.
// type ExecResult = {status: int, stdout: string, stderr: string}
// [status]: the exit code, -1 when a signal ended the program
// [stdout]: all it wrote to standard output
// [stderr]: all it wrote to standard error

// exec(argv: {string}, cwd?: string) -> ExecResult
// Runs a program (argv[0], looked up on the PATH) in cwd (the current
// directory by default) and waits for it. Raises when it cannot be
// started. Blocking, for tools; slang/async's exec does not block.
func m.exec(argv, cwd){}

// cpu_count() -> int
// How many CPUs the machine runs threads on: how many isolates that compute
// can run at once (1 where there are no threads).
func m.cpu_count(){}

// platform() -> string
// "<os>-<arch>" of the running slang, as Zig names them ("macos-aarch64",
// "linux-x86_64"): where packages keep their prebuilt native modules
// (lib/<platform>/).
func m.platform(){}

return m
