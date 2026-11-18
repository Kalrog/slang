// sessions (the REPL's lines, a notebook's cells): chunks that share their
// locals and give the value they end in; entering a project; interrupts
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local compiler = require("slang/compiler")
local time = require("slang/time")

t.group("sessions"){
  t.test("a chunk's value is the expression or call it ends with"){
    local s = compiler.session()
    assert(s:compile("1 + 2")() == 3)
    assert(s:compile("local a = 4\na * 2")() == 8)
    assert(s:compile("len(\"abc\")")() == 3)
    assert(s:compile("local b = 1")() == null)
    assert(s:compile("{1, 2}\n")()[1] == 2)
    assert(s:compile("// nothing\n")() == null)
    assert(s:compile("return 7")() == 7)
  }
  t.test("top-level locals stay for the chunks after, and are one variable"){
    local s = compiler.session()
    s:compile("local n = 0\nlocal func inc(){ n = n + 1 }")()
    s:compile("inc()\ninc()")()
    assert(s:compile("n")() == 2)
    s:compile("n = 10")()
    assert(s:compile("inc()\nn")() == 11)
    s:compile("let {local first, local second} = {7, 8}")()
    assert(s:compile("first + second")() == 15)
    s:compile("local later")()
    assert(s:compile("later")() == null)
    assert(str.join(s:names(), " ") == "first inc later n second")
  }
  t.test("a session's locals are not the program's globals, and globals stay global"){
    local s = compiler.session()
    s:compile("local len = 3")()
    assert(s:compile("len")() == 3)
    assert(len({1, 2}) == 2, "the built-in is untouched")
    s:compile("Session_test_global = 5")()
    assert(Session_test_global == 5)
    assert(get_raw(s.env, "Session_test_global") == null)
    Session_test_global = null
    // a local in a block ends with it
    s:compile("if(true){ local inner = 1 }")()
    assert(s:compile("inner")() == null)
    // two sessions do not share
    local other = compiler.session()
    assert(other:compile("len(\"ab\")")() == 2)
  }
  t.test("locations count the lines before the chunk"){
    local s = compiler.session()
    local e = t.raises(func(){
      s:compile("local t = null\nt.x = 1", "notes.md", 10)()
    })
    assert(e.location.origin == "notes.md" and e.location.line == 12, e.location.line)
    local syntax = t.raises(func(){ s:compile("local = ", "notes.md", 4) })
    assert(syntax.kind == "syntax" and syntax.location.line == 5)
    // a chunk that fails to parse as either reports the statement
    t.raises(func(){ s:compile("x +") })
  }
  t.test("parse_source with result: the trailing expression is the Return"){
    local g = compiler.grammar()
    local block = g:parse_source("local a = 1\na + 1", "r", {result: true})
    assert(block.statements[1].type == "Return")
    t.raises(func(){ g:parse_source("local a = 1\na + 1", "r") })
    // a return of its own stays the last word
    t.raises(func(){ g:parse_source("return 1\n2", "r", {result: true}) })
  }
}

// ------------------------------------------------------------ in a process

local slang = compiler.absolute_path("bin/slang")
local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-session-test-",
  string(to_int(time.now()))
)

local func sh(command, dir){
  local r = os.exec({"sh", "-c", command}, dir)
  assert(r.status == 0, concat(command, ": ", r.stderr, r.stdout))
  return r.stdout
}

local func write(path, text){
  os.write_file(concat(scratch, "/", path), text)
}

t.group("sessions: in a process"){
  t.test("the REPL keeps locals and shows values, not null"){
    os.mkdir_all(scratch)
    write("lines", "local x = 20\nlocal func twice(v){ return v * 2 }\ntwice(x) + 2\nx = 1\nexit\n")
    local out = sh(concat(slang, " repl < lines"), scratch)
    assert(str.index_of(out, ">>> 42\n") >= 0, out)
    assert(str.index_of(out, "null") < 0, out)
    sh(concat("rm -rf '", scratch, "'"))
  }
  t.test("enter_project: another project's packages, files and extensions"){
    os.mkdir_all(concat(scratch, "/tool"))
    os.mkdir_all(concat(scratch, "/proj/dep"))
    write("proj/dep/slang.project", "{name: \"dep\"}\n")
    write("proj/dep/init.slang", "return {answer: 42}\n")
    write("proj/helper.slang", "return {double: |x| x * 2}\n")
    write("proj/lambda.slang", os.read_file("extensions/lambda_shorthand.slang"))
    write(
      "proj/slang.project",
      "{name: \"proj\", extensions: {\"lambda\"}, dependencies: {dep: {path: \"dep\"}}}\n",
    )
    write("tool/slang.project", "{name: \"tool\"}\n")
    write("tool/own.slang", "return \"the tool's own\"\n")
    write("tool/main.slang", concat(
      "local compiler = require(\"slang/compiler\")\n",
      "local own = require(\"tool/own\")\n",
      "local p = compiler.enter_project(args()[0])\n",
      "local s = compiler.session()\n",
      "print(s:compile(\"local f = |x| x + 1\\nf(require(\\\"dep\\\").answer) + require(\\\"helper\\\").double(1)\")(), \"\\n\")\n",
      "print(p.package or p.path != null, \" \", require(\"tool/own\"), \"\\n\")\n",
      "print(compiler.enter_project(args()[1]) == null, \"\\n\")\n",
    ))
    sh(concat(slang, " get"), concat(scratch, "/proj"))
    local out = sh(
      concat(slang, " run tool/main.slang proj/notes.md ", os.getenv("TMPDIR") or "/tmp"),
      scratch,
    )
    assert(out == "45\ntrue the tool's own\ntrue\n", out)
    sh(concat("rm -rf '", scratch, "'"))
  }
  t.test("the extensions of the library are in the binary"){
    os.mkdir_all(scratch)
    write("page.slang", concat(
      "extension \"extensions/html\"\n",
      "print(string(<p class=\"x\">a {\"<b>\"}</p>), \"\\n\")\n",
    ))
    assert(sh(concat(slang, " run page.slang"), scratch) ==
      "<p class=\"x\">a &lt;b&gt;</p>\n")
    sh(concat("rm -rf '", scratch, "'"))
  }
  t.test("catch_interrupt: ctrl-c is an error the code can catch"){
    if(str.starts_with(os.platform(), "windows")){
      return
    }
    os.mkdir_all(scratch)
    write("spin.slang", concat(
      "local vm = require(\"slang/vm\")\n",
      "vm.catch_interrupt(true)\n",
      "print(\"spinning\\n\")\n",
      "local n = 0\n",
      "try {\n  for(true){ n = n + 1 }\n} catch(local e) {\n",
      "  print(e.kind, \" \", e.kind == error.kinds.interrupted, \"\\n\")\n}\n",
      "vm.catch_interrupt(null)\n",
      "print(vm.interrupted(), \"\\n\")\n",
    ))
    local out = sh(concat(
      slang, " run spin.slang > out & pid=$!; ",
      "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do ",
      "grep -q spinning out 2>/dev/null && break; sleep 0.1; done; ",
      "kill -INT $pid; wait $pid; cat out"
    ), scratch)
    assert(out == "spinning\ninterrupted true\nfalse\n", out)
    sh(concat("rm -rf '", scratch, "'"))
  }
}
