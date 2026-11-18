// notebook/protocol: how a kernel and what started it talk.
//
// The kernel reads commands from its standard input, a JSON object per
// line ({op: "execute", id, code, origin?, line?}, {op: "variables", id},
// {op: "shutdown"}), and reports on its standard output, in the middle of
// what the cells print: an event is a frame, an escape sequence that
// carries the kernel's token and a JSON object,
//
//   ESC _ slangnb:<token>: {"event": "done", "id": "c1", ...} ESC \ newline
//
// so what a cell printed before an event is before it in the stream, and
// text printed by C code is captured like any other. The token is made by
// whoever starts the kernel: a cell cannot write an event by accident.
//
// The events: ready {project, error}; start {id}; display and result {id,
// data: the forms by MIME type}; clear {id}; error {id, error: {kind,
// message, location, stack}}; done {id, status: "ok" | "error" |
// "interrupted", ms}; variables {id, variables}.
local str = require("slang/string")
local json = require("slang/json")

local protocol = {}

local OPEN = "\x1b_slangnb:"
local CLOSE = "\x1b\\\n"

// frame(token: string, event: table) -> string
// The bytes of an event, to write to standard output.
func protocol.frame(token, event){
  return concat(OPEN, token, ":", json.encode(event), CLOSE)
}

// What splits a kernel's output into text and events, from [parser].
// type Parser = {feed: func(chunk: string), finish: func()}
// [feed]: takes the next bytes read
// [finish]: the stream ended: what was held back is text

// parser(token: string, on_text: func(text: string),
//   on_event: func(event: table)) -> Parser
// Splits the output of the kernel with the token: on_text for what the
// cells printed, on_event for each event, in the order they were written.
func protocol.parser(token, on_text, on_event){
  local mark = concat(OPEN, token, ":")
  local buffer = ""
  local func text(s){
    if(s != ""){
      on_text(s)
    }
  }
  // how many bytes at the end of the buffer may be the start of a frame
  local func held(){
    local n = len(buffer)
    local most = len(mark) - 1
    if(most > n){
      most = n
    }
    for(local k = most; k > 0; k = k - 1){
      if(str.ends_with(buffer, str.substring(mark, 0, k))){
        return k
      }
    }
    return 0
  }
  local p = {}
  func p.feed(chunk){
    buffer = concat(buffer, chunk)
    for(true){
      local at = str.index_of(buffer, mark)
      if(at < 0){
        local keep = held()
        text(str.substring(buffer, 0, len(buffer) - keep))
        buffer = str.substring(buffer, len(buffer) - keep)
        break
      }
      local stop = str.index_of(buffer, CLOSE, at + len(mark))
      if(stop < 0){
        // the frame is not whole yet
        text(str.substring(buffer, 0, at))
        buffer = str.substring(buffer, at)
        break
      }
      text(str.substring(buffer, 0, at))
      local body = str.substring(buffer, at + len(mark), stop)
      buffer = str.substring(buffer, stop + len(CLOSE))
      local event = try { json.decode(body) } catch { null }
      if(type(event) == "table"){
        on_event(event)
      }
    }
  }
  func p.finish(){
    text(buffer)
    buffer = ""
  }
  return p
}

return protocol
