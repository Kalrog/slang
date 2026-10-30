// uv: the native binding of libuv in the callback style of luv. Most code
// should use slang/async, which builds Futures and Streams on it.
//
//   local uv = require("uv")
//   local t = uv.timer()
//   t:start(100, 0, func(){ print("tick") t:close() })
//   uv.run()
//
// Handles are userdata with methods; every operation takes its callback
// last, and callbacks have the shape cb(err, value) with err a string like
// "ECONNRESET: connection reset by peer" or null. Callbacks run only from
// inside uv.run(); an error raised in one stops the loop and comes out of
// uv.run(). An active handle (a running timer, a listening or reading
// socket, a pending connect) keeps its userdata alive; a handle collected
// before it was closed is closed by its finalizer. Failing calls raise the
// same kind of error text.
//
// uv.c_api is a userdata holding the C API (slang_uv.h) through which other
// extensions (sqlite, crypto) run work on libuv's thread pool.
local m = {}

local timer_methods = {}
local timer_meta = {__index: timer_methods, __type: "uv.timer"}

local tcp_methods = {}
local tcp_meta = {__index: tcp_methods, __type: "uv.tcp"}

local pipe_methods = {}
local pipe_meta = {__index: pipe_methods, __type: "uv.pipe"}

local signal_methods = {}
local signal_meta = {__index: signal_methods, __type: "uv.signal"}

local process_methods = {}
local process_meta = {__index: process_methods, __type: "uv.process"}

local poll_methods = {}
local poll_meta = {__index: poll_methods, __type: "uv.poll"}

// ------------------------------------------------------------ the loop

// run([mode]) -> whether there is more to do; mode "default" (run until
// nothing is active), "once" or "nowait". Raises when the loop is already
// running, or with the error a callback raised.
func m.run(mode){}

// stop() makes the running uv.run() return soon
func m.stop(){}

// now() -> the loop's idea of the time in milliseconds
func m.now(){}

// hrtime() -> a high-resolution time in nanoseconds, for measuring
func m.hrtime(){}

// loop_alive() -> whether the loop has active, referenced handles or
// requests
func m.loop_alive(){}

// version() -> the libuv version text
func m.version(){}

// ------------------------------------------------------------ timers

// timer() -> a new uv.timer
func m.timer(){ return {meta: timer_meta} }

// timer:start(timeout, repeat, cb) calls cb() after timeout milliseconds,
// then every repeat milliseconds unless repeat is 0 (or null)
func timer_methods.start(timer, timeout, repeat, cb){}

// timer:stop() stops the timer
func timer_methods.stop(timer){}

// timer:again() restarts a repeating timer with its repeat interval
func timer_methods.again(timer){}

// timer:close([cb]) closes the handle; cb() runs once it is closed
func timer_methods.close(timer, cb){}

// timer:is_active() -> whether the timer is running
func timer_methods.is_active(timer){}

// timer:is_closing() -> whether close() was called
func timer_methods.is_closing(timer){}

// timer:ref() makes the handle keep uv.run() going again (the default)
func timer_methods.ref(timer){}

// timer:unref() makes the handle no longer keep uv.run() going
func timer_methods.unref(timer){}

// timer:has_ref() -> whether the handle keeps uv.run() going
func timer_methods.has_ref(timer){}

// ------------------------------------------------------------ tcp

// tcp() -> a new uv.tcp socket
func m.tcp(){ return {meta: tcp_meta} }

// tcp:bind(ip, port) binds the socket to an IPv4 or IPv6 address (not a
// host name)
func tcp_methods.bind(tcp, ip, port){}

// tcp:listen([backlog], cb) listens for connections (backlog 128, pass
// null for it); cb(err) runs for each one, which accept() then takes
func tcp_methods.listen(tcp, backlog, cb){}

// tcp:accept(client) accepts a pending connection into client, a new
// uv.tcp or uv.pipe
func tcp_methods.accept(tcp, client){}

// tcp:connect(ip, port, cb) connects to an IPv4 or IPv6 address (not a
// host name); cb(err) when done
func tcp_methods.connect(tcp, ip, port, cb){}

// tcp:read_start(cb) reads: cb(err, chunk) for each chunk, with chunk null
// at the end of the stream; reading stops at the end or an error
func tcp_methods.read_start(tcp, cb){}

// tcp:read_stop() stops reading
func tcp_methods.read_stop(tcp){}

// tcp:write(data, [cb]) queues a copy of data; cb(err) once written
func tcp_methods.write(tcp, data, cb){}

// tcp:shutdown([cb]) closes the write side after pending writes; cb(err)
func tcp_methods.shutdown(tcp, cb){}

// tcp:getsockname() -> {ip, port, family} of the local end; family "ipv4"
// or "ipv6"
func tcp_methods.getsockname(tcp){}

// tcp:getpeername() -> {ip, port, family} of the remote end
func tcp_methods.getpeername(tcp){}

// tcp:nodelay(enable) turns Nagle's algorithm off (true) or on
func tcp_methods.nodelay(tcp, enable){}

// tcp:keepalive(enable, [delay]) turns TCP keep-alive on or off; delay is
// the initial delay in seconds (60)
func tcp_methods.keepalive(tcp, enable, delay){}

// tcp:fileno() -> the OS file descriptor
func tcp_methods.fileno(tcp){}

// tcp:close([cb]) closes the handle; cb() runs once it is closed
func tcp_methods.close(tcp, cb){}

// tcp:is_active() -> whether the socket is listening, reading or
// connecting
func tcp_methods.is_active(tcp){}

// tcp:is_closing() -> whether close() was called
func tcp_methods.is_closing(tcp){}

// tcp:ref() makes the handle keep uv.run() going again (the default)
func tcp_methods.ref(tcp){}

// tcp:unref() makes the handle no longer keep uv.run() going
func tcp_methods.unref(tcp){}

// tcp:has_ref() -> whether the handle keeps uv.run() going
func tcp_methods.has_ref(tcp){}

// ------------------------------------------------------------ pipes

// pipe() -> a new uv.pipe: stdin/stdout, a child's stdio, or a named pipe
func m.pipe(){ return {meta: pipe_meta} }

// pipe:open(fd) takes over an existing file descriptor (0 for stdin, 1 for
// stdout)
func pipe_methods.open(pipe, fd){}

// pipe:read_start(cb) reads: cb(err, chunk) for each chunk, with chunk
// null at the end of the stream
func pipe_methods.read_start(pipe, cb){}

// pipe:read_stop() stops reading
func pipe_methods.read_stop(pipe){}

// pipe:write(data, [cb]) queues a copy of data; cb(err) once written
func pipe_methods.write(pipe, data, cb){}

// pipe:shutdown([cb]) closes the write side after pending writes; cb(err)
func pipe_methods.shutdown(pipe, cb){}

// pipe:fileno() -> the OS file descriptor
func pipe_methods.fileno(pipe){}

// pipe:close([cb]) closes the handle; cb() runs once it is closed
func pipe_methods.close(pipe, cb){}

// pipe:is_active() -> whether the pipe is reading or writing
func pipe_methods.is_active(pipe){}

// pipe:is_closing() -> whether close() was called
func pipe_methods.is_closing(pipe){}

// pipe:ref() makes the handle keep uv.run() going again (the default)
func pipe_methods.ref(pipe){}

// pipe:unref() makes the handle no longer keep uv.run() going
func pipe_methods.unref(pipe){}

// pipe:has_ref() -> whether the handle keeps uv.run() going
func pipe_methods.has_ref(pipe){}

// ------------------------------------------------------------ signals

// signal() -> a new uv.signal watcher
func m.signal(){ return {meta: signal_meta} }

// signal:start(sig, cb) watches for sig, a number or a name like "SIGINT";
// cb(err, name) for each delivery (the number when it has no name here)
func signal_methods.start(signal, sig, cb){}

// signal:stop() stops watching
func signal_methods.stop(signal){}

// signal:close([cb]) closes the handle; cb() runs once it is closed
func signal_methods.close(signal, cb){}

// signal:is_active() -> whether the watcher is started
func signal_methods.is_active(signal){}

// signal:is_closing() -> whether close() was called
func signal_methods.is_closing(signal){}

// signal:ref() makes the handle keep uv.run() going again (the default)
func signal_methods.ref(signal){}

// signal:unref() makes the handle no longer keep uv.run() going (a watcher
// that should not stop the program from ending)
func signal_methods.unref(signal){}

// signal:has_ref() -> whether the handle keeps uv.run() going
func signal_methods.has_ref(signal){}

// ------------------------------------------------------------ processes

// spawn(file, args, options, cb) -> a uv.process running file. args is the
// list of arguments after the program name (or null). options (or null):
// cwd; env, a table of names to values replacing the environment;
// detached; stdio, a list for fds 0, 1, 2, ... whose entries are a uv.pipe
// (connected to the child), "inherit", an int (that fd of this process) or
// "ignore" (without stdio the child inherits 0, 1 and 2).
// cb(err, {status, signal}) when it exits; signal only when a signal ended
// it. Raises when the program cannot be started.
func m.spawn(file, args, options, cb){ return {meta: process_meta} }

// kill(pid, [sig]) sends sig (a number or a name, "SIGTERM" by default) to
// the process pid
func m.kill(pid, sig){}

// getpid() -> the id of this process
func m.getpid(){}

// process:pid() -> the child's process id
func process_methods.pid(process){}

// process:kill([sig]) sends sig (a number or a name, "SIGTERM" by
// default) to the child
func process_methods.kill(process, sig){}

// process:close([cb]) closes the handle; cb() runs once it is closed
func process_methods.close(process, cb){}

// process:is_active() -> whether the handle is active
func process_methods.is_active(process){}

// process:is_closing() -> whether close() was called
func process_methods.is_closing(process){}

// process:ref() makes the handle keep uv.run() going again (the default)
func process_methods.ref(process){}

// process:unref() makes the handle no longer keep uv.run() going
func process_methods.unref(process){}

// process:has_ref() -> whether the handle keeps uv.run() going
func process_methods.has_ref(process){}

// ------------------------------------------------------------ polling

// poll(fd) -> a uv.poll watching a socket or pipe that another library
// owns (a database client, say)
func m.poll(fd){ return {meta: poll_meta} }

// poll:start(events, cb) watches for events "r", "w" or "rw";
// cb(err, events) with the events that happened
func poll_methods.start(poll, events, cb){}

// poll:stop() stops watching
func poll_methods.stop(poll){}

// poll:close([cb]) closes the handle; cb() runs once it is closed
func poll_methods.close(poll, cb){}

// poll:is_active() -> whether the watcher is started
func poll_methods.is_active(poll){}

// poll:is_closing() -> whether close() was called
func poll_methods.is_closing(poll){}

// poll:ref() makes the handle keep uv.run() going again (the default)
func poll_methods.ref(poll){}

// poll:unref() makes the handle no longer keep uv.run() going
func poll_methods.unref(poll){}

// poll:has_ref() -> whether the handle keeps uv.run() going
func poll_methods.has_ref(poll){}

// ------------------------------------------------------------ names

// getaddrinfo(host, [port], [family], cb) resolves host; cb(err, list of
// {ip, port, family}). port is a number, a service name or null; family
// "ipv4" or "ipv6" limits the answers.
func m.getaddrinfo(host, port, family, cb){}

// ------------------------------------------------------------ files

// fs_read_file(path, cb) reads the whole file; cb(err, data)
func m.fs_read_file(path, cb){}

// fs_write_file(path, data, [append], cb) creates or replaces the file, or
// appends to it when append is true; cb(err)
func m.fs_write_file(path, data, append, cb){}

// fs_stat(path, cb) -> cb(err, {size, mode, mtime, atime, ctime, is_file,
// is_dir}); the times in seconds
func m.fs_stat(path, cb){}

// fs_unlink(path, cb) removes a file; cb(err)
func m.fs_unlink(path, cb){}

// fs_mkdir(path, cb) makes a directory; cb(err)
func m.fs_mkdir(path, cb){}

// fs_rmdir(path, cb) removes an empty directory; cb(err)
func m.fs_rmdir(path, cb){}

// fs_rename(from, to, cb) renames a file or directory; cb(err)
func m.fs_rename(from, to, cb){}

// fs_scandir(path, cb) lists a directory; cb(err, list of {name, type})
// with type "file", "dir", "link", "unknown" or "other"
func m.fs_scandir(path, cb){}

// fs_open(path, flags, cb) opens a file; cb(err, fd). flags as in fopen:
// "r", "r+", "w", "w+", "a", "a+", and "wx" or "w+x" to fail when the file
// exists.
func m.fs_open(path, flags, cb){}

// fs_read(fd, length, offset, cb) -> cb(err, data); offset -1 or null
// reads at the current position. data is shorter at the end of the file,
// "" past it.
func m.fs_read(fd, length, offset, cb){}

// fs_write(fd, data, offset, cb) writes all of data at offset (-1 or null:
// the current position); cb(err, written)
func m.fs_write(fd, data, offset, cb){}

// fs_close(fd, cb) closes a file descriptor; cb(err)
func m.fs_close(fd, cb){}

return m
