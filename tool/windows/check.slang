// tool/windows/check.slang: every check of slang (and of the game, when
// it is next to slang) in one run, written to one report, so that a
// tester with a Windows machine runs one command and sends one file back.
//
//   slang run tool/windows/check.slang [--headless] [--skip text]...
//                                      [--report file]
//
// Each test suite runs in a process of its own (a crash or a failure
// cannot stop the others) and the report is written again after each, so
// it holds everything up to a check that hangs. It is made for Windows
// (the test kit, tool/windows/kit.sh) and runs anywhere.
//
// [--headless]: no GPU, window or sound (CI): those suites are skipped
// [--skip]: leaves out the suites whose path contains the text
// [--report]: where the report goes (default: windows_report.txt next to
//   slang's folder, in the kit its root)
local os = require("slang/os")
local str = require("slang/string")
local time = require("slang/time")
local compiler = require("slang/compiler")
local tbl = require("slang/table")

// ------------------------------------------------------------ where things are

local func dir_of(path){
  local i = str.last_index_of(path, "/")
  if(i <= 0){
    return "."
  }
  return str.substring(path, 0, i)
}

local exe = os.executable()
// <root>/bin/slang(.exe)
local root = dir_of(dir_of(exe))
local kit = dir_of(root)
local game = concat(kit, "/model_coder")
local here = concat(root, "/tool/windows")

local options = {headless: false, skip: {}, report: concat(kit, "/windows_report.txt")}
local argv = args()
for(local i = 0; i < len(argv); i = i + 1){
  local a = argv[i]
  if(a == "--headless"){
    options.headless = true
  } else if(a == "--skip" and i + 1 < len(argv)){
    i = i + 1
    append(options.skip, argv[i])
  } else if(a == "--report" and i + 1 < len(argv)){
    i = i + 1
    options.report = argv[i]
  }
}

// suites that drive a Unix shell throughout (sh -c with rm, codesign,
// pipes) or pkg, which Windows has not yet (plans/PLAN_WINDOWS.md): left
// out on Windows, with the reason in the report
local posix_only = {
  ["test/build_test.slang"]: "drives sh",
  ["test/session_test.slang"]: "drives sh",
  ["test/pkg_test.slang"]: "pkg needs git, tar and sh",
}
local on_windows = str.starts_with(os.platform(), "windows")

// suites that need a GPU, a window or an audio device
local needs_device = {"packages/gpu", "packages/window", "packages/microphone", "game: frame"}

// ------------------------------------------------------------ the report

local lines = {}
local started = time.clock()

local func write_report(){
  try {
    os.write_file(options.report, concat(str.join(lines, "\n"), "\n"))
  } catch(local e) {
    os.write_stderr(concat("check: cannot write ", options.report, ": ", string(e), "\n"))
  }
}

local func say(...parts){
  local line = str.join(parts, "")
  append(lines, line)
  print(line, "\n")
  write_report()
}

local func tail_of(text, n){
  local all = str.lines(text)
  local from = len(all) - n
  if(from < 0){
    from = 0
  }
  local out = {}
  for(local i = from; i < len(all); i = i + 1){
    append(out, concat("      ", all[i]))
  }
  return str.join(out, "\n")
}

// ------------------------------------------------------------ running

local counts = {pass: 0, fail: 0, skip: 0, crash: 0}

local func skipped(name){
  for(let local s in values(options.skip)){
    if(str.contains(name, s)){
      return true
    }
  }
  if(options.headless){
    for(let local d in values(needs_device)){
      if(str.contains(name, d)){
        return true
      }
    }
  }
  return false
}

// a path as Windows itself writes it (for the programs started: slang's
// own paths use slashes, which Windows takes, but a backslash is the safe
// spelling when starting a process)
local func native(path){
  if(on_windows){
    return str.replace(path, "/", "\\")
  }
  return path
}

// runs a command in dir; {status, out, ms}
local func run(command, dir){
  local t0 = time.clock()
  local argv = {native(command[0])}
  for(local i = 1; i < len(command); i = i + 1){
    append(argv, command[i])
  }
  local r = try { os.exec(argv, native(dir)) } catch(local e) { {status: -1, stdout: "", stderr: string(e)} }
  return {status: r.status, out: concat(r.stdout or "", r.stderr or ""), ms: to_int(time.clock() - t0)}
}

// a test suite: `slang test file` in dir, its summary and its failures
local func suite(name, dir, file){
  if(on_windows and posix_only[name] != null){
    counts.skip = counts.skip + 1
    say("SKIP  ", name, " (", posix_only[name], ")")
    return null
  }
  if(skipped(name)){
    counts.skip = counts.skip + 1
    say("SKIP  ", name)
    return null
  }
  print("...   ", name, "\n")
  local r = run({exe, "test", file}, dir)
  local total = null
  local failed = null
  local details = {}
  local all = str.lines(r.out)
  for(local i = 0; i < len(all); i = i + 1){
    local line = all[i]
    if(str.starts_with(line, "Total tests: ")){
      total = str.trim(str.substring(line, 13))
    } else if(str.starts_with(line, "Tests failed: ")){
      failed = str.trim(str.substring(line, 14))
    } else if(str.ends_with(line, " Failed") or str.starts_with(str.trim(line), "Error")){
      if(len(details) < 40){
        append(details, concat("      ", str.trim(line)))
      }
    }
  }
  local timing = concat(" (", string(r.ms), " ms)")
  if(total == null){
    counts.crash = counts.crash + 1
    say("CRASH ", name, timing, ", exit status ", string(r.status), "\n", tail_of(r.out, 30))
  } else if(failed != null and failed != "0"){
    counts.fail = counts.fail + 1
    say("FAIL  ", name, ": ", failed, " of ", total, timing, "\n", str.join(details, "\n"))
  } else {
    counts.pass = counts.pass + 1
    say("PASS  ", name, ": ", total, timing)
  }
}

// a program: `slang run file args...` in dir; ok when it exits with 0
local func program(name, dir, command){
  if(skipped(name)){
    counts.skip = counts.skip + 1
    say("SKIP  ", name)
    return null
  }
  print("...   ", name, "\n")
  local r = run(command, dir)
  local timing = concat(" (", string(r.ms), " ms)")
  if(r.status == 0){
    counts.pass = counts.pass + 1
    say("PASS  ", name, timing, "\n", tail_of(r.out, 6))
  } else {
    counts.crash = counts.crash + 1
    say("FAIL  ", name, timing, ", exit status ", string(r.status), "\n", tail_of(r.out, 30))
  }
}

// the *_test.slang files of a directory, sorted
local func test_files(dir){
  local out = {}
  local names = try { os.list_dir(dir) } catch { {} }
  for(let local n in values(names)){
    if(str.ends_with(n, "_test.slang")){
      append(out, n)
    }
  }
  tbl.sort(out)
  return out
}

// ------------------------------------------------------------ the checks

say("slang Windows check")
say("  platform    ", os.platform(), ", ", string(os.cpu_count()), " CPUs")
say("  executable  ", exe)
say("  slang       ", root)
say("  cwd         ", os.cwd())
say("  home        ", compiler.home())
say("  cache       ", string(compiler.cache_root()))
for(let local v in values({"OS", "PROCESSOR_IDENTIFIER", "LOCALAPPDATA"})){
  local value = os.getenv(v)
  if(value != null){
    say("  ", v, " = ", value)
  }
}
if(options.headless){
  say("  (headless: no GPU, window or sound)")
}
say("")

say("== the graphics card")
program("packages/gpu: adapter", here, {exe, "run", concat(here, "/gpu_info.slang")})
say("")

say("== slang's tests (test/)")
for(let local f in values(test_files(concat(root, "/test")))){
  suite(concat("test/", f), root, concat("test/", f))
}
say("")

say("== the VM's and the extensions' tests (zig/test/)")
for(let local f in values(test_files(concat(root, "/zig/test")))){
  suite(concat("zig/test/", f), root, concat("zig/test/", f))
}
say("")

say("== packages")
for(let local p in values({"jolt", "kernel", "gpu", "window", "microphone"})){
  local dir = concat(root, "/packages/", p)
  if(os.is_dir(concat(dir, "/test"))){
    for(let local f in values(test_files(concat(dir, "/test")))){
      suite(concat("packages/", p, "/test/", f), dir, concat("test/", f))
    }
  }
}
say("")

if(os.is_dir(game)){
  say("== the game (model_coder)")
  // every engine and game module with tests, as tools/check.sh runs them
  local modules = {}
  local func walk(dir, rel){
    for(let local n in values(try { os.list_dir(dir) } catch { {} })){
      local full = concat(dir, "/", n)
      local r = concat(rel, "/", n)
      if(os.is_dir(full)){
        if(r != "game/prototypes"){
          walk(full, r)
        }
      } else if(str.ends_with(n, ".slang") and not str.ends_with(n, ".def.slang") and
        n != "burrower.slang" and str.contains(os.read_file(full), "group(\"")){
        append(modules, r)
      }
    }
  }
  walk(concat(game, "/engine"), "engine")
  walk(concat(game, "/game"), "game")
  tbl.sort(modules)
  for(let local m in values(modules)){
    suite(concat("game: ", m), game, m)
  }
  // one frame of the game, drawn without a window after 300 ticks
  program("game: frame (burrower --shot)", game, {
    exe, "run", "game/burrower.slang", "--shot", concat(kit, "/burrower_shot.png"),
    "--ticks", "300", "--port", "7811", "--voice", "off",
  })
  say("")
}

local seconds = to_int((time.clock() - started) / 1000)
say("== done in ", string(seconds), " s: ", string(counts.pass), " passed, ",
  string(counts.fail), " failed, ", string(counts.crash), " crashed, ",
  string(counts.skip), " skipped")
say("report: ", options.report)
// (CI: a run with a failure fails)
if(counts.fail + counts.crash > 0){
  os.exit(1)
}
