// llhttp: the native binding of llhttp, the HTTP/1 parser of Node.js.
// slang/http parses requests and responses with it; most code should use
// slang/http.
//
//   local llhttp = require("llhttp")
//   local p = llhttp.parser("request", {max_head: 65536})
//   for(let local e in values(p:execute(bytes))){ ... }
//
// execute(data) feeds bytes and returns the list of events they completed,
// in order:
//   {type: "head", method, url, version, headers, keep_alive, upgrade,
//    chunked, content_length}             (requests)
//   {type: "head", status, reason, version, headers, ...}  (responses)
//   {type: "body", data}                  a piece of the body, de-chunked
//   {type: "done", keep_alive}            the message is complete
//   {type: "upgrade", rest}               the connection switches protocol
//                                         (rest: the bytes after the head)
//   {type: "error", code, reason, status} the input is not HTTP; status is
//                                         431 for a head over max_head,
//                                         else 400; the parser stays failed
// Header names are lowercased. A repeated header is joined with ", "
// (cookie with "; "), except set-cookie, which is always a list.
local m = {}

local parser_methods = {}
local parser_meta = {__index: parser_methods, __type: "llhttp.parser"}

// parser(kind, [options]) -> an llhttp.parser; kind "request" or
// "response". options.max_head limits the bytes of a head (0, the default:
// no limit).
func m.parser(kind, options){ return {meta: parser_meta} }

// version() -> the llhttp version as "major.minor.patch"
func m.version(){}

// ------------------------------------------------------------ parsers

// parser:execute(data) -> the list of events data completed; an empty
// list once the parser has failed (or switched protocol)
func parser_methods.execute(parser, data){}

// parser:finish() -> the events that ending the input gives (a response
// that runs to the end of the connection completes)
func parser_methods.finish(parser){}

// parser:skip_body() makes the next head have no body (the answer to a
// HEAD request)
func parser_methods.skip_body(parser){}

// parser:reset() readies the parser for a new connection
func parser_methods.reset(parser){}

return m
