// slang/isolate: parallelism without shared state, built into the VM. An
// isolate is a VM of its own (heap, collector, globals, modules) on an OS
// thread of its own, so isolates run in parallel; they share nothing and
// talk through channels, which copy what is sent.
//
//   local isolate = require("slang/isolate")
//   local jobs = isolate.channel()
//   local results = isolate.channel()
//   local worker = isolate.spawn(func(jobs, results){
//     local iso = require("slang/isolate")    // a fresh VM: it requires
//     for(let local job in iso.each(jobs)){    // what it needs itself
//       results:send({id: job.id, area: job.w * job.h})
//     }
//     return "done"
//   }, jobs, results)
//   jobs:send({id: 1, w: 2, h: 3})            // copied
//   jobs:close()
//   results:receive().area                    // 6, waiting for it
//   worker:join()                             // "done"
//
// What crosses (the arguments of spawn, a function's result, a value sent
// through a channel) is copied into the receiving heap: null, bools,
// numbers, strings, tables (with their metatables; cycles and tables that
// appear twice in one value stay so) and functions. A function crosses as
// bytecode and is loaded with the receiver's globals: it may use globals and
// what it requires itself, but not locals of the code around it (an error
// names the variable). Channels, isolates and shared buffers
// (slang/buffer's shared) cross by reference: both sides use the same one.
// Coroutines, other buffers and other userdata do not cross.
//
// Every isolate has an event loop of its own: slang/async and the uv module
// work in any of them (async.main in an isolate drives that isolate's
// loop), and async.receive waits for a channel without blocking the loop.
// Handles do not cross; what an isolate leaves open is closed when it ends,
// and kill wakes an isolate waiting in its loop.
//
// The main program ending ends the process: isolates still running stop
// with it, so join the ones whose work matters. An isolate's error nobody
// joined is printed to stderr when the program ends. In a browser (the
// playground) there are no threads: available() is false and spawn raises.

// An isolate, as spawn returns it; == compares which isolate.
// type Isolate = {join: func(): any, kill: func(), running: bool, id: int}
// [join]: waits for the isolate's function to return and gives its result
//   (copied; again on every join), or raises its error, with the location
//   and traceback where it was raised in the isolate. A killed isolate
//   gives null.
// [kill]: stops the isolate at its next safe point (a call, a loop, a
//   channel it waits on; code inside a C call stops when it returns) and
//   waits until it has; try and pcall do not catch the stop.
// [running]: whether its function has not returned yet
// [id]: a number for the isolate, from 1

// A channel: a queue of copied values between isolates (or within one);
// == compares which channel. A channel is unbounded unless made with a
// capacity: send never blocks then.
// type Channel = {send: func(v: any), receive: func(): any,
//   try_send: func(v: any): bool, try_receive: func(): any,
//   close: func(), closed: bool, len: int, capacity: int?,
//   watch: func(h: any), unwatch: func(h: any)}
// [send]: copies v into the channel; blocks while a channel with a
//   capacity is full; raises when the channel is closed. null cannot be
//   sent: receive gives null for a closed channel.
// [receive]: the next value, waiting until there is one; null once the
//   channel is closed and empty
// [try_send]: like send, but returns false instead of blocking on a full
//   channel
// [try_receive]: the next value, or null when none is queued (closed
//   tells whether more can come)
// [close]: no more sends; what is queued can still be received
// [closed]: whether close was called
// [len]: how many values are queued
// [capacity]: the capacity, or null for an unbounded channel
// [watch]: sends the uv async handle h (uv.async(cb)) whenever the channel
//   changes, and at once when values are queued; how slang/async's receive
//   wakes the loop. unwatch before closing h.
// [unwatch]: stops sending h
local m = {}

// available() -> bool
// Whether isolates can run here: false in a browser, which has no threads.
func m.available(){}

// spawn(f: function, ...args) -> Isolate
// Runs f(args) in a new isolate, in parallel with the caller, and returns
// at once. f and the arguments are copied as described above; f must not
// use locals of the code around it. The isolate finds modules where the
// caller does (the same search paths and program arguments).
//   local w = isolate.spawn(func(n){ return n * n }, 12)
//   w:join()    // 144
func m.spawn(f, ...args){}

// channel(options?: {capacity?: int}) -> Channel
// A new channel, unbounded unless options.capacity (at least 1) limits how
// many values it holds; send blocks on a full one.
func m.channel(options){}

// each(ch: Channel) -> function
// An iterator over the values of ch: receives until ch is closed and
// empty. Like every iterator it also stops at a value of false.
//   for(let local job in isolate.each(jobs)){ ... }
func m.each(ch){}

// id() -> int
// The running isolate's id; the main program's is 0.
func m.id(){}


return m
