// slang/os: files and the process
local t = require("slang/test")
local os = require("slang/os")
local time = require("slang/time")

local dir = concat(os.temp_dir(), "/slang-os-test-", string(to_int(time.now())))

t.group("os"){
  t.setup(func(){
    os.remove_all(dir)
    os.mkdir_all(dir)
  })
  t.teardown(func(){
    os.remove_all(dir)
  })
  t.test("files"){
    local p = concat(dir, "/a.txt")
    os.write_file(p, "one\r\ntwo\n")
    os.append_file(p, "three")
    assert(os.read_file(p) == "one\r\ntwo\nthree")
    local st = os.stat(p)
    assert(st.size == 14 and not st.is_dir and st.mtime > 0)
    assert(os.stat(dir).is_dir and os.stat(concat(dir, "/nope")) == null)
    os.rename(p, concat(dir, "/b.txt"))
    assert(not os.exists(p) and os.exists(concat(dir, "/b.txt")))
    os.remove(concat(dir, "/b.txt"))
    assert(not os.exists(concat(dir, "/b.txt")))
    assert(pcall(os.remove, concat(dir, "/b.txt"))[0] == "err")
  }
  t.test("open"){
    local p = concat(dir, "/lines.txt")
    local w = os.open(p, "w")
    w:write("one\r\ntwo\n")
    w:write_bytes({116, 104, 114, 101, 101})
    w:flush()
    w:close()
    local f = os.open(p)
    assert(f:read_line() == "one" and f:read_line() == "two")
    assert(f:read_line() == "three" and f:read_line() == null)
    f:close()
    local lines = {}
    for(let local line in os.open(p):lines()){
      append(lines, line)
    }
    assert(lines == {"one", "two", "three"})
    assert(os.open(p):read_bytes(3) == {111, 110, 101})
    assert(pcall(os.open, concat(dir, "/missing.txt"))[0] == "err", "reading needs the file")
  }
  t.test("remove_all"){
    os.mkdir_all(concat(dir, "/x/y"))
    os.write_file(concat(dir, "/x/y/z"), "")
    os.remove_all(concat(dir, "/x"))
    assert(not os.exists(concat(dir, "/x")))
    os.remove_all(concat(dir, "/x"))
  }
}
