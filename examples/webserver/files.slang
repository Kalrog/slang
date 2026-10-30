// Uploaded files: each user's own, the bytes in uploads/<id>, the record
// (name, type, size, SHA-256) in the files table of db.slang.
//
// An upload is a multipart form body read as a stream (main.slang asks
// slang/http to stream POST /files): each file part goes straight to a
// temporary file while its SHA-256 is computed, so a large file never sits
// in memory, and is renamed into place when its part ends.
//
//   await files.receive(req) -> {saved: list} or {error, status}
//   files.list(user)   files.find(user, id)   await files.remove(user, id)
//   files.path(file) -> where its bytes are
local a = require("slang/async")
local http = require("slang/http")
local crypto = require("slang/crypto")
local encoding = require("slang/encoding")
local os = require("slang/os")
local str = require("slang/string")
local db = require("db")
local m = {}

local dir = "examples/webserver/uploads"
os.mkdir_all(dir)

// the limit for one request's files together
m.max_upload = 50 * 1024 * 1024

func m.path(file){
  return concat(dir, "/", string(file.id))
}

func m.list(user){
  return db:all(
    sql{ select id, name, type, size, sha256, at from files where user_id = {user} order by id desc }
  )
}

func m.find(user, id){
  return db:one(
    sql{ select id, name, type, size, sha256, at from files where id = {id} and user_id = {user} }
  )
}

async func m.remove(user, id){
  local f = m.find(user, id)
  if(f == null){
    return false
  }
  db:run(sql{ delete from files where id = {f.id} })
  pcall(a.await, a.fs.remove(m.path(f)))
  return true
}

// a file part being written: {name, type, tmp, fd, hasher, size}
async func begin(part){
  local tmp = concat(dir, "/tmp-", crypto.token(12))
  local fd = await a.fs.open(tmp, "w")
  return {
    name: part.filename, type: part.content_type, tmp: tmp, fd: fd,
    hasher: crypto.hasher("sha256"), size: 0,
  }
}

async func finish(user, f){
  await a.fs.close(f.fd)
  local digest = encoding.hex_encode(f.hasher:digest())
  local id = db:run(sql{
    insert into files(user_id, name, type, size, sha256) values ({user}, {f.name}, {f.type}, {f.size}, {digest})
  }).last_id
  await a.fs.rename(f.tmp, m.path({id: id}))
  return m.find(user, id)
}

async func abandon(f){
  pcall(a.await, a.fs.close(f.fd))
  pcall(a.await, a.fs.remove(f.tmp))
}

async func m.receive(req){
  local boundary = http.multipart_boundary(req.headers["content-type"])
  if(boundary == null){
    return {status: 400, error: "Send the files as a multipart form."}
  }
  local parser = http.multipart_parser(boundary)
  local saved = {}
  local current = null
  local total = 0
  local r = pcall(func(){
    await for(let local chunk in req.stream){
      for(let local e in values(parser:push(chunk))){
        if(e.type == "part"){
          // a form field or an empty file input is no file
          if(e.filename != null and e.filename != ""){
            current = await begin(e)
          }
        } else if(e.type == "data" and current != null){
          total = total + len(e.data)
          if(total > m.max_upload){
            error("too large")
          }
          current.size = current.size + len(e.data)
          current.hasher:update(e.data)
          await a.fs.write(current.fd, e.data, null)
        } else if(e.type == "end_part" and current != null){
          append(saved, await finish(req.user.id, current))
          current = null
        }
      }
    }
    parser:finish()
  })
  if(r[0] == "err"){
    if(current != null){
      await abandon(current)
    }
    local msg = r[1].message or string(r[1])
    if(str.ends_with(msg, "too large")){
      return {
        status: 413,
        error: concat(
          "An upload can be at most ",
          string(to_int(m.max_upload / 1024 / 1024)),
          " MiB."
        ),
      }
    }
    return {status: 400, error: concat("The upload failed: ", msg)}
  }
  return {saved: saved}
}

return m
