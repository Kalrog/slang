// slang/os: files, the process and its environment, built into the VM.
// Relative paths are relative to the current directory.
local m = {}

// ------------------------------------------------------------ files

// exists(path) -> whether a file or directory exists at path
func m.exists(path){}

// is_dir(path) -> whether path is a directory
func m.is_dir(path){}

// read_file(path) -> the whole content of the file as a string. Raises an
// error when it cannot be read.
func m.read_file(path){}

// write_file(path, content): writes the string content to the file,
// replacing what was there. Raises an error when it cannot be written.
func m.write_file(path, content){}

// list_dir(path) -> the sorted list of the names of the entries of the
// directory. Raises an error when it cannot be listed.
func m.list_dir(path){}

// mkdir_all(path): creates the directory and any missing parents. Raises an
// error when it cannot.
func m.mkdir_all(path){}

// ------------------------------------------------------------ process

// cwd() -> the current directory
func m.cwd(){}

// getenv(name) -> the value of the environment variable, or null
func m.getenv(name){}

// write_stderr(text): writes text to standard error, after flushing
// standard output
func m.write_stderr(text){}

// exit([code]): flushes standard output and ends the process with code (0
// by default)
func m.exit(code){}

// ------------------------------------------------------------ clocks

// clock() -> seconds since the program started, as a double (monotonic)
func m.clock(){}

// time_ms() -> milliseconds since the Unix epoch, as an int
func m.time_ms(){}

return m
