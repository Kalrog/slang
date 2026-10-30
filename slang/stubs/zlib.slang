// zlib: the native binding of zlib (deflate and inflate in the gzip, zlib
// and raw formats), at once or as a stream. slang/http uses it for
// compressed responses; most code gets compression from there.
//
//   local zlib = require("zlib")
//   local packed = zlib.deflate("hello hello hello")
//   zlib.inflate(packed)  // "hello hello hello"
//
// Formats: "gzip", "zlib", "raw", and for inflating also "auto" (gzip or
// zlib, told apart by the header). Errors read "zlib: ...".
local m = {}

local stream_methods = {}
local stream_meta = {__index: stream_methods, __type: "zlib.stream"}

// ------------------------------------------------------------ at once

// deflate(data, [format], [level]) -> the compressed bytes; format "gzip"
// (the default), "zlib" or "raw", level 0 to 9 (6)
func m.deflate(data, format, level){}

// inflate(data, [format], [max_size]) -> the decompressed bytes; format
// "auto" (the default), "gzip", "zlib" or "raw". max_size bounds the
// output (0, the default, means no bound); going over raises, and so does
// input that is cut short.
func m.inflate(data, format, max_size){}

// version() -> the version of the zlib library
func m.version(){}

// ------------------------------------------------------------ streams

// compressor([format], [level]) -> a zlib.stream that compresses; format
// "gzip" (the default), "zlib" or "raw", level 0 to 9 (6)
func m.compressor(format, level){ return {meta: stream_meta} }

// decompressor([format], [max_size]) -> a zlib.stream that decompresses;
// format "auto" (the default), "gzip", "zlib" or "raw"; max_size bounds the
// total output (0: no bound), going over raises
func m.decompressor(format, max_size){ return {meta: stream_meta} }

// stream:push(chunk) -> the output so far ("" is common). A decompressor
// ignores bytes after the end of the compressed stream.
func stream_methods.push(stream, chunk){}

// stream:flush() -> output that lets the reader decode everything pushed
// so far; "" for a decompressor
func stream_methods.flush(stream){}

// stream:finish() -> the rest of the output; the stream is done and raises
// on further use. A decompressor raises when the input was cut short.
func stream_methods.finish(stream){}

// stream:is_done() -> true once the end of the compressed stream was
// reached or finish() was called
func stream_methods.is_done(stream){}

return m
