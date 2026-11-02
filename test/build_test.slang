// slang build: programs built into executables, run away from their sources
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local ast = require("slang/ast")
local compiler = require("slang/compiler")
local tool = require("slang/bundle_tool")
local time = require("slang/time")

t.group("build: requires"){
  t.test("literal requires are found, computed ones located, quotes skipped"){
    local r = ast.requires(compiler.parse(
      "local a = require(\"a/b\")\nfunc f(n){ return require(n) }\nlocal q = +{require(\"quoted\")}",
      "t",
    ))
    assert(len(r.names) == 1 and r.names[0].name == "a/b")
    assert(len(r.computed) == 1)
  }
}

// ------------------------------------------------------------ building

local slang = os.executable()
local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-build-test-", string(to_int(time.now()))
)

local func sh(command, dir){
  local r = os.exec({"sh", "-c", command}, dir)
  assert(r.status == 0, concat(command, ": ", r.stderr, r.stdout))
  return r
}

local func write(path, text){
  local full = concat(scratch, "/", path)
  local i = len(full) - 1
  for(str.char_at(full, i) != "/"){
    i = i - 1
  }
  os.mkdir_all(str.substring(full, 0, i))
  os.write_file(full, text)
}

local css = ""
for(local i = 0; i < 100; i = i + 1){
  css = concat(css, "p { margin: ", string(i), "px }\n")
}

write(
  "app/slang.project",
  "{name: \"hello\", build: {assets: {\"static\", \"words.txt\"}, compress: true}}",
)
write(
  "app/util/greet.slang",
  "return func(n){ return concat(\"hello \", string(n)) }",
)
write("app/words.txt", "alpha beta\n")
write("app/static/app.css", css)
write("app/static/tiny.txt", "x")
write("app/main.slang", str.join({
  "local os = require(\"slang/os\")",
  "local str = require(\"slang/string\")",
  "local bundle = require(\"slang/bundle\")",
  "local greet = require(\"util/greet\")",
  "print(greet(len(args())), \"\\n\")",
  "print(os.read_file(\"words.txt\"))",
  "print(len(os.read_file(\"static/app.css\")), \" \", os.is_dir(\"static\"), \" \", str.join(os.list_dir(\"static\"), \",\"), \"\\n\")",
  "print(bundle.active(), \" \", bundle.stat(\"static/app.css\").encoding, \" \", os.exists(\"nothing\"), \"\\n\")",
  "if(false){ require(concat(\"no\", \"where\")) }",
  "",
}, "\n"))

t.group("build: executables"){
  t.test(
    "one file: modules, assets (gzipped where it pays), run from elsewhere",
  ){
    local r = sh(
      concat(slang, " build -o ", scratch, "/hello"),
      concat(scratch, "/app"),
    )
    assert(
      str.index_of(r.stderr, "main.slang:9: require of a computed name") >= 0,
      r.stderr,
    )
    os.mkdir_all(concat(scratch, "/elsewhere"))
    local out = sh(
      concat(scratch, "/hello a b"),
      concat(scratch, "/elsewhere"),
    ).stdout
    assert(out == concat(
        "hello 2\nalpha beta\n",
        string(len(css)),
        " true app.css,tiny.txt\n",
        "true gzip false\n",
      ), out)
    local stored = {}
    for(let local e in values(tool.inspect(concat(scratch, "/hello")))){
      stored[e.name] = e
    }
    assert(stored["<main>"].kind == "module" and stored["util/greet"] != null)
    assert(stored["static/app.css"].encoding == "gzip")
    assert(stored["static/tiny.txt"].encoding == null)
    assert(tool.inspect(slang) == null)
    if(str.starts_with(os.platform(), "macos")){
      sh(concat("codesign --verify --strict ", scratch, "/hello"))
    }
  }

  t.test("--dir: the executable, its assets next to it"){
    sh(
      concat(slang, " build --dir -o ", scratch, "/dist"),
      concat(scratch, "/app"),
    )
    assert(os.exists(concat(scratch, "/dist/static/app.css")))
    assert(not os.exists(concat(scratch, "/dist/lib")))
    local out = sh(
      concat(scratch, "/dist/hello"),
      concat(scratch, "/elsewhere"),
    ).stdout
    assert(str.starts_with(out, "hello 0\nalpha beta\n"), out)
    assert(str.index_of(out, "true null false") >= 0, out)
  }

  t.test("assets outside the project are refused"){
    write("outside/slang.project", "{build: {assets: {\"../app/words.txt\"}}}")
    write("outside/main.slang", "print(1)\n")
    local r = os.exec(
      {"sh", "-c", concat(slang, " build --list")},
      concat(scratch, "/outside"),
    )
    assert(r.status == 1, r.stdout)
    assert(str.index_of(r.stderr, "outside the project") >= 0, r.stderr)
  }

  t.test("native extensions are linked in (when this slang has lib/static)"){
    local bin = str.substring(slang, 0, len(slang) - len("/slang"))
    if(not os.exists(concat(bin, "/../lib/static/manifest.slang"))){
      return
    }
    write("native/main.slang", str.join({
      "local zlib = require(\"zlib\")",
      "print(len(zlib.inflate(zlib.deflate(\"abcabcabc\", \"gzip\"), \"gzip\")), \"\\n\")",
      "",
    }, "\n"))
    sh(
      concat(slang, " build -o ", scratch, "/native/z main.slang"),
      concat(scratch, "/native"),
    )
    // no lib/ anywhere near it: the extension is in the executable
    local out = sh(
      concat("SLANG_NATIVE_PATH=/nonexistent ", scratch, "/native/z"),
      concat(scratch, "/elsewhere"),
    ).stdout
    assert(out == "9\n", out)
  }

  t.test("(clean up)"){
    sh(concat("rm -rf '", scratch, "'"))
  }
}
