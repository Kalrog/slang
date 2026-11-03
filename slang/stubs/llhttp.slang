// llhttp: the native binding of llhttp, the HTTP/1 parser of Node.js.
// slang/http parses requests and responses with it; most code should use
// slang/http.
//
//   local llhttp = require("llhttp")
//   local p = llhttp.parser("request", {max_head: 65536})
//   local events = p:execute("GET /hi HTTP/1.1\r\nHost: x\r\n\r\n")
//   events[0].url      // "/hi"
//   events[1].type     // "done"
//
// [Parser.execute] feeds bytes and returns the list of [Event]s they
// completed, in order: a "head", then "body" pieces, then "done" for each
// message; "upgrade" when the connection switches protocol, "error" when
// the input is not HTTP.

// What a [Parser] reports; which fields are set depends on type.
// type Event = {type: string, method?: string, url?: string,
//   status?: int, reason?: string, version?: string,
//   headers?: {[string]: string | {string}}, keep_alive?: bool,
//   upgrade?: bool, chunked?: bool, content_length?: int, data?: string,
//   rest?: string, code?: string}
// [type]: "head", "body", "done", "upgrade" or "error"
// [method]: head of a request: the method, "GET"
// [url]: head of a request: the request target
// [status]: head of a response: its status code; error: 431 for a head over max_head, else 400
// [reason]: head of a response: its reason phrase; error: what is wrong
// [version]: head: "1.1" and the like
// [headers]: head: by lowercased name; a repeated header is joined with ", " (cookie with "; "), except set-cookie, which is always a list
// [keep_alive]: head and done: whether the connection may carry another message
// [upgrade]: head: whether the message asks to switch protocol
// [chunked]: head: whether the body is chunked
// [content_length]: head: the Content-Length, when there is one
// [data]: body: a piece of the body, de-chunked
// [rest]: upgrade: the bytes after the head, which belong to the new protocol
// [code]: error: llhttp's error name, like "HPE_INVALID_METHOD"

local m = {}

// How a [Parser] limits its input.
// type ParserOptions = {max_head?: int}
// [max_head]: the most bytes a head may have; 0 (the default) means no limit

// A parser of one connection's messages; type() of it is
// "llhttp.parser".
// type Parser
local parser_methods = {}
local parser_meta = {__index: parser_methods, __type: "llhttp.parser"}

// parser(kind: string, options?: ParserOptions) -> Parser
// A new parser of requests (kind "request") or responses ("response").
func m.parser(kind, options){ return {@meta: parser_meta} }

// version() -> string
// The llhttp version as "major.minor.patch".
func m.version(){}

// ------------------------------------------------------------ parsers

// execute(data: string) -> {Event}
// Feeds data and returns the events it completed. After an "error" event
// the parser stays failed, and after "upgrade" it is done: execute then
// returns an empty list.
func parser_methods.execute(parser, data){}

// finish() -> {Event}
// The events that ending the input gives (a response that runs to the end
// of the connection completes).
func parser_methods.finish(parser){}

// skip_body()
// Makes the next head have no body (the answer to a HEAD request).
func parser_methods.skip_body(parser){}

// reset()
// Readies the parser for a new connection.
func parser_methods.reset(parser){}

return m
