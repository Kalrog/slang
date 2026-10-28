// A router: handlers by method and path pattern.
//
//   local app = router.new()
//   app:route("GET", "/todos/:id", func(req, params){ ... params.id ... })
//   app:route("GET", "/static/*", func(req, params){ ... params.rest ... })
//   app.fallback = func(req){ ... }        // when nothing matches
//   app:dispatch(req)                      // what the handler returned
//
// A handler returns what an http handler returns: a string, a response
// table or a Future. `:name` matches one segment, a final `*` the rest of
// the path.
local str = require("slang/string")
local m = {}
local methods = {}
local meta = {__index: methods, __type: "router"}

func m.new(){
  return {meta: meta, routes: {}, fallback: null}
}

func methods.route(self, method, pattern, handler){
  append(self.routes, {method: method, parts: str.split(pattern, "/"), handler: handler})
}

// the params of r for the request's path segments, or null when it does not match
local func match(r, parts){
  local params = {}
  for(local i = 0; i < len(r.parts); i = i + 1){
    local p = r.parts[i]
    if(p == "*"){
      local rest = {}
      for(local j = i; j < len(parts); j = j + 1){
        append(rest, parts[j])
      }
      params.rest = str.join(rest, "/")
      return params
    }
    if(i >= len(parts)){
      return null
    }
    if(str.starts_with(p, ":")){
      params[str.substring(p, 1)] = parts[i]
    } else if(p != parts[i]){
      return null
    }
  }
  if(len(parts) != len(r.parts)){
    return null
  }
  return params
}

func methods.dispatch(self, req){
  local parts = str.split(req.path, "/")
  for(let local r in values(self.routes)){
    if(r.method == req.method){
      local params = match(r, parts)
      if(params != null){
        return r.handler(req, params)
      }
    }
  }
  if(self.fallback != null){
    return self.fallback(req)
  }
  return {status: 404, body: concat("no route for ", req.path, "\n")}
}

return m
