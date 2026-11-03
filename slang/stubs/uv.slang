// uv: the native binding of libuv in the callback style of luv. Most code
// should use slang/async, which builds Futures and Streams on it.
//
//   local uv = require("uv")
//   local t = uv.timer()
//   t:start(100, 0, func(){
//     print("tick\n")
//     t:close()
//   })
//   uv.run()
//
// Handles ([Timer], [Tcp], [Udp], [Pipe], [Signal], [Process], [Poll]) are
// userdata with methods; every operation takes its callback last, and
// callbacks have the shape cb(err, value) with err a string like
// "ECONNRESET: connection reset by peer" or null. Callbacks run only from
// inside [run]; an error raised in one stops the loop and comes out of
// [run]. An active handle (a running timer, a listening or reading socket,
// a pending connect) keeps its userdata alive; a handle collected before
// it was closed is closed by its finalizer. Failing calls raise the same
// kind of error text.
//
// Every VM has a loop of its own, so isolates (slang/isolate) run event
// loops side by side; handles cannot cross between them, and what an
// isolate leaves open is closed with its loop when it ends. Killing an
// isolate wakes its loop: [run] raises "isolate killed".
//
// uv.c_api is a userdata holding the C API (slang_uv.h) through which other
// extensions (sqlite, crypto) run work on libuv's thread pool.
local m = {}

// What a callback that may fail receives first: an error text like
// "ENOENT: no such file or directory", or null.
// type Err = string?

// A network address.
// type Address = {ip: string, port: int, family: string}
// [family]: "ipv4" or "ipv6"

// A timer; type() of it is "uv.timer".
// type Timer
local timer_methods = {}
local timer_meta = {__index: timer_methods, __type: "uv.timer"}

// A TCP socket, listening or connected; type() of it is "uv.tcp".
// type Tcp
local tcp_methods = {}
local tcp_meta = {__index: tcp_methods, __type: "uv.tcp"}

// A UDP socket; type() of it is "uv.udp".
// type Udp
local udp_methods = {}
local udp_meta = {__index: udp_methods, __type: "uv.udp"}

// A pipe: stdin/stdout, a child's stdio or a named pipe; type() of it is
// "uv.pipe".
// type Pipe
local pipe_methods = {}
local pipe_meta = {__index: pipe_methods, __type: "uv.pipe"}

// A signal watcher; type() of it is "uv.signal".
// type Signal
local signal_methods = {}
local signal_meta = {__index: signal_methods, __type: "uv.signal"}

// A handle woken from other threads ([async]); type() of it is "uv.async".
// type Async
local async_methods = {}
local async_meta = {__index: async_methods, __type: "uv.async"}

// A child process started by [spawn]; type() of it is "uv.process".
// type Process
local process_methods = {}
local process_meta = {__index: process_methods, __type: "uv.process"}

// A watcher of a file descriptor another library owns; type() of it is
// "uv.poll".
// type Poll
local poll_methods = {}
local poll_meta = {__index: poll_methods, __type: "uv.poll"}

// ------------------------------------------------------------ the loop

// run(mode?: string) -> bool
// Runs the event loop and returns whether there is more to do. Raises when
// the loop is already running, or with the error a callback raised.
// [mode]: "default" (run until nothing is active), "once" or "nowait"
func m.run(mode){}

// running() -> bool
// Whether [run] is running: code called from a callback cannot run the
// loop again.
func m.running(){}

// stop()
// Makes the running [run] return soon.
func m.stop(){}

// now() -> int
// The loop's idea of the time in milliseconds.
func m.now(){}

// hrtime() -> int
// A high-resolution time in nanoseconds, for measuring.
func m.hrtime(){}

// loop_alive() -> bool
// Whether the loop has active, referenced handles or requests.
func m.loop_alive(){}

// version() -> string
// The libuv version text.
func m.version(){}

// ------------------------------------------------------------ timers

// timer() -> Timer
// A new timer, not started.
func m.timer(){ return {@meta: timer_meta} }

// start(timeout: int, repeat: int?, cb: func())
// Calls cb() after timeout milliseconds, then every repeat milliseconds
// unless repeat is 0 or null.
func timer_methods.start(timer, timeout, repeat, cb){}

// stop()
// Stops the timer.
func timer_methods.stop(timer){}

// again()
// Restarts a repeating timer with its repeat interval.
func timer_methods.again(timer){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func timer_methods.close(timer, cb){}

// is_active() -> bool
// Whether the timer is running.
func timer_methods.is_active(timer){}

// is_closing() -> bool
// Whether [Timer.close] was called.
func timer_methods.is_closing(timer){}

// ref()
// Makes the handle keep [run] going again (the default).
func timer_methods.ref(timer){}

// unref()
// Makes the handle no longer keep [run] going.
func timer_methods.unref(timer){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func timer_methods.has_ref(timer){}

// ------------------------------------------------------------ tcp

// tcp() -> Tcp
// A new TCP socket, neither bound nor connected.
func m.tcp(){ return {@meta: tcp_meta} }

// bind(ip: string, port: int)
// Binds the socket to an IPv4 or IPv6 address (not a host name).
func tcp_methods.bind(tcp, ip, port){}

// listen(backlog: int?, cb: func(err: Err))
// Listens for connections; cb(err) runs for each one, which
// [Tcp.accept] then takes.
// [backlog]: the queue length, 128 when null
func tcp_methods.listen(tcp, backlog, cb){}

// accept(client: Tcp | Pipe)
// Accepts a pending connection into client, a new [Tcp] or [Pipe].
func tcp_methods.accept(tcp, client){}

// connect(ip: string, port: int, cb: func(err: Err))
// Connects to an IPv4 or IPv6 address (not a host name; see
// [getaddrinfo]); cb(err) when done.
func tcp_methods.connect(tcp, ip, port, cb){}

// read_start(cb: func(err: Err, chunk: string?))
// Starts reading: cb(err, chunk) for each chunk, with chunk null at the
// end of the stream. Reading stops at the end or an error.
func tcp_methods.read_start(tcp, cb){}

// read_stop()
// Stops reading.
func tcp_methods.read_stop(tcp){}

// write(data: string, cb?: func(err: Err))
// Queues a copy of data; cb(err) once it is written.
func tcp_methods.write(tcp, data, cb){}

// shutdown(cb?: func(err: Err))
// Closes the write side after pending writes; cb(err) when done.
func tcp_methods.shutdown(tcp, cb){}

// getsockname() -> Address
// The local end of the socket.
func tcp_methods.getsockname(tcp){}

// getpeername() -> Address
// The remote end of the socket.
func tcp_methods.getpeername(tcp){}

// nodelay(enable: bool)
// Turns Nagle's algorithm off (true) or on.
func tcp_methods.nodelay(tcp, enable){}

// keepalive(enable: bool, delay?: int)
// Turns TCP keep-alive on or off.
// [delay]: the initial delay in seconds, 60 by default
func tcp_methods.keepalive(tcp, enable, delay){}

// fileno() -> int
// The OS file descriptor.
func tcp_methods.fileno(tcp){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func tcp_methods.close(tcp, cb){}

// is_active() -> bool
// Whether the socket is listening, reading or connecting.
func tcp_methods.is_active(tcp){}

// is_closing() -> bool
// Whether [Tcp.close] was called.
func tcp_methods.is_closing(tcp){}

// ref()
// Makes the handle keep [run] going again (the default).
func tcp_methods.ref(tcp){}

// unref()
// Makes the handle no longer keep [run] going.
func tcp_methods.unref(tcp){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func tcp_methods.has_ref(tcp){}

// ------------------------------------------------------------ udp

// udp() -> Udp
// A new UDP socket, not bound.
func m.udp(){ return {@meta: udp_meta} }

// bind(ip: string, port: int, options?: {reuse?: bool})
// Binds the socket to an IPv4 or IPv6 address (not a host name); port 0
// picks a free one ([Udp.getsockname] says which).
// [reuse]: other sockets may bind the same address
func udp_methods.bind(udp, ip, port, options){}

// send(data: string, ip: string, port: int)
// Sends one datagram (a copy of data), right away when the socket can take
// it, else queued. Datagrams may be lost or arrive out of order, so there
// is no callback.
func udp_methods.send(udp, data, ip, port){}

// recv_start(cb: func(err: Err, data: string?, from: Address?))
// Starts receiving: cb(err, data, from) for each datagram.
func udp_methods.recv_start(udp, cb){}

// recv_stop()
// Stops receiving.
func udp_methods.recv_stop(udp){}

// getsockname() -> Address
// The local address of the socket.
func udp_methods.getsockname(udp){}

// broadcast(enable: bool)
// Whether datagrams may go to broadcast addresses.
func udp_methods.broadcast(udp, enable){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func udp_methods.close(udp, cb){}

// is_active() -> bool
// Whether the socket is receiving.
func udp_methods.is_active(udp){}

// is_closing() -> bool
// Whether [Udp.close] was called.
func udp_methods.is_closing(udp){}

// ref()
// Makes the handle keep [run] going again (the default).
func udp_methods.ref(udp){}

// unref()
// Makes the handle no longer keep [run] going.
func udp_methods.unref(udp){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func udp_methods.has_ref(udp){}

// ------------------------------------------------------------ pipes

// pipe() -> Pipe
// A new pipe: for stdin/stdout ([Pipe.open]), a child's stdio ([spawn])
// or an accepted connection.
func m.pipe(){ return {@meta: pipe_meta} }

// open(fd: int)
// Takes over an existing file descriptor (0 for stdin, 1 for stdout).
func pipe_methods.open(pipe, fd){}

// read_start(cb: func(err: Err, chunk: string?))
// Starts reading: cb(err, chunk) for each chunk, with chunk null at the
// end of the stream.
func pipe_methods.read_start(pipe, cb){}

// read_stop()
// Stops reading.
func pipe_methods.read_stop(pipe){}

// write(data: string, cb?: func(err: Err))
// Queues a copy of data; cb(err) once it is written.
func pipe_methods.write(pipe, data, cb){}

// shutdown(cb?: func(err: Err))
// Closes the write side after pending writes; cb(err) when done.
func pipe_methods.shutdown(pipe, cb){}

// fileno() -> int
// The OS file descriptor.
func pipe_methods.fileno(pipe){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func pipe_methods.close(pipe, cb){}

// is_active() -> bool
// Whether the pipe is reading or writing.
func pipe_methods.is_active(pipe){}

// is_closing() -> bool
// Whether [Pipe.close] was called.
func pipe_methods.is_closing(pipe){}

// ref()
// Makes the handle keep [run] going again (the default).
func pipe_methods.ref(pipe){}

// unref()
// Makes the handle no longer keep [run] going.
func pipe_methods.unref(pipe){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func pipe_methods.has_ref(pipe){}

// ------------------------------------------------------------ signals

// signal() -> Signal
// A new signal watcher, not started.
func m.signal(){ return {@meta: signal_meta} }

// start(sig: int | string, cb: func(err: Err, name: string | int))
// Watches for sig, a number or a name like "SIGINT"; cb(err, name) for
// each delivery (the number when it has no name here).
func signal_methods.start(signal, sig, cb){}

// stop()
// Stops watching.
func signal_methods.stop(signal){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func signal_methods.close(signal, cb){}

// is_active() -> bool
// Whether the watcher is started.
func signal_methods.is_active(signal){}

// is_closing() -> bool
// Whether [Signal.close] was called.
func signal_methods.is_closing(signal){}

// ref()
// Makes the handle keep [run] going again (the default).
func signal_methods.ref(signal){}

// unref()
// Makes the handle no longer keep [run] going: for a watcher that should
// not stop the program from ending.
func signal_methods.unref(signal){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func signal_methods.has_ref(signal){}

// ------------------------------------------------------------ async handles

// async(cb: func()) -> Async
// A handle whose cb runs on the loop after a wake from any thread: another
// extension sends it through the C API (slang_uv.h's async_send), and an
// isolate's channel through [isolate.Channel.watch]. Several wakes before
// cb runs make one call. It keeps [run] going until it is closed.
func m.async(cb){ return {@meta: async_meta} }

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func async_methods.close(h, cb){}

// is_active() -> bool
// Whether the handle is open.
func async_methods.is_active(h){}

// is_closing() -> bool
// Whether [Async.close] was called.
func async_methods.is_closing(h){}

// ref()
// Makes the handle keep [run] going again (the default).
func async_methods.ref(h){}

// unref()
// Makes the handle no longer keep [run] going.
func async_methods.unref(h){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func async_methods.has_ref(h){}

// ------------------------------------------------------------ processes

// How [spawn] starts a program.
// type SpawnOptions = {cwd?: string, env?: {[string]: string},
//   detached?: bool, stdio?: {Pipe | string | int}}
// [cwd]: the directory to run in
// [env]: the whole environment of the child, replacing this process's
// [detached]: runs the child in its own process group
// [stdio]: fds 0, 1, 2, ...: a Pipe (connected to the child), "inherit", an int (that fd of this process) or "ignore"; without stdio the child inherits 0, 1 and 2

// How a child process ended.
// type ExitStatus = {status: int, signal?: string | int}
// [status]: the exit code
// [signal]: the signal that ended it (a name, or the number when it has none here); null when it exited

// spawn(file: string, args: {string}?, options: SpawnOptions?,
//       cb: func(err: Err, exit: ExitStatus)) -> Process
// Starts file (looked up on the PATH) and calls cb when it exits. Raises
// when the program cannot be started.
// [args]: the arguments after the program name, or null
func m.spawn(file, args, options, cb){ return {@meta: process_meta} }

// kill(pid: int, sig?: int | string)
// Sends sig (a number or a name, "SIGTERM" by default) to the process pid.
func m.kill(pid, sig){}

// getpid() -> int
// The id of this process.
func m.getpid(){}

// pid() -> int
// The child's process id.
func process_methods.pid(process){}

// kill(sig?: int | string)
// Sends sig (a number or a name, "SIGTERM" by default) to the child.
func process_methods.kill(process, sig){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func process_methods.close(process, cb){}

// is_active() -> bool
// Whether the handle is active.
func process_methods.is_active(process){}

// is_closing() -> bool
// Whether [Process.close] was called.
func process_methods.is_closing(process){}

// ref()
// Makes the handle keep [run] going again (the default).
func process_methods.ref(process){}

// unref()
// Makes the handle no longer keep [run] going.
func process_methods.unref(process){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func process_methods.has_ref(process){}

// ------------------------------------------------------------ polling

// poll(fd: int) -> Poll
// A watcher of a socket or pipe that another library owns (a database
// client, say), not started.
func m.poll(fd){ return {@meta: poll_meta} }

// start(events: string, cb: func(err: Err, events: string))
// Watches for events "r", "w" or "rw"; cb(err, events) with the events
// that happened.
func poll_methods.start(poll, events, cb){}

// stop()
// Stops watching.
func poll_methods.stop(poll){}

// close(cb?: func())
// Closes the handle; cb() runs once it is closed.
func poll_methods.close(poll, cb){}

// is_active() -> bool
// Whether the watcher is started.
func poll_methods.is_active(poll){}

// is_closing() -> bool
// Whether [Poll.close] was called.
func poll_methods.is_closing(poll){}

// ref()
// Makes the handle keep [run] going again (the default).
func poll_methods.ref(poll){}

// unref()
// Makes the handle no longer keep [run] going.
func poll_methods.unref(poll){}

// has_ref() -> bool
// Whether the handle keeps [run] going.
func poll_methods.has_ref(poll){}

// ------------------------------------------------------------ names

// getaddrinfo(host: string, port: int | string | null, family: string?,
//             cb: func(err: Err, addresses: {Address}))
// Resolves host.
// [port]: a number, a service name or null
// [family]: "ipv4" or "ipv6" limits the answers; null gives both
func m.getaddrinfo(host, port, family, cb){}

// ------------------------------------------------------------ files

// What [fs_stat] gives. The times are in milliseconds since the Unix epoch.
// type FileStat = {size: int, mode: int, mtime: float, atime: float,
//   ctime: float, is_file: bool, is_dir: bool}
// [mode]: the file type and permission bits (st_mode)

// A directory entry, from [fs_scandir].
// type DirEntry = {name: string, type: string}
// [type]: "file", "dir", "link", "unknown" or "other"

// fs_read_file(path: string, cb: func(err: Err, data: string?))
// Reads the whole file.
func m.fs_read_file(path, cb){}

// fs_write_file(path: string, data: string, append: bool?,
//               cb: func(err: Err))
// Creates or replaces the file, or appends to it when append is true.
func m.fs_write_file(path, data, append, cb){}

// fs_stat(path: string, cb: func(err: Err, stat: FileStat?))
// Reads what the file system knows about path.
func m.fs_stat(path, cb){}

// fs_unlink(path: string, cb: func(err: Err))
// Removes a file.
func m.fs_unlink(path, cb){}

// fs_mkdir(path: string, cb: func(err: Err))
// Makes a directory.
func m.fs_mkdir(path, cb){}

// fs_rmdir(path: string, cb: func(err: Err))
// Removes an empty directory.
func m.fs_rmdir(path, cb){}

// fs_rename(from: string, to: string, cb: func(err: Err))
// Renames a file or directory.
func m.fs_rename(from, to, cb){}

// fs_scandir(path: string, cb: func(err: Err, entries: {DirEntry}?))
// Lists a directory.
func m.fs_scandir(path, cb){}

// fs_open(path: string, flags: string, cb: func(err: Err, fd: int?))
// Opens a file and gives its descriptor.
// [flags]: as in fopen: "r", "r+", "w", "w+", "a", "a+", and "wx" or "w+x" to fail when the file exists
func m.fs_open(path, flags, cb){}

// fs_read(fd: int, length: int, offset: int?,
//         cb: func(err: Err, data: string?))
// Reads up to length bytes at offset. data is shorter at the end of the
// file, "" past it.
// [offset]: -1 or null reads at the current position
func m.fs_read(fd, length, offset, cb){}

// fs_write(fd: int, data: string, offset: int?,
//          cb: func(err: Err, written: int?))
// Writes all of data at offset.
// [offset]: -1 or null writes at the current position
func m.fs_write(fd, data, offset, cb){}

// fs_close(fd: int, cb: func(err: Err))
// Closes a file descriptor.
func m.fs_close(fd, cb){}

return m
