// navigate/typed: a module with types in its docs, for the tests
local typed = {}

// What a handler receives.
// type Request = {method: string, path: string, body?: string}
// [body]: null when it was streamed

// type Server
local server_methods = {}

// close(): stops listening
func server_methods.close(s){}

// serve(port: int, handler: func(req: Request): string) -> server: Server
// Serves on [port] until [Server.close].
// [port]: 0 picks a free one
// [server]: the running server
func typed.serve(port, handler){
  return {@meta: {__index: server_methods}}
}

return typed
