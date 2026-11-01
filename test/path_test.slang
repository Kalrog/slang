// slang/path
local t = require("slang/test")
local path = require("slang/path")

t.group("path"){
  t.test("clean and join"){
    assert(path.clean("a//b/./../c/") == "a/c" and path.clean("") == ".")
    assert(path.clean("/../a") == "/a" and path.clean("../../a") == "../../a")
    assert(path.clean("a/..") == "." and path.clean("/") == "/")
    assert(path.join("a", "b/../c", "d.txt") == "a/c/d.txt")
    assert(path.join("a", "", "/b", "c/") == "a/b/c" and path.join("", "") == "")
  }
  t.test("pieces"){
    assert(path.split("a/b/c.txt") == {"a/b/", "c.txt"} and path.split("c") == {"", "c"})
    assert(path.base("a/b/") == "b" and path.base("") == "." and path.base("//") == "/")
    assert(path.dir("/a/b") == "/a" and path.dir("a") == "." and path.dir("/a") == "/")
    assert(path.ext("a/b.tar.gz") == ".gz" and path.ext("a.b/c") == "")
    assert(path.is_abs("/x") and not path.is_abs("x"))
    assert(path.is_abs(path.abs("x")))
  }
  t.test("rel"){
    assert(path.rel("a/b", "a/c/d") == "../c/d")
    assert(path.rel("/a", "/a/b") == "b" and path.rel("/a/b", "/a/b") == ".")
    assert(path.rel("/", "/x") == "x" and path.rel(".", "a") == "a")
    assert(pcall(path.rel, "/a", "b")[0] == "err")
  }
}
