// packages: versions, and slang get / update / run against git repositories
// made on the spot (git must be installed)
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local pkg = require("slang/pkg")
local compiler = require("slang/compiler")
local time = require("slang/time")

t.group("packages: versions"){
  t.test("tags and asks parse; majors decide what stands in"){
    local v = pkg.parse_version("v1.2.3")
    assert(v.major == 1 and v.minor == 2 and v.patch == 3 and v.text == "1.2.3")
    assert(pkg.parse_version("^1.2").text == "1.2.0")
    assert(pkg.parse_version("v1.2.3-beta") == null)
    assert(pkg.parse_version("x") == null)
    local a = pkg.parse_version("1.2.0")
    assert(pkg.compare(a, pkg.parse_version("1.10.0")) < 0)
    assert(pkg.compatible(a, pkg.parse_version("1.9.9")))
    assert(not pkg.compatible(a, pkg.parse_version("2.0.0")))
    // below 1.0 the minor is the major
    assert(not pkg.compatible(
      pkg.parse_version("0.1"),
      pkg.parse_version("0.2"),
    ))
  }
}

// ------------------------------------------------------------ with git

local slang = compiler.absolute_path("bin/slang")
local scratch = concat(
  os.temp_dir(), "/slang-pkg-test-", string(to_int(time.now()))
)

local func sh(command, dir){
  local r = os.exec({"sh", "-c", command}, dir)
  assert(r.status == 0, concat(command, ": ", r.stderr, r.stdout))
  return r.stdout
}

local func write(path, text){
  os.write_file(concat(scratch, "/", path), text)
}

// a repository at repos/name with one commit and tag per version: versions
// is a list of {tag, files}
local func repo(name, versions){
  local dir = concat(scratch, "/repos/", name)
  os.mkdir_all(dir)
  sh("git init -q && git config user.email t@t && git config user.name t", dir)
  for(let local v in values(versions)){
    for(let local f in entries(v.files)){
      write(concat("repos/", name, "/", f[0]), f[1])
    }
    sh(
      concat("git add -A && git commit -qm ", v.tag, " && git tag ", v.tag),
      dir,
    )
  }
  return dir
}

local func slang_in(dir, command){
  return sh(
    concat("SLANG_PKG_DIR=", scratch, "/cache ", slang, " ", command),
    dir,
  )
}

t.group("packages: get, update, run"){
  t.test(
    "minimal versions, the lock, update, and extensions that stay in their package",
  ){
    os.mkdir_all(concat(scratch, "/app"))
    local util = repo("util", {
      {
        tag: "v1.0.0",
        files: {
          ["slang.project"]: "{name: \"util\"}\n",
          ["init.slang"]: "return {version: \"1.0\"}\n",
        },
      },
      {tag: "v1.1.0", files: {["init.slang"]: "return {version: \"1.1\"}\n"}},
    })
    local lambda = os.read_file("extensions/lambda_shorthand.slang")
    local func fns_project(min){
      return concat(
        "{name: \"fns\", extensions: {\"fns/lambda\"},\n",
        " dependencies: {util: {git: \"", util, "\", version: \"", min,
        "\"}}}\n"
      )
    }
    local fns = repo("fns", {
      {
        tag: "v1.0.0",
        files: {
          ["slang.project"]: fns_project("^1.0"),
          ["lambda.slang"]: lambda,
          ["init.slang"]: "local util = require(\"util\")\nreturn {double: |x| x * 2, util: util.version}\n",
        },
      },
      {tag: "v1.1.0", files: {["slang.project"]: fns_project("^1.1")}},
    })
    write("app/slang.project", concat(
      "{name: \"app\", dependencies: {\n  fns: {git: \"",
      fns,
      "\", version: \"^1.0\"},\n  util: {git: \"",
      util,
      "\", version: \"^1.0\"},\n}}\n",
    ))
    write(
      "app/main.slang",
      "local fns = require(\"fns\")\nprint(fns.double(21), \" \", fns.util, \"\\n\")\n",
    )
    local app = concat(scratch, "/app")
    // the lowest versions that satisfy everyone
    local out = slang_in(app, "get")
    assert(
      str.index_of(out, "fns 1.0.0") >= 0 and
        str.index_of(out, "util 1.0.0") >= 0,
      out,
    )
    assert(slang_in(app, "run main.slang") == "42 1.0\n")
    local lock = compiler.read_table_file(concat(app, "/slang.lock"))
    assert(lock.fns.version == "1.0.0" and str.starts_with(
        lock.fns.hash, "sha256:"
      ))
    // update: fns 1.1.0 asks for util 1.1 and gets it
    out = slang_in(app, "update")
    assert(
      str.index_of(out, "fns 1.1.0") >= 0 and
        str.index_of(out, "util 1.1.0") >= 0,
      out,
    )
    assert(slang_in(app, "run main.slang") == "42 1.1\n")
    // the package's lambda extension does not reach the project
    write("app/leak.slang", "local f = |x| x\n")
    local r = os.exec({"sh", "-c", concat(slang, " run leak.slang")}, app)
    assert(r.status != 0, "the extension leaked into the project")
    sh(concat("rm -rf '", scratch, "'"))
  }
}

t.group("packages: native modules"){
  t.test("a prebuilt library per platform, its stubs, and other platforms"){
    local platform = os.platform()
    os.mkdir_all(concat(scratch, "/nat/stubs"))
    os.mkdir_all(concat(scratch, "/napp"))
    // the package's author builds lib/<platform>/hello.<ext>
    write("nat/slang.project", "{name: \"nat\"}\n")
    write("nat/init.slang", "return require(\"nat/hello\")\n")
    write(
      "nat/stubs/hello.slang",
      "// hello: a greeting\nlocal m = {}\nreturn m\n",
    )
    write("nat/hello.c", concat(
      "#include \"slang.h\"\n",
      "static int greet(slang_State *S) { slang_pushstring(S, \"hi\"); return 1; }\n",
      "static const slang_Reg funcs[] = {{\"greet\", greet}, {0, 0}};\n",
      "SLANG_EXTENSION(nat_hello) { slang_newmodule(S, funcs); return 1; }\n",
    ))
    local nat = concat(scratch, "/nat")
    local ext = ".so"
    local flags = "-shared -fPIC"
    if(str.starts_with(platform, "macos")){
      ext = ".dylib"
      flags = "-dynamiclib -undefined dynamic_lookup"
    }
    os.mkdir_all(concat(nat, "/lib/", platform))
    sh(
      concat(
        "cc ", flags, " -I", compiler.absolute_path("zig/include"), " -o lib/",
        platform, "/hello", ext, " hello.c"
      ),
      nat,
    )
    write(
      "napp/slang.project",
      "{name: \"napp\", dependencies: {nat: {path: \"../nat\"}}}\n",
    )
    write("napp/main.slang", "print(require(\"nat\").greet(), \"\\n\")\n")
    local napp = concat(scratch, "/napp")
    slang_in(napp, "get")
    assert(slang_in(napp, "run main.slang") == "hi\n")
    // the stubs are the package's
    write("napp/stub.slang", concat(
      "local c = require(\"slang/compiler\")\n",
      "print(c.stub_path(\"nat/hello\") != null, \"\\n\")\n",
    ))
    assert(slang_in(napp, "run stub.slang") == "true\n")
    // built for another platform only: an error that names this one
    sh(concat("mv lib/", platform, " lib/other-platform"), nat)
    local r = os.exec({"sh", "-c", concat(slang, " run main.slang")}, napp)
    assert(r.status != 0)
    assert(str.index_of(r.stderr, concat("for ", platform)) >= 0, r.stderr)
    sh(concat("rm -rf '", scratch, "'"))
  }
}

t.group("packages: executables"){
  t.test("exec runs the project's, a dependency's and an installed package's"){
    local home = concat(scratch, "/home")
    os.mkdir_all(concat(scratch, "/hello/bin"))
    os.mkdir_all(concat(scratch, "/eapp/sub"))
    os.mkdir_all(concat(scratch, "/elsewhere"))
    write(
      "hello/slang.project",
      "{name: \"hello\", executables: {hello: \"bin/hello.slang\", [\"hello-twice\"]: \"bin/twice.slang\"}}\n",
    )
    write("hello/init.slang", "return {greet: func(who){ return concat(\"hello \", who) }}\n")
    write(
      "hello/bin/hello.slang",
      "print(require(\"hello\").greet(args()[0] or \"world\"), \" \", len(args()), \"\\n\")\n",
    )
    write(
      "hello/bin/twice.slang",
      "local h = require(\"hello\")\nprint(h.greet(\"a\"), \", \", h.greet(\"b\"), \"\\n\")\n",
    )
    write(
      "eapp/slang.project",
      "{name: \"eapp\", dependencies: {hello: {path: \"../hello\"}}, executables: {eapp: \"main.slang\"}}\n",
    )
    write("eapp/main.slang", "print(\"eapp \", args()[0], \"\\n\")\n")
    local func run(dir, command){
      return sh(
        concat("SLANG_HOME=", home, " ", slang, " ", command),
        concat(scratch, "/", dir),
      )
    }
    run("eapp", "get")
    // the project's own, from a folder below it; arguments are the program's
    assert(run("eapp/sub", "exec eapp one") == "eapp one\n")
    // a dependency's: by name, as a command of slang, and by its package
    assert(run("eapp", "exec hello you") == "hello you 1\n")
    assert(run("eapp", "hello-twice") == "hello a, hello b\n")
    assert(run("eapp", "exec hello:hello") == "hello world 0\n")
    local listed = run("eapp", "exec")
    assert(
      str.index_of(listed, "eapp") >= 0 and
        str.index_of(listed, "hello-twice") >= 0,
      listed,
    )
    // elsewhere there is none, until the package is installed
    local r = os.exec(
      {"sh", "-c", concat("SLANG_HOME=", home, " ", slang, " hello")},
      concat(scratch, "/elsewhere"),
    )
    assert(r.status == 2 and str.index_of(r.stderr, "is no command") >= 0, r.stderr)
    local out = run("elsewhere", "install ../hello")
    assert(str.index_of(out, "installed hello: hello, hello-twice") >= 0, out)
    assert(run("elsewhere", "hello there") == "hello there 1\n")
    assert(run("elsewhere", "exec hello-twice") == "hello a, hello b\n")
    // its launcher is a script that runs it
    assert(sh(concat(home, "/bin/hello launched"), scratch) == "hello launched 1\n")
    assert(os.exists(concat(home, "/tools/hello/slang.lock")))
    // installing again without one of them takes that launcher away
    write("hello/slang.project", "{name: \"hello\", executables: {hello: \"bin/hello.slang\"}}\n")
    run("elsewhere", "install ../hello")
    assert(not os.exists(concat(home, "/bin/hello-twice")))
    assert(os.exists(concat(home, "/bin/hello")))
    // and uninstalling takes all of it
    run("elsewhere", "uninstall hello")
    assert(not os.exists(concat(home, "/bin/hello")))
    assert(not os.exists(concat(home, "/tools/hello")))
    r = os.exec(
      {"sh", "-c", concat("SLANG_HOME=", home, " ", slang, " uninstall hello")},
      concat(scratch, "/elsewhere"),
    )
    assert(r.status == 1)
    sh(concat("rm -rf '", scratch, "'"))
  }
  t.test("a package without a name or without executables is not installed"){
    local home = concat(scratch, "/home")
    os.mkdir_all(concat(scratch, "/plain"))
    os.mkdir_all(concat(scratch, "/lib"))
    write("plain/slang.project", "{executables: {x: \"x.slang\"}}\n")
    write("lib/slang.project", "{name: \"lib\"}\n")
    for(let local dir in values({"plain", "lib"})){
      local r = os.exec(
        {"sh", "-c", concat("SLANG_HOME=", home, " ", slang, " install ", dir)},
        scratch,
      )
      assert(r.status == 1, dir)
      assert(str.index_of(r.stderr, "slang install: ") == 0, r.stderr)
    }
    sh(concat("rm -rf '", scratch, "'"))
  }
}
