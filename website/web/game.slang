// A program of several files as a page of its own, on the graphics VM
// (website/web/build.sh, `make wasm-gfx`): the page, the VM and the
// program's files, ready to be served from one directory.
//
//   bin/slang run website/web/game.slang <project> <out> [title]
//
// The project's slang.project names its packages; the ones the graphics VM
// carries (raylib, box2d, jolt, kernel, dsp) are found at /<name> there, and
// its slang.project and slang.lock are rewritten to say so. Every file
// under the project goes along except tests, tools, what a run wrote (out/)
// and pictures, sounds and notes the program does not read; binary files
// travel as base64. The page passes its URL's query to the program as
// environment variables (?SWITCHBACK_SEED=7), and keeps what the program
// writes under $HOME in the browser's storage (IndexedDB) between visits.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local encoding = require("slang/encoding")

local PACKAGES = {"raylib", "box2d", "jolt", "kernel", "dsp"}
// directories that are not the program
local SKIP_DIRS = {test: true, tool: true, out: true, web: true, [".git"]: true}
// files the program reads as text, and as bytes
local TEXT = {".slang", ".kernel", ".dsp", ".json", ".txt", ".glsl", ".vs", ".fs"}
local BINARY = {".ttf", ".otf", ".png", ".wav", ".ogg", ".mp3", ".bin"}

local argv = args()
if(len(argv) < 2){
  os.write_stderr("usage: slang run website/web/game.slang <project> <out> [title]\n")
  os.exit(2)
}
local project = argv[0]
local out = argv[1]
local title = argv[2] or project
local vm_dir = "website/public"
if(not os.exists(concat(vm_dir, "/slang-gfx.wasm"))){
  os.write_stderr("no website/public/slang-gfx.wasm: run make wasm-gfx first\n")
  os.exit(1)
}

local func ends_with_any(name, list){
  for(let local suffix in values(list)){
    if(str.ends_with(name, suffix)){
      return true
    }
  }
  return false
}

// the packages' paths, as the graphics VM has them
local func rewrite(text){
  for(let local name in values(PACKAGES)){
    // any path that ends in the package's directory name
    local at = 0
    for(true){
      local i = str.index_of(text, concat("/", name, "\""), at)
      if(i < 0){
        break
      }
      // back to the opening quote of the path
      local q = str.last_index_of(str.substring(text, 0, i), "\"")
      text = concat(str.substring(text, 0, q + 1), "/", name, str.substring(text, i + len(name) + 1))
      at = q + len(name) + 3
    }
  }
  return text
}

local files = {}
local count = 0
local bytes = 0
local func walk(dir, rel){
  for(let local name in values(os.list_dir(dir))){
    local path = concat(dir, "/", name)
    local r = if(rel == ""){ name } else { concat(rel, "/", name) }
    if(os.is_dir(path)){
      if(not SKIP_DIRS[name]){
        walk(path, r)
      }
      continue
    }
    if(name == "slang.project" or name == "slang.lock"){
      files[r] = rewrite(os.read_file(path))
    } else if(ends_with_any(name, TEXT)){
      files[r] = os.read_file(path)
    } else if(ends_with_any(name, BINARY) and rel != ""){
      // (pictures at the top are the README's)
      files[r] = {b64: encoding.base64.encode(os.read_file(path))}
    } else {
      continue
    }
    count = count + 1
    bytes = bytes + len(os.read_file(path))
  }
}
walk(project, "")
if(files["main.slang"] == null){
  os.write_stderr(concat(project, " has no main.slang\n"))
  os.exit(1)
}

local func escape(s){
  s = str.replace(s, "&", "&amp;")
  s = str.replace(s, "<", "&lt;")
  return str.replace(s, ">", "&gt;")
}

local page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TITLE</title>
<link rel="icon" href="data:,">
<style>
  :root { color-scheme: dark; --bg: #111416; --fg: #e8e4da; --dim: #8d918f; --accent: #d9a441; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg);
    font: 15px/1.4 system-ui, -apple-system, sans-serif; }
  body { display: flex; flex-direction: column; }
  header { display: flex; align-items: center; gap: 12px; padding: 8px 16px; flex-wrap: wrap; }
  h1 { font-size: 17px; margin: 0; font-weight: 600; }
  button { font: inherit; padding: 6px 16px; border-radius: 6px; border: 1px solid #444;
    background: var(--accent); color: #1b1407; font-weight: 600; cursor: pointer; }
  button.quiet { background: transparent; color: var(--fg); font-weight: 400; }
  #status { color: var(--dim); }
  #stage { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center; }
  canvas { display: block; max-width: 100%; max-height: 100%; aspect-ratio: 16 / 9;
    background: #000; outline: none; }
  #stage:fullscreen canvas { width: 100%; height: 100%; object-fit: contain; }
  #output { margin: 0; max-height: 9em; overflow: auto; padding: 0 16px 8px; color: var(--dim);
    font: 12px/1.35 ui-monospace, Menlo, monospace; white-space: pre-wrap; }
  #output .err { color: #e07a6a; }
</style>
</head>
<body>
<header>
  <h1>TITLE</h1>
  <button id="play">Play</button>
  <button id="full" class="quiet" hidden>Full screen</button>
  <span id="status">INFO</span>
</header>
<div id="stage"><canvas id="canvas" tabindex="0" oncontextmenu="event.preventDefault()"></canvas></div>
<pre id="output"></pre>
<script type="module">
const status = document.getElementById("status");
const output = document.getElementById("output");
const canvas = document.getElementById("canvas");
const play = document.getElementById("play");
const full = document.getElementById("full");
const say = (text) => { status.textContent = text; };
const show = (cls) => (text) => {
  const line = document.createElement("div");
  if (cls) line.className = cls;
  line.textContent = text;
  output.appendChild(line);
  output.scrollTop = output.scrollHeight;
  if (cls) console.error(text); else console.log(text);
};
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// keys reach the program while its canvas has focus, and arrows and space
// do not scroll the page then
for (const type of ["keydown", "keyup", "keypress"]) {
  window.addEventListener(type, (e) => {
    if (document.activeElement !== canvas) e.stopImmediatePropagation();
    else if ([" ", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab"].includes(e.key)) e.preventDefault();
  }, true);
}
// the audio the program opens (raylib's miniaudio), closed when it ends:
// its callback must not call into a program that is gone
const audio = [];
const BaseAudioContext = window.AudioContext || window.webkitAudioContext;
if (BaseAudioContext) {
  window.AudioContext = class extends BaseAudioContext {
    constructor(...options) { super(...options); audio.push(this); }
  };
}
window.addEventListener("error", (e) => {
  if (/miniaudio is not defined/.test(e.message)) e.preventDefault();
});
full.addEventListener("click", () => document.getElementById("stage").requestFullscreen().then(() => canvas.focus()));

let started = false;
async function start() {
  if (started) return;
  started = true;
  play.disabled = true;
  say("loading…");
  const [{ default: createSlang }, files] = await Promise.all([
    import("./slang-gfx.js"),
    fetch("files.json").then((r) => r.json()),
  ]);
  let module;
  module = await createSlang({
    canvas,
    print: show(""),
    printErr: show("err"),
    onExit: (code) => {
      for (const context of audio) context.close().catch(() => {});
      say(code === 0 ? "ended" : `ended (exit code ${code})`);
    },
    // (the program's environment is read before main starts)
    preRun: [(m) => {
      for (const [k, v] of new URLSearchParams(location.search)) m.ENV[k] = v;
    }],
  });
  window.slang = module;
  const FS = module.FS;
  FS.mkdir("/work");
  for (const [path, content] of Object.entries(files)) {
    const parts = path.split("/");
    for (let i = 1; i < parts.length; i++) {
      try { FS.mkdir("/work/" + parts.slice(0, i).join("/")); } catch {}
    }
    FS.writeFile("/work/" + path, content && content.b64 ? unb64(content.b64) : content);
  }
  // what the program keeps under $HOME stays in the browser between visits
  const home = module.ENV.HOME || "/home/web_user";
  try { FS.mkdirTree(home); } catch {}
  FS.mount(module.IDBFS, {}, home);
  await new Promise((done) => FS.syncfs(true, done));
  let syncing = false;
  setInterval(() => {
    if (syncing) return;
    syncing = true;
    FS.syncfs(false, () => { syncing = false; });
  }, 3000);
  play.hidden = true;
  full.hidden = false;
  say("click the picture to give it the mouse and the keys");
  canvas.focus();
  FS.chdir("/work");
  try {
    module.callMain(["run", "/work/MAIN"]);
  } catch (e) {
    if (e !== "unwind" && !(e && e.name === "ExitStatus")) show("err")(String(e && e.stack || e));
  }
}
play.addEventListener("click", start);
if (new URLSearchParams(location.search).has("autostart")) start();
</script>
</body>
</html>
"""

os.mkdir_all(out)
local info = concat(
  string(count), " files; the first start loads about ",
  string(to_int((len(os.read_file(concat(vm_dir, "/slang-gfx.wasm"))) + bytes) / 1000000)),
  " MB",
)
page = str.replace(page, "TITLE", escape(title))
page = str.replace(page, "INFO", escape(info))
page = str.replace(page, "MAIN", "main.slang")
os.write_file(concat(out, "/index.html"), page)
os.write_file(concat(out, "/files.json"), json.encode(files))
for(let local f in values({"slang-gfx.js", "slang-gfx.wasm"})){
  os.copy_file(concat(vm_dir, "/", f), concat(out, "/", f))
}
print(out, "/index.html: ", info, "\n")
