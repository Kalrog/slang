// Events are plain tables with a `kind` field. Handlers declared with
// `on PATTERN { ... }` (dsl/events) listen to all events and act on the ones
// that match. Scripts waiting on an event name (dsl/script) are woken too.
local m = {}

local listeners = {}
local log = {}

func m.listen(f){
  append(listeners, f)
  return f
}

func m.emit(e){
  append(log, e)
  local n = len(listeners)
  for(local i = 0; i < n; i = i + 1){
    listeners[i](e)
  }
  if(e.kind != null and m.on_emit != null){
    m.on_emit(e)
  }
  return e
}

// log() -> every event emitted so far (useful in tests); clear_log() resets it
func m.log(){
  return log
}

func m.clear_log(){
  log = {}
}

func m.clear(){
  listeners = {}
  log = {}
}

return m
