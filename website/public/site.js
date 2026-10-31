// The site's live code: every [data-workbench] becomes an editor that
// highlights and checks as you type (slang highlight --check), runs
// (slang run) and formats (slang fmt) on slang.wasm in a worker.

// ---------------------------------------------------------------- workers

class Worker2 {
  constructor() {
    this.url = new URL("worker.js", import.meta.url);
    this.spawn();
  }
  spawn() {
    this.worker = new Worker(this.url, { type: "module" });
    this.worker.onmessage = (e) => this.receive(e.data);
    this.pending = new Map();
    this.next = 0;
  }
  request(cmd, code, onStream, files) {
    const id = ++this.next;
    return new Promise((resolve) => {
      this.pending.set(id, { resolve, onStream });
      this.worker.postMessage({ id, cmd, code, files });
    });
  }
  receive(m) {
    const p = this.pending.get(m.id);
    if (!p) return;
    if (m.stream) {
      if (p.onStream) p.onStream(m.stream, m.text);
      return;
    }
    this.pending.delete(m.id);
    p.resolve(m);
  }
  // stops what runs (an endless loop, say) and starts a fresh worker
  kill() {
    this.worker.terminate();
    const pending = [...this.pending.values()];
    this.spawn();
    for (const p of pending) p.resolve({ killed: true, code: -2, stdout: "", stderr: "" });
  }
}

// one for checking and formatting, one for running (so a long run can be
// stopped without losing the checker); made when first needed
let checker = null, runner = null;
const check = (cmd, code, files) => (checker ||= new Worker2()).request(cmd, code, null, files);

// the files an extension's page carries for its examples (the extension's
// source), by path
const pageFiles = (() => {
  const el = document.getElementById("ext-files");
  return el ? JSON.parse(el.textContent) : null;
})();
const utf8Length = (s) => new TextEncoder().encode(s).length;

// ---------------------------------------------------------------- text

const escapeHtml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// byte offsets (what slang reports) to string indices
function byteMap(text) {
  if (!/[^\x00-\x7f]/.test(text)) return null;
  const map = [];
  for (let i = 0; i < text.length; i++) {
    const c = text.codePointAt(i);
    const n = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    for (let k = 0; k < n; k++) map.push(i);
    if (c >= 0x10000) i++;
  }
  map.push(text.length);
  return map;
}
const toIndex = (map, b) => (map ? map[Math.min(b, map.length - 1)] : b);

function lineStarts(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") starts.push(i + 1);
  return starts;
}

// the highlighted HTML of text: tokens [{from, to, kind}], problems
// [{from, to, severity}]
function render(text, tokens, problems) {
  const n = text.length;
  const kind = new Array(n).fill(null);
  for (const t of tokens) for (let i = Math.max(0, t.from); i < Math.min(n, t.to); i++) kind[i] = t.kind;
  const sev = new Array(n).fill(null);
  for (const p of problems) {
    for (let i = Math.max(0, p.from); i < Math.min(n, p.to); i++) {
      if (sev[i] !== "error") sev[i] = p.severity;
    }
  }
  let html = "";
  let i = 0;
  while (i < n) {
    let j = i + 1;
    while (j < n && kind[j] === kind[i] && sev[j] === sev[i]) j++;
    let piece = escapeHtml(text.slice(i, j));
    if (kind[i]) piece = `<span class="t-${kind[i]}">${piece}</span>`;
    if (sev[i]) piece = `<span class="sq sq-${sev[i]}">${piece}</span>`;
    html += piece;
    i = j;
  }
  return html + "\n";
}

// ---------------------------------------------------------------- editor

class Editor {
  // prefix: a line the code is checked after, unseen (an extension statement)
  constructor(root, prefix = "", files = null) {
    this.root = root;
    this.prefix = prefix;
    this.files = files;
    this.prefixLines = prefix ? prefix.split("\n").length - 1 : 0;
    this.prefixBytes = utf8Length(prefix);
    this.input = root.querySelector(".ed-input");
    this.code = root.querySelector(".ed-hl code");
    this.original = this.input.value;
    this.text = this.input.value;
    this.tokens = null; // [{from, to, kind}] for this.text, once checked
    this.problems = [];
    this.version = 0;
    this.listeners = [];
    this.input.addEventListener("input", () => this.changed());
    this.input.addEventListener("keydown", (e) => this.key(e));
    this.input.addEventListener("scroll", () => this.follow());
    this.grow = !root.closest(".big");
    this.fit();
  }
  // the highlighted copy under the textarea scrolls with it
  follow() {
    this.code.parentElement.scrollTop = this.input.scrollTop;
    this.code.parentElement.scrollLeft = this.input.scrollLeft;
  }
  // an editor in a page grows with its code (up to its max-height)
  fit() {
    if (!this.grow) return;
    this.input.style.height = "auto";
    this.input.style.height = this.input.scrollHeight + 2 + "px";
  }
  get value() {
    return this.input.value;
  }
  set value(text) {
    this.input.focus();
    this.input.select();
    // keeps undo where the browser can
    if (!document.execCommand || !document.execCommand("insertText", false, text)) {
      this.input.value = text;
    }
    this.input.setSelectionRange(0, 0);
    this.input.scrollTop = 0;
    this.changed();
  }
  onChange(f) {
    this.listeners.push(f);
  }
  // until the checker answers, the old colours stay on the text before and
  // after the change
  changed() {
    const next = this.input.value;
    const old = this.text;
    let p = 0;
    while (p < old.length && p < next.length && old[p] === next[p]) p++;
    let s = 0;
    while (s < old.length - p && s < next.length - p && old[old.length - 1 - s] === next[next.length - 1 - s]) s++;
    const delta = next.length - old.length;
    const keep = (list) => list.flatMap((t) => {
      if (t.to <= p) return [t];
      if (t.from >= old.length - s) return [{ ...t, from: t.from + delta, to: t.to + delta }];
      return [];
    });
    this.text = next;
    if (this.tokens) this.tokens = keep(this.tokens);
    this.problems = keep(this.problems);
    this.paint();
    this.fit();
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.check(), 180);
    for (const f of this.listeners) f();
  }
  async check() {
    const v = ++this.version;
    const text = this.input.value;
    const r = await check("check", this.prefix + text, this.files);
    if (v !== this.version || r.killed) return;
    let data;
    try {
      data = JSON.parse(r.stdout);
    } catch {
      return;
    }
    const map = byteMap(text);
    const starts = lineStarts(text);
    // positions come for prefix + text: the prefix's part is dropped
    const pb = this.prefixBytes, pl = this.prefixLines;
    this.tokens = data.tokens.filter((t) => t.start >= pb).map((t) => ({
      from: toIndex(map, t.start - pb),
      to: toIndex(map, t.start - pb + t.length),
      kind: t.category.split(".")[0],
    }));
    const diagnostics = data.diagnostics
      .map((d) => ({ ...d, line: Math.max(1, d.line - pl) }));
    this.problems = diagnostics.map((d) => {
      // columns count bytes from the line's start
      const lineStart = starts[Math.min(d.line - 1, starts.length - 1)] || 0;
      const lineBytes = map ? new TextEncoder().encode(text.slice(0, lineStart)).length : lineStart;
      const from = toIndex(map, lineBytes + d.column - 1);
      let to = d.length ? toIndex(map, lineBytes + d.column - 1 + d.length) : from;
      if (!d.length) {
        while (to < text.length && /[\w]/.test(text[to])) to++;
        if (to === from) to = Math.min(text.length, from + 1);
      }
      return { from, to, line: d.line, column: d.column, message: d.message, severity: d.severity };
    });
    this.paint();
    for (const f of this.listeners) f("checked");
  }
  paint() {
    const tokens = this.tokens || [];
    this.code.innerHTML = this.tokens || this.problems.length
      ? render(this.text, tokens, this.problems)
      : escapeHtml(this.text) + "\n";
    this.follow();
  }
  goto(line, column) {
    const starts = lineStarts(this.input.value);
    const at = (starts[line - 1] ?? 0) + Math.max(0, (column || 1) - 1);
    this.input.focus();
    this.input.setSelectionRange(at, at);
    const lineHeight = parseFloat(getComputedStyle(this.input).lineHeight) || 20;
    this.input.scrollTop = Math.max(0, (line - 3) * lineHeight);
  }
  key(e) {
    const ta = this.input;
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
      e.preventDefault();
      this.root.dispatchEvent(new CustomEvent("run", { bubbles: true }));
      return;
    }
    const { selectionStart: a, selectionEnd: b, value } = ta;
    const insert = (text) => {
      if (!document.execCommand("insertText", false, text)) {
        ta.setRangeText(text, ta.selectionStart, ta.selectionEnd, "end");
        this.changed();
      }
    };
    if (e.key === "Tab") {
      e.preventDefault();
      const lineStart = value.lastIndexOf("\n", a - 1) + 1;
      if (a === b && !e.shiftKey) return insert("  ");
      // indent or outdent the selected lines
      const end = value.indexOf("\n", b - (b > a && value[b - 1] === "\n" ? 1 : 0));
      const stop = end < 0 ? value.length : end;
      const lines = value.slice(lineStart, stop).split("\n");
      const changed = lines.map((l) => (e.shiftKey ? l.replace(/^ {1,2}/, "") : "  " + l)).join("\n");
      ta.setSelectionRange(lineStart, stop);
      insert(changed);
      ta.setSelectionRange(lineStart, lineStart + changed.length);
      return;
    }
    if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
      // keep the indentation, one more after an opening bracket
      const lineStart = value.lastIndexOf("\n", a - 1) + 1;
      const indent = value.slice(lineStart).match(/^ */)[0];
      const before = value.slice(lineStart, a).trimEnd();
      const opens = /[{(\[]$/.test(before);
      const closes = /^[})\]]/.test(value.slice(b));
      e.preventDefault();
      if (opens && closes) {
        insert(`\n${indent}  \n${indent}`);
        const at = ta.selectionStart - indent.length - 1;
        ta.setSelectionRange(at, at);
      } else {
        insert(`\n${indent}${opens ? "  " : ""}`);
      }
      return;
    }
    if (e.key === "}" && a === b) {
      // a closing brace on a line of spaces goes back one step
      const lineStart = value.lastIndexOf("\n", a - 1) + 1;
      const line = value.slice(lineStart, a);
      if (/^ {2,}$/.test(line)) {
        e.preventDefault();
        ta.setSelectionRange(a - 2, a);
        insert("}");
      }
    }
  }
}

// ---------------------------------------------------------------- output

// a program's output, with main.slang:line:col made into links
function outputHtml(text, kind, shift = 0) {
  return text.split(/(\n)/).map((line) => {
    if (line === "\n") return line;
    let cls = kind === 2 ? "err" : "";
    if (kind === 2 && /^\s+at (.*\()?(slang\/|\[native)/.test(line)) cls += " trace";
    const html = escapeHtml(line.replace(/\/work\/main\.slang/g, "main.slang"))
      .replace(/main\.slang:(\d+):(\d+)/g, (_, l, c) => {
        const line = Math.max(1, +l - shift);
        return `<a href="#" data-line="${line}" data-col="${c}">main.slang:${line}:${c}</a>`;
      });
    return cls ? `<span class="${cls}">${html}</span>` : html;
  }).join("");
}

const LIMIT = 200000;

class Workbench {
  constructor(root) {
    this.root = root;
    this.prefix = root.dataset.prefix || "";
    this.files = this.prefix ? pageFiles : null;
    this.editor = new Editor(root.querySelector("[data-editor]"), this.prefix, this.files);
    this.expanded = root.querySelector("[data-expanded]");
    this.expandedFor = this.editor.value;
    for (const tab of root.querySelectorAll("[data-tab]")) {
      tab.addEventListener("click", () => this.show(tab.dataset.tab));
    }
    this.output = root.querySelector("[data-output]");
    this.status = root.querySelector("[data-status]");
    this.problems = root.querySelector("[data-problems]");
    this.runButton = root.querySelector("[data-run]");
    this.running = false;
    this.runButton?.addEventListener("click", () => (this.running ? this.stop() : this.run()));
    root.addEventListener("run", () => this.run());
    root.querySelector("[data-format]")?.addEventListener("click", () => this.format());
    root.querySelector("[data-reset]")?.addEventListener("click", () => {
      this.show("code");
      this.editor.value = this.editor.original;
      this.output.textContent = "";
      this.output.classList.remove("shown");
    });
    const open = root.querySelector("[data-open]");
    open?.addEventListener("click", async (e) => {
      e.preventDefault();
      location.href = open.getAttribute("href") + "#code=" + (await pack(this.editor.value));
    });
    this.output.addEventListener("click", (e) => {
      const a = e.target.closest("a[data-line]");
      if (!a) return;
      e.preventDefault();
      this.editor.goto(+a.dataset.line, +a.dataset.col);
    });
    this.problems.addEventListener("click", (e) => {
      const b = e.target.closest("[data-line]");
      if (b) this.editor.goto(+b.dataset.line, +b.dataset.col);
    });
    this.editor.onChange((what) => {
      if (what === "checked") this.showProblems();
    });
  }
  // the Example / Expanded toggle: the expansion of the code as it is now
  async show(which) {
    if (!this.expanded) return;
    for (const tab of this.root.querySelectorAll("[data-tab]")) {
      tab.setAttribute("aria-selected", String(tab.dataset.tab === which));
    }
    const editorBox = this.root.querySelector("[data-editor]");
    editorBox.hidden = which !== "code";
    this.expanded.hidden = which === "code";
    if (which === "code" || this.expandedFor === this.editor.value) return;
    const code = this.editor.value;
    this.say("expanding…");
    const r = await check("expand", this.prefix + code, this.files);
    if (r.code !== 0) {
      this.expanded.querySelector("code").textContent = "(the example does not parse: fix it first)";
      this.say("");
      return;
    }
    const text = r.stdout.replace(/\n+$/, "");
    const hl = await check("check", text);
    let tokens = [];
    try {
      const map = byteMap(text);
      tokens = JSON.parse(hl.stdout).tokens.map((t) => ({
        from: toIndex(map, t.start),
        to: toIndex(map, t.start + t.length),
        kind: t.category.split(".")[0],
      }));
    } catch {}
    this.expanded.querySelector("code").innerHTML = render(text, tokens, []);
    this.expandedFor = code;
    this.say("");
  }
  showProblems() {
    const list = this.editor.problems;
    this.problems.innerHTML = list.map((p) =>
      `<button class="problem ${p.severity}" data-line="${p.line}" data-col="${p.column}">` +
      `<span class="where">${p.line}:${p.column}</span> ${escapeHtml(p.message)}</button>`).join("");
    this.problems.classList.toggle("shown", list.length > 0);
  }
  say(text) {
    if (this.status) this.status.textContent = text;
  }
  async run() {
    if (this.running) return;
    if (usesRaylib(this.editor.value)) return this.runGraphics();
    this.running = true;
    this.runButton.textContent = "Stop";
    this.runButton.classList.add("stop");
    this.output.classList.add("shown");
    this.output.innerHTML = "";
    this.say("running…");
    let shown = 0;
    const append = (fd, text) => {
      if (shown > LIMIT) return;
      shown += text.length;
      this.output.insertAdjacentHTML("beforeend", outputHtml(text, fd, this.editor.prefixLines));
      if (shown > LIMIT) {
        this.output.insertAdjacentHTML("beforeend", '<span class="err">\n… output limit reached, stopped\n</span>');
        this.stop(true);
      }
    };
    runner ||= new Worker2();
    const started = performance.now();
    this.timer = setTimeout(() => this.stop(), 20000);
    const r = await runner.request("run", this.prefix + this.editor.value, append, this.files);
    clearTimeout(this.timer);
    this.running = false;
    this.runButton.textContent = "Run";
    this.runButton.classList.remove("stop");
    if (r.killed) {
      this.say(this.stopped === "limit" ? "stopped" : "stopped after " + Math.round((performance.now() - started) / 1000) + " s");
      if (this.stopped !== "limit") this.output.insertAdjacentHTML("beforeend", '<span class="err">\n■ stopped\n</span>');
      this.stopped = null;
      return;
    }
    if (!this.output.textContent) this.output.innerHTML = '<span class="dim">(no output)</span>';
    const ms = Math.round(r.ms);
    this.say(r.code === 0 ? `done in ${ms} ms` : `exit code ${r.code}`);
  }
  // a raylib program: the graphics VM, a canvas above the output
  async runGraphics() {
    stopGraphics();
    this.running = true;
    this.runButton.textContent = "Stop";
    this.runButton.classList.add("stop");
    this.output.classList.add("shown");
    this.output.innerHTML = "";
    this.say("loading raylib…");
    guardKeys();
    let stage = this.root.querySelector(".stage");
    if (!stage) {
      stage = document.createElement("div");
      stage.className = "stage";
      this.output.before(stage);
    }
    // a fresh canvas for every run: a WebGL context does not start over
    stage.innerHTML = '<canvas tabindex="0" aria-label="The program\'s window"></canvas>' +
      '<p class="hint">Click the window to give it the keyboard. ' +
      '<button class="btn ghost small" data-fullscreen>Fullscreen</button></p>';
    const canvas = stage.querySelector("canvas");
    // the right button is the game's, not the browser's menu
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());
    stage.querySelector("[data-fullscreen]").addEventListener("click", () => {
      (stage.requestFullscreen || stage.webkitRequestFullscreen).call(stage);
      canvas.focus();
    });
    const shift = this.editor.prefixLines;
    const show = (fd) => (text) => {
      this.output.insertAdjacentHTML("beforeend", outputHtml(text + "\n", fd, shift));
      this.output.scrollTop = this.output.scrollHeight;
    };
    let createSlang;
    try {
      ({ default: createSlang } = await import(new URL("slang-gfx.js", import.meta.url)));
    } catch {
      show(2)("The graphics VM is not built here (make wasm-gfx).");
      return this.graphicsEnded("unavailable");
    }
    let module = null;
    module = await createSlang({
      canvas,
      print: show(1),
      printErr: show(2),
      // (a run that was stopped ends here too: its status stays)
      onExit: (code) => {
        if (gfx && gfx.module === module) this.graphicsEnded(code === 0 ? "done" : `exit code ${code}`);
      },
    });
    gfx = { module, canvas, bench: this };
    module.FS.mkdir("/work");
    for (const [path, text] of Object.entries(this.files || {})) {
      const parts = path.split("/");
      for (let i = 1; i < parts.length; i++) {
        try { module.FS.mkdir("/work/" + parts.slice(0, i).join("/")); } catch {}
      }
      module.FS.writeFile("/work/" + path, text);
    }
    module.FS.writeFile("/work/main.slang", this.prefix + this.editor.value);
    module.FS.writeFile("/work/slang.project", '{name: "playground", dependencies: {raylib: {path: "/raylib"}}}');
    module.FS.writeFile("/work/slang.lock", '{["raylib"]: {path: "/raylib"}}');
    this.say("running");
    canvas.focus();
    try {
      module.callMain(["run", "/work/main.slang"]);
    } catch (e) {
      if (e !== "unwind" && !(e && e.name === "ExitStatus")) show(2)(String(e));
    }
  }
  graphicsEnded(status) {
    if (gfx && gfx.bench === this) gfx = null;
    this.running = false;
    this.runButton.textContent = "Run";
    this.runButton.classList.remove("stop");
    if (!this.output.textContent) this.output.innerHTML = '<span class="dim">(no output)</span>';
    this.say(status);
  }
  stop(limit) {
    if (gfx && gfx.bench === this) {
      stopGraphics();
      return this.graphicsEnded("stopped");
    }
    if (!this.running || !runner) return;
    this.stopped = limit ? "limit" : "user";
    runner.kill();
  }
  async format() {
    this.say("formatting…");
    const r = await check("fmt", this.prefix + this.editor.value, this.files);
    if (r.code !== 0) {
      this.say("fix the errors first");
      return;
    }
    // without the prefix's lines
    const formatted = r.stdout.split("\n").slice(this.editor.prefixLines).join("\n");
    if (formatted !== this.editor.value) this.editor.value = formatted;
    this.say("formatted");
  }
}

// ---------------------------------------------------------------- graphics

// A program that uses raylib runs on the graphics VM (slang built with
// Emscripten and raylib's web platform, website/web/build.sh) on the page
// itself, drawing into a canvas: it hands the browser control at the end of
// each frame, so the page stays responsive. One runs at a time.
const usesRaylib = (code) => /require\(\s*"raylib"\s*\)/.test(code);
let gfx = null; // {module, canvas, bench}

// keys reach the game only while its canvas has focus (raylib listens on
// the whole window); arrows and space do not scroll the page meanwhile.
// Registered before raylib's own listeners, so it sees the keys first.
let keyGuard = false;
function guardKeys() {
  if (keyGuard) return;
  keyGuard = true;
  for (const type of ["keydown", "keyup", "keypress"]) {
    window.addEventListener(type, (e) => {
      if (!gfx) return;
      if (document.activeElement !== gfx.canvas) {
        e.stopImmediatePropagation();
      } else if ([" ", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.key)) {
        e.preventDefault();
      }
    }, true);
  }
}

// in fullscreen the window is scaled to fill the screen, keeping its shape
// (the mouse stays right: Emscripten maps it through the displayed size)
document.addEventListener("fullscreenchange", () => {
  const stage = document.fullscreenElement;
  for (const canvas of document.querySelectorAll(".stage canvas")) {
    if (stage && stage.contains(canvas)) {
      const scale = Math.min(innerWidth / canvas.width, innerHeight / canvas.height);
      canvas.style.setProperty("width", `${Math.floor(canvas.width * scale)}px`, "important");
      canvas.style.setProperty("height", `${Math.floor(canvas.height * scale)}px`, "important");
      canvas.focus();
    } else {
      canvas.style.removeProperty("width");
      canvas.style.removeProperty("height");
    }
  }
});

function stopGraphics() {
  if (!gfx) return;
  const { module } = gfx;
  gfx = null;
  try {
    module._emscripten_cancel_main_loop();
    // (a sound that plays goes quiet; harmless when there is no audio)
    module._CloseAudioDevice();
    module._CloseWindow();
  } catch {}
}

// raylib 5.5's audio (miniaudio) leaves a click listener behind that refers
// to its global after closing its last device: that error says nothing
window.addEventListener("error", (e) => {
  if (/miniaudio is not defined/.test(e.message)) e.preventDefault();
});

// ---------------------------------------------------------------- sharing

const b64 = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64 = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function pack(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  return b64(new Uint8Array(await new Response(stream).arrayBuffer()));
}
async function unpack(s) {
  const stream = new Blob([unb64(s)]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return await new Response(stream).text();
}

// ---------------------------------------------------------------- pages

const benches = [...document.querySelectorAll("[data-workbench]")].map((el) => new Workbench(el));

// load the VM while the reader reads
if (benches.length) {
  const warm = () => (checker ||= new Worker2());
  (window.requestIdleCallback || ((f) => setTimeout(f, 300)))(warm);
}

if (document.body.classList.contains("play") && benches.length) {
  const bench = benches[0];
  const examples = JSON.parse(document.getElementById("examples").textContent);
  const select = document.querySelector("[data-examples]");
  const loadHash = async () => {
    const m = location.hash.match(/^#code=(.+)$/);
    if (!m) return;
    try {
      bench.editor.value = await unpack(m[1]);
    } catch {
      bench.say("that link holds no code");
    }
  };
  select.addEventListener("change", () => {
    const ex = examples[+select.value];
    if (!ex) return;
    // another example ends the one that runs
    if (bench.running) bench.stop();
    bench.editor.value = ex.code;
    bench.output.classList.remove("shown");
    history.replaceState(null, "", location.pathname);
  });
  document.querySelector("[data-share]").addEventListener("click", async () => {
    const url = location.origin + location.pathname + "#code=" + (await pack(bench.editor.value));
    history.replaceState(null, "", url);
    try {
      await navigator.clipboard.writeText(url);
      bench.say("link copied");
    } catch {
      bench.say("link in the address bar");
    }
  });
  window.addEventListener("hashchange", loadHash);
  loadHash();
}
