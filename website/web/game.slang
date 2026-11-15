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
//
// What a project adds to its page lives in its site/ directory, copied
// next to the page (and not among the program's files). site/index.html,
// when there is one, is the page itself; it loads launcher.js (written
// here: it starts the program) and gives it the elements launcher.js
// names. site/page.js, when
// there is one, is a module the page imports; it may export
//   setup(page)        when the page is loaded (page.header takes controls)
//   beforeStart(page)  before the program starts: what it puts in
//                      page.env is the program's environment (the URL's
//                      query still wins); may be async
//   message(text, page)  a message the program sent (slang/web's send)
//   started(page)      the program started (its first frame is drawn)
//   progress(page, share, text)  how the start goes (0 to 1)
// and page.send(text) is a message to the program (slang/web's receive);
// page.say(text) shows a line of status, page.show(cls)(text) a line of
// output. A server directory (server/) is
// not the program either.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local encoding = require("slang/encoding")

local PACKAGES = {"raylib", "box2d", "jolt", "kernel", "dsp"}
// directories that are not the program
local SKIP_DIRS = {test: true, tool: true, out: true, web: true, site: true, server: true, design: true, [".git"]: true}
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

local default_page = """<!doctype html>
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
  .progress { position: relative; width: 180px; height: 4px; border-radius: 2px; background: #2a2e31; overflow: hidden; }
  .progress i { position: absolute; inset: 0; background: var(--accent); transform-origin: left;
    transform: scaleX(var(--progress, 0)); transition: transform .2s; }
  .progress.busy i { transform: scaleX(.35); animation: slide 1.1s ease-in-out infinite alternate; }
  @keyframes slide { from { transform: translateX(0) scaleX(.35); } to { transform: translateX(65%) scaleX(.35); } }
  .progress[hidden], .progress[hidden] + .ptext { display: none; }
  .ptext { color: var(--dim); font-size: 13px; }
  #output { margin: 0; max-height: 9em; overflow: auto; padding: 0 16px 8px; color: var(--dim);
    font: 12px/1.35 ui-monospace, Menlo, monospace; white-space: pre-wrap; }
  #output .err { color: #e07a6a; }
</style>
</head>
<body>
<header>
  <h1>TITLE</h1>
  <button id="play" data-play>Play</button>
  <button id="full" class="quiet" hidden>Full screen</button>
  <span id="status">INFO</span>
  <span class="progress" data-progress hidden><i></i></span><span class="ptext" data-progress-text></span>
</header>
<div id="stage"><canvas id="canvas" tabindex="0" oncontextmenu="event.preventDefault()"></canvas></div>
<pre id="output"></pre>
<script type="module" src="launcher.js"></script>
</body>
</html>
"""

local launcher = """// launcher.js, written by website/web/game.slang: starts the program on
// the graphics VM in this page (see game.slang for what a page provides).
// What the page has: #canvas (the program's window), buttons with
// data-play (start it), #status (a line of status), #output (what it
// prints), #full (full screen), #stage (what goes full screen), and
// [data-progress] / [data-progress-text] (how the start goes: see
// progress below); all but the canvas are optional.
const status = document.getElementById("status");
const output = document.getElementById("output");
const canvas = document.getElementById("canvas");
const plays = [...document.querySelectorAll("[data-play]")];
const full = document.getElementById("full");
const say = (text) => { if (status) status.textContent = text; };
const show = (cls) => (text) => {
  if (cls) console.error(text); else console.log(text);
  if (!output) return;
  const line = document.createElement("div");
  if (cls) line.className = cls;
  line.textContent = text;
  output.appendChild(line);
  output.scrollTop = output.scrollHeight;
};
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// keys reach the program while its canvas has focus, and arrows and space
// do not scroll the page then
for (const type of ["keydown", "keyup", "keypress"]) {
  window.addEventListener(type, (e) => {
    // (what is typed into the page's own fields stays theirs)
    if (e.target.closest && e.target.closest("input, textarea, select, [contenteditable]")) return;
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
if (full) full.addEventListener("click", () => document.getElementById("stage").requestFullscreen().then(() => canvas.focus()));

// the project's own part of the page (site/page.js); progress(page,
// share, text) hears how the start goes
const hooks = HOOKS ? await import("./page.js") : {};
const page = { header: document.querySelector("header"), say, show, env: {}, send: () => {}, started: false };
if (hooks.setup) await hooks.setup(page);

// How the start goes, on the page: elements with data-progress get
// --progress (0 to 1), and the class "busy" while the program starts and
// nothing can be measured (an animation of transform keeps moving then,
// though the page itself is held); [data-progress-text] the words.
const bars = [...document.querySelectorAll("[data-progress]")];
const words = [...document.querySelectorAll("[data-progress-text]")];
function progress(share, text, busy = false) {
  for (const b of bars) {
    b.hidden = false;
    b.style.setProperty("--progress", String(Math.max(0, Math.min(1, share))));
    b.classList.toggle("busy", busy);
  }
  for (const w of words) w.textContent = text;
  if (hooks.progress) hooks.progress(page, share, text);
}
const MB = (n) => (n / 1e6).toFixed(1);
// the files' sizes, as game.slang wrote them (a server need not say them,
// and one that compresses says less)
const SIZES = SIZES_JSON;
// the bytes of url, telling got(bytes) as they come
async function download(url, got) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: the server answered ${res.status}`);
  if (!res.body) {
    const all = new Uint8Array(await res.arrayBuffer());
    got(all.length);
    return all;
  }
  const reader = res.body.getReader();
  const chunks = [];
  let length = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    length += value.length;
    got(value.length);
  }
  const all = new Uint8Array(length);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.length; }
  return all;
}
// a frame for the page to show what it says before the program holds it
const painted = () => new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));

let started = false;
async function start() {
  if (started) return;
  started = true;
  for (const b of plays) b.disabled = true;
  say("loading…");
  if (hooks.beforeStart) {
    try {
      await hooks.beforeStart(page);
    } catch (e) {
      show("err")(String(e && e.message || e));
    }
  }
  // the VM and the program's files, as they come (about 0.8 of the bar)
  const total = SIZES["slang-gfx.wasm"] + SIZES["files.json"];
  let got = 0;
  const more = (n) => {
    got += n;
    progress(0.8 * Math.min(1, got / total), `Downloading the game · ${MB(Math.min(got, total))} of ${MB(total)} MB`);
  };
  more(0);
  const [{ default: createSlang }, wasm, filesBytes] = await Promise.all([
    import("./slang-gfx.js"),
    download("slang-gfx.wasm", more),
    download("files.json", more),
  ]);
  const files = JSON.parse(new TextDecoder().decode(filesBytes));
  progress(0.82, "Preparing the engine");
  await painted();
  let module;
  module = await createSlang({
    canvas,
    // (the bytes downloaded above)
    instantiateWasm: (imports, done) => {
      WebAssembly.instantiate(wasm, imports).then((r) => done(r.instance, r.module), (e) => show("err")(String(e)));
      return {};
    },
    print: show(""),
    printErr: show("err"),
    onExit: (code) => {
      for (const context of audio) context.close().catch(() => {});
      say(code === 0 ? "ended" : `ended (exit code ${code})`);
    },
    // (the program's environment is read before main starts)
    preRun: [(m) => {
      for (const [k, v] of Object.entries(page.env)) m.ENV[k] = String(v);
      for (const [k, v] of new URLSearchParams(location.search)) m.ENV[k] = v;
    }],
  });
  window.slang = module;
  // messages: the program's to the project's page.js, and back
  module.programInbox = [];
  module.onProgramMessage = (text) => { if (hooks.message) hooks.message(text, page); };
  page.send = (text) => module.programInbox.push(text);
  progress(0.88, "Unpacking the game");
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
  for (const b of plays) b.hidden = true;
  // the program compiles its modules and runs until its first frame: the
  // page is held meanwhile
  progress(0.92, "Starting the engine", true);
  await painted();
  FS.chdir("/work");
  try {
    module.callMain(["run", "/work/MAIN"]);
  } catch (e) {
    if (e !== "unwind" && !(e && e.name === "ExitStatus")) show("err")(String(e && e.stack || e));
  }
  // (its first frame is drawn: the program shows how it goes on)
  progress(1, "");
  for (const b of bars) b.hidden = true;
  if (full) full.hidden = false;
  page.started = true;
  document.body.classList.add("running");
  if (hooks.started) hooks.started(page);
  say("click the picture to give it the mouse and the keys");
  canvas.focus();
}
for (const b of plays) b.addEventListener("click", start);
if (new URLSearchParams(location.search).has("autostart")) start();
"""


os.mkdir_all(out)
// the project's own part of the page
local site = concat(project, "/site")
local hooks = false
local func copy_site(dir, rel){
  for(let local name in values(os.list_dir(dir))){
    local from = concat(dir, "/", name)
    local to = if(rel == ""){ name } else { concat(rel, "/", name) }
    if(os.is_dir(from)){
      os.mkdir_all(concat(out, "/", to))
      copy_site(from, to)
    } else {
      os.copy_file(from, concat(out, "/", to))
      if(to == "page.js"){
        hooks = true
      }
    }
  }
}
if(os.is_dir(site)){
  copy_site(site, "")
}
local info = concat(
  string(count), " files; the first start loads about ",
  string(to_int((len(os.read_file(concat(vm_dir, "/slang-gfx.wasm"))) + bytes) / 1000000)),
  " MB",
)
// the project's own page (site/index.html), or the plain one
if(not os.exists(concat(site, "/index.html"))){
  local page = str.replace(default_page, "TITLE", escape(title))
  page = str.replace(page, "INFO", escape(info))
  os.write_file(concat(out, "/index.html"), page)
}
launcher = str.replace(launcher, "/work/MAIN", "/work/main.slang")
launcher = str.replace(launcher, "HOOKS ?", if(hooks){ "true ?" } else { "false ?" })
launcher = str.replace(launcher, "SIZES_JSON", json.encode({
  ["slang-gfx.wasm"]: len(os.read_file(concat(vm_dir, "/slang-gfx.wasm"))),
  ["files.json"]: len(json.encode(files)),
}))
os.write_file(concat(out, "/launcher.js"), launcher)
os.write_file(concat(out, "/files.json"), json.encode(files))
for(let local f in values({"slang-gfx.js", "slang-gfx.wasm"})){
  os.copy_file(concat(vm_dir, "/", f), concat(out, "/", f))
}
print(out, "/index.html: ", info, "\n")
