// slang/path
local t = require("slang/test")
local path = require("slang/path")
local str = require("slang/string")
local windows = str.starts_with(require("slang/os").platform(), "windows")

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
  t.test("a drive is a root on Windows"){
    if(not windows){
      t.skip("Windows only")
    }
    assert(path.is_abs("C:/x") and path.is_abs("/x") and not path.is_abs("C:x"))
    assert(path.clean("C:/a/../../b/") == "C:/b" and path.clean("C:/") == "C:/")
    assert(path.dir("C:/a") == "C:/" and path.abs("D:/a/./b") == "D:/a/b")
    assert(path.rel("C:/a", "C:/a/b/c") == "b/c" and path.rel("C:/", "C:/x") == "x")
    t.raises(func(){ path.rel("C:/a", "D:/a") })
  }
  t.test("rel"){
    assert(path.rel("a/b", "a/c/d") == "../c/d")
    assert(path.rel("/a", "/a/b") == "b" and path.rel("/a/b", "/a/b") == ".")
    assert(path.rel("/", "/x") == "x" and path.rel(".", "a") == "a")
    t.raises(func(){ path.rel("/a", "b") })
  }
}
