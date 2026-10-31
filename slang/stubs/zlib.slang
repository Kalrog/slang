// zlib: the native binding of zlib (deflate and inflate in the gzip, zlib
// and raw formats), at once or as a stream. slang/http uses it for
// compressed responses; most code gets compression from there.
//
//   local zlib = require("zlib")
//   local packed = zlib.deflate("hello hello hello")
//   zlib.inflate(packed)  // "hello hello hello"
//
//   local c = zlib.compressor("gzip")
//   local out = concat(c:push("part one, "), c:push("part two"), c:finish())
//
// Formats: "gzip", "zlib", "raw", and for inflating also "auto" (gzip or
// zlib, told apart by the header). Errors read "zlib: ...".
local m = {}

// A compressor or decompressor fed in chunks, from [compressor] or
// [decompressor]; type() of it is "zlib.stream".
// type Stream
local stream_methods = {}
local stream_meta = {__index: stream_methods, __type: "zlib.stream"}

// ------------------------------------------------------------ at once

// deflate(data: string, format?: string, level?: int) -> string
// The compressed bytes of data.
// [format]: "gzip" (the default), "zlib" or "raw"
// [level]: 0 (none) to 9 (smallest), 6 by default
func m.deflate(data, format, level){}

// inflate(data: string, format?: string, max_size?: int) -> string
// The decompressed bytes of data. Raises when the output would exceed
// max_size, and on input that is cut short or malformed.
// [format]: "auto" (the default), "gzip", "zlib" or "raw"
// [max_size]: bounds the output; 0 (the default) means no bound
func m.inflate(data, format, max_size){}

// version() -> string
// The version of the zlib library.
func m.version(){}

// ------------------------------------------------------------ streams

// compressor(format?: string, level?: int) -> Stream
// A stream that compresses.
// [format]: "gzip" (the default), "zlib" or "raw"
// [level]: 0 to 9, 6 by default
func m.compressor(format, level){ return {meta: stream_meta} }

// decompressor(format?: string, max_size?: int) -> Stream
// A stream that decompresses. Raises once its total output goes over
// max_size.
// [format]: "auto" (the default), "gzip", "zlib" or "raw"
// [max_size]: bounds the total output; 0 (the default) means no bound
func m.decompressor(format, max_size){ return {meta: stream_meta} }

// push(chunk: string) -> string
// Feeds chunk and returns the output so far ("" is common). A
// decompressor ignores bytes after the end of the compressed stream.
func stream_methods.push(stream, chunk){}

// flush() -> string
// Output that lets the reader decode everything pushed so far; "" for a
// decompressor.
func stream_methods.flush(stream){}

// finish() -> string
// The rest of the output; the stream is done and raises on further use. A
// decompressor raises when the input was cut short.
func stream_methods.finish(stream){}

// is_done() -> bool
// True once the end of the compressed stream was reached or
// [Stream.finish] was called.
func stream_methods.is_done(stream){}

return m
