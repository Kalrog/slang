// bench/machine/run.slang: how fast this machine runs slang, and how fast
// it is without slang, in one report: for comparing two machines (an ARM
// Mac and an x86 PC, say) with bench/machine/compare.slang, to tell "this
// CPU is slower" from "slang does worse on it".
//
//   slang run bench/machine/run.slang [--label name] [--out dir] [--quick]
//
// Writes <out>/<label>.json (default: bench/machine/results/, the label
// from the platform and the CPU) and prints a table. The groups:
//
//   native   C loops (native.c, built by build.sh with zig cc -O2): float
//            and integer arithmetic, a switch and a threaded bytecode loop,
//            memory latency; and slang's own native code (Zig): SHA-256,
//            ChaCha20-Poly1305, X25519
//   interp   bench/compare's programs in slang and in Lua 5.4 (built by
//            build.sh, the same source on every machine): the slang/Lua
//            ratio says how slang's VM does against another interpreter on
//            the same CPU
//   micro    bench/micro.slang: ns per operation of slang's VM
//
// Every measurement is the best of several runs (each program's first run
// also warms slang's module cache). --quick runs each once (to try it out).
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local time = require("slang/time")
local crypto = require("slang/crypto_core")
local math = require("slang/math")

// ------------------------------------------------------------ where things are

local func dir_of(path){
  local i = str.last_index_of(path, "/")
  if(i <= 0){
    return "."
  }
  return str.substring(path, 0, i)
}

local exe = os.executable()
local root = dir_of(dir_of(exe))
local here = concat(root, "/bench/machine")
local on_windows = str.starts_with(os.platform(), "windows")
local exe_suffix = if(on_windows){ ".exe" } else { "" }

local options = {label: null, out: concat(here, "/results"), quick: false}
local argv = args()
for(local i = 0; i < len(argv); i = i + 1){
  local a = argv[i]
  if(a == "--label" and i + 1 < len(argv)){
    i = i + 1
    options.label = argv[i]
  } else if(a == "--out" and i + 1 < len(argv)){
    i = i + 1
    options.out = argv[i]
  } else if(a == "--quick"){
    options.quick = true
  }
}
local RUNS = if(options.quick){ 1 } else { 5 }

local func native_path(path){
  if(on_windows){
    return str.replace(path, "/", "\\")
  }
  return path
}

// runs a program: {status, out}
local func run(argv, dir){
  local cmd = {native_path(argv[0])}
  for(local i = 1; i < len(argv); i = i + 1){
    append(cmd, argv[i])
  }
  local r = try { os.exec(cmd, native_path(dir or root)) } catch(local e) { {status: -1, stdout: "", stderr: string(e)} }
  return {status: r.status, out: concat(r.stdout or "", r.stderr or "")}
}

// ------------------------------------------------------------ the machine

local func cpu_name(){
  local p = os.platform()
  if(str.starts_with(p, "macos")){
    return str.trim(run({"/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"}).out)
  }
  if(str.starts_with(p, "linux")){
    local info = try { os.read_file("/proc/cpuinfo") } catch { "" }
    for(let local line in values(str.lines(info))){
      if(str.starts_with(line, "model name")){
        return str.trim(str.substring(line, str.index_of(line, ":") + 1))
      }
    }
  }
  if(on_windows){
    local out = run({"reg", "query", "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "/v", "ProcessorNameString"}).out
    local i = str.index_of(out, "REG_SZ")
    if(i >= 0){
      return str.trim(str.substring(out, i + 6))
    }
    return os.getenv("PROCESSOR_IDENTIFIER") or "?"
  }
  return "?"
}

local func slang_version(){
  local file = concat(root, "/VERSION")
  if(os.exists(file)){
    return str.trim(os.read_file(file))
  }
  local r = run({"git", "-C", root, "rev-parse", "--short", "HEAD"})
  if(r.status == 0){
    return str.trim(r.out)
  }
  return "?"
}

local func slug(s){
  local out = {}
  for(let local b in values(str.to_bytes(str.lower(s)))){
    if(b >= 'a' and b <= 'z' or b >= '0' and b <= '9'){
      append(out, str.from_bytes({b}))
    } else if(len(out) > 0 and out[len(out) - 1] != "-"){
      append(out, "-")
    }
  }
  local text = str.join(out, "")
  for(str.ends_with(text, "-")){
    text = str.substring(text, 0, len(text) - 1)
  }
  return text
}

local machine = {
  platform: os.platform(), cpu: cpu_name(), cpus: os.cpu_count(),
  slang: slang_version(), date: time.iso(time.now()),
}
local label = options.label or concat(machine.platform, "-", slug(machine.cpu))
print("bench/machine: ", label, "\n  ", machine.cpu, ", ", machine.cpus, " CPUs, slang ", machine.slang, "\n\n")

local results = {}
local func record(group, name, value, unit){
  append(results, {group: group, name: name, value: value, unit: unit})
  print(str.format("  %-8s %-44s %12.3f %s\n", group, name, value, unit))
}

// ------------------------------------------------------------ native

local bin = concat(here, "/bin/", machine.platform)
local native = concat(bin, "/native", exe_suffix)
if(os.exists(native)){
  local r = run({native})
  for(let local line in values(str.lines(r.out))){
    // "name: 1.234 ns per unit"
    local colon = str.index_of(line, ": ")
    local ns = str.index_of(line, " ns per ")
    if(colon > 0 and ns > colon){
      record("native", concat("C ", str.substring(line, 0, colon)),
        str.to_number(str.substring(line, colon + 2, ns)), concat("ns/", str.substring(line, ns + 8)))
    }
  }
} else {
  print("  (no ", native, ": run bench/machine/build.sh)\n")
}

// slang's own native code: best of RUNS, ns per byte or per operation
local func best_of(f){
  local best = math.inf
  for(local i = 0; i < RUNS; i = i + 1){
    local t0 = time.clock()
    f()
    local t = time.clock() - t0
    if(t < best){
      best = t
    }
  }
  return best
}
local mb = "x" * (1024 * 1024)
local big = mb * 32
record("native", "Zig sha256", best_of(func(){ crypto.hash("sha256", big) }) * 1e6 / len(big), "ns/byte")
local key = crypto.random_bytes(32)
local iv = crypto.random_bytes(12)
local some = mb * 8
record("native", "Zig chacha20-poly1305", best_of(func(){ crypto.encrypt("chacha20-poly1305", key, iv, some) }) * 1e6 / len(some), "ns/byte")
local secret = crypto.random_bytes(32)
local public = crypto.x25519(crypto.random_bytes(32))
record("native", "Zig x25519", best_of(func(){
  for(local i = 0; i < 200; i = i + 1){
    crypto.x25519(secret, public)
  }
}) * 1e6 / 200, "ns/op")

// ------------------------------------------------------------ interpreters

local lua = concat(bin, "/lua", exe_suffix)
local have_lua = os.exists(lua)
if(not have_lua){
  print("  (no ", lua, ": the slang column only)\n")
}
// the ms a compare program says it took ("name: result in X ms"), best of RUNS
local func program_ms(argv){
  local best = math.inf
  // (one more first: it warms slang's module cache)
  for(local i = 0; i < RUNS + 1; i = i + 1){
    local r = run(argv, concat(root, "/bench/compare"))
    local at = str.index_of(r.out, " in ")
    local ms_at = str.index_of(r.out, " ms")
    if(r.status != 0 or at < 0 or ms_at < at){
      print("  ! ", str.join(argv, " "), ": ", str.trim(r.out), "\n")
      return null
    }
    local ms = str.to_number(str.trim(str.substring(r.out, at + 4, ms_at)))
    if(i > 0 and ms < best){
      best = ms
    }
  }
  return best
}
for(let local b in values({"fib", "sieve", "nbody", "objects", "strings", "hashmap", "dijkstra"})){
  local s = program_ms({exe, "run", concat("slang/", b, ".slang")})
  if(s != null){
    record("interp", concat(b, " slang"), s, "ms")
  }
  if(have_lua){
    local l = program_ms({lua, concat("lua/", b, ".lua")})
    if(l != null){
      record("interp", concat(b, " lua"), l, "ms")
    }
  }
}

// ------------------------------------------------------------ micro

local m = run({exe, "run", "bench/micro.slang"})
if(m.status != 0){
  print("  ! bench/micro.slang: ", m.out, "\n")
}
for(let local line in values(str.lines(m.out))){
  // "name: 1.23 ns" (the name may hold ": ")
  if(str.ends_with(line, " ns")){
    local colon = str.last_index_of(line, ": ")
    if(colon > 0){
      record("micro", str.substring(line, 0, colon), str.to_number(str.substring(line, colon + 2, len(line) - 3)), "ns")
    }
  }
}

// ------------------------------------------------------------ the report

os.mkdir_all(options.out)
local file = concat(options.out, "/", label, ".json")
os.write_file(file, concat(json.encode({label: label, machine: machine, results: results}, {indent: "  "}), "\n"))
print("\nwritten: ", file, "\n")
