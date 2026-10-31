// slang/os: files, the process and its environment, built into the VM.
// Everything here blocks; slang/async has non-blocking files and
// processes.
//
//   local os = require("slang/os")
//   if(not os.exists("out")){ os.mkdir_all("out") }
//   os.write_file("out/hello.txt", concat("from ", os.cwd(), "\n"))
//   local r = os.exec({"ls", "out"})
//   print(r.stdout)
//
// Relative paths are relative to the current directory. In a program built
// by `slang build`, a relative path that names a bundled file or directory
// reads from the bundle first ([exists], [is_dir], [read_file],
// [list_dir]; see slang/bundle); writes always go to the disk, so a
// program that writes a bundled path still reads the bundled file there.
local m = {}

// ------------------------------------------------------------ files

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

// ------------------------------------------------------------ process

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

// ------------------------------------------------------------ clocks

// clock() -> float
// Seconds since the program started, from a monotonic clock: for
// measuring.
func m.clock(){}

// time_ms() -> int
// Milliseconds since the Unix epoch.
func m.time_ms(){}

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

// platform() -> string
// "<os>-<arch>" of the running slang, as Zig names them ("macos-aarch64",
// "linux-x86_64"): where packages keep their prebuilt native modules
// (lib/<platform>/).
func m.platform(){}

return m
