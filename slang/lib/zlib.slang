// slang/zlib: deflate and inflate (zlib) in the gzip, zlib and raw
// formats, at once or as a stream. slang/http uses it for compressed
// responses.
//
//   local zlib = require("slang/zlib")
//   local packed = zlib.deflate("hello hello hello")
//   zlib.inflate(packed)  // "hello hello hello"
//   zlib.deflate(data, {format: "zlib", level: 9})
//
//   local c = zlib.compressor({format: "gzip"})
//   local out = concat(c:push("part one, "), c:push("part two"), c:finish())
//   c.done   // true
//
// Formats: "gzip", "zlib", "raw", and for inflating also "auto" (gzip or
// zlib, told apart by the header). Errors read "zlib: ...". [c] is the
// native extension under this module.

local native = require("zlib")
local zlib = {}

// The native extension: deflate(data, format, level), inflate(data,
// format, max_size), compressor(format, level), decompressor(format,
// max_size).
zlib.c = native

// version() -> string
// The version of the zlib library.
zlib.version = native.version

// deflate(data: string, options?: {format?: string, level?: int}) -> string
// data compressed.
// [format]: "gzip" (the default), "zlib" or "raw"
// [level]: 0 (none) to 9 (smallest), 6 by default
func zlib.deflate(data, options){
  local o = options or {}
  return native.deflate(data, o.format, o.level)
}

// inflate(data: string, options?: {format?: string, max_size?: int})
//   -> string
// data decompressed; raises when it is not data of the format or would
// grow past max_size.
// [format]: "auto" (the default), "gzip", "zlib" or "raw"
// [max_size]: bounds the output; 0 (the default) means no bound
func zlib.inflate(data, options){
  local o = options or {}
  return native.inflate(data, o.format, o.max_size)
}

local stream_methods = {}
local stream_get = {}

// A compressor or decompressor fed in chunks, from [compressor] or
// [decompressor].
// type Stream
local stream_meta = {
  __type: "zlib.Stream", __index: stream_methods, __get: stream_get
}

// done(self) -> bool
// Whether [Stream.finish] was called.
func stream_get.done(s){
  return s.handle:is_done()
}

// push(chunk: string) -> string
// Feeds a chunk; returns what is ready of the output (maybe "").
func stream_methods.push(s, chunk){
  return s.handle:push(chunk)
}

// flush() -> string
// What is pending of the output, so that the receiver has all the data
// pushed so far.
func stream_methods.flush(s){
  return s.handle:flush()
}

// finish() -> string
// The rest of the output; the stream is done.
func stream_methods.finish(s){
  return s.handle:finish()
}

// compressor(options?: {format?: string, level?: int}) -> Stream
// A stream that compresses what is pushed (options as for [deflate]).
func zlib.compressor(options){
  local o = options or {}
  return {@meta: stream_meta, handle: native.compressor(o.format, o.level)}
}

// decompressor(options?: {format?: string, max_size?: int}) -> Stream
// A stream that decompresses what is pushed (options as for [inflate];
// max_size bounds the total output).
func zlib.decompressor(options){
  local o = options or {}
  return {
    @meta: stream_meta, handle: native.decompressor(o.format, o.max_size)
  }
}

return zlib
