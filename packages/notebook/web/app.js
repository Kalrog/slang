// A notebook's page: one notebook with its cells, or (on the notebook
// server) a folder's notebooks. No libraries: slang highlights code (with
// its own parser) and renders Markdown; this script edits, asks and shows.
// What an editor knows about code (mistakes, completion, what a name is,
// where it is defined and used, renaming, formatting) is slang's language
// server's, asked through the session.
//
// The page talks to a notebook's session (notebook/session). On the
// notebook server that is the server, over a WebSocket. A page of its own
// (no server: notebook/export's app, which puts a configuration in
// #nb-config) runs the session itself, as slang.wasm in a worker, and
// keeps the notebook: in the browser's storage, and in a file of the
// reader's when they open or save one.
//
// Either way a kernel may run in the page too: slang.wasm in another
// worker (notebook/kernel_web), which the session drives through the page.
(function () {
  "use strict";

  const VALUE = "application/vnd.slang.value+json";
  // {vm, worker, files, notebook, key} of a page without a server, or null
  const CONFIG = (() => {
    const el = document.getElementById("nb-config");
    return el ? JSON.parse(el.textContent) : null;
  })();
  const main = document.getElementById("main");
  const crumbs = document.getElementById("crumbs");
  const actions = document.getElementById("actions");
  const toasts = document.getElementById("toasts");

  // ---------------------------------------------------------------- helpers

  // h("div", {class: "x", onclick: f}, child, ...): an element
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "html") el.innerHTML = v;
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) {
      if (kid != null && kid !== false) el.append(kid);
    }
    return el;
  }

  function icon(name) {
    const paths = {
      play: '<path d="M4 2.5v11l9-5.5z" fill="currentColor"/>',
      stop: '<rect x="3.5" y="3.5" width="9" height="9" rx="1.5" fill="currentColor"/>',
      restart: '<path d="M13 8a5 5 0 1 1-1.6-3.7M13 2.5v3h-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
      new: '<path d="M4 1.8h5l3 3v9.4H4zM9 1.8v3h3M8 7.5v4M6 9.5h4" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
      open: '<path d="M1.8 12.5V4a1 1 0 0 1 1-1h3l1.4 1.6h5a1 1 0 0 1 1 1v1.2M1.8 12.5l1.7-5h11l-1.7 5z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>',
      save: '<path d="M8 2v8M4.5 7 8 10.5 11.5 7M2.5 13.5h11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
      up: '<path d="M8 12.5v-9M4 7l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
      down: '<path d="M8 3.5v9M4 9l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
      trash: '<path d="M3 4.5h10M6.5 4.5v-2h3v2M4.5 4.5l.6 8.5h5.8l.6-8.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>',
      folder: '<path d="M1.5 4a1 1 0 0 1 1-1h3.2l1.5 1.7h6.3a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>',
      notebook: '<path d="M3.5 1.8h8a1 1 0 0 1 1 1v10.4a1 1 0 0 1-1 1h-8zM3.5 1.8v12.4M6 5.2h4M6 8h4" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
      theme: '<path d="M8 1.5a6.5 6.5 0 1 0 0 13z" fill="currentColor"/><circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" stroke-width="1.3"/>',
    };
    const span = document.createElement("span");
    span.style.display = "contents";
    span.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true">' + paths[name] + "</svg>";
    return span.firstChild;
  }

  function list(v) {
    return Array.isArray(v) ? v : [];
  }

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function toast(message, ms) {
    const el = h("div", { class: "toast" }, message);
    toasts.append(el);
    setTimeout(() => el.remove(), ms || 6000);
  }

  function encodePath(path) {
    return path.split("/").map(encodeURIComponent).join("/");
  }

  function setCrumbs(path, isFile) {
    const parts = path === "" ? [] : path.split("/");
    crumbs.replaceChildren();
    if (CONFIG) {
      // a page of its own has one notebook and no folders
      crumbs.append(h("span", { class: "sep" }, "/"), h("span", { class: "here" }, path));
      return;
    }
    let at = "";
    parts.forEach((part, i) => {
      at = at === "" ? part : at + "/" + part;
      crumbs.append(h("span", { class: "sep" }, "/"));
      if (i === parts.length - 1) {
        crumbs.append(h("span", { class: "here" }, part));
      } else {
        crumbs.append(h("a", { href: "/nb/" + encodePath(at) + "/" }, part));
      }
    });
  }

  function themeButton() {
    return h("button", {
      class: "tool icon", title: "Light or dark", "aria-label": "Switch between light and dark",
      onclick: () => {
        const root = document.documentElement;
        const dark = root.dataset.theme
          ? root.dataset.theme === "dark"
          : matchMedia("(prefers-color-scheme: dark)").matches;
        root.dataset.theme = dark ? "light" : "dark";
        try { localStorage.setItem("slang-notebook-theme", root.dataset.theme); } catch (e) {}
      },
    }, icon("theme"));
  }

  // ---------------------------------------------------------------- slang in the page

  let vmPromise = null;

  // slang as WebAssembly, compiled once for all the workers of the page
  function vmModule() {
    if (!vmPromise) {
      vmPromise = (async () => {
        const inline = document.getElementById("nb-vm");
        let res;
        if (inline) {
          // in the page itself: gzipped, in base64
          const text = atob(inline.textContent.trim());
          const bytes = new Uint8Array(text.length);
          for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
          res = new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")));
        } else {
          res = await fetch(CONFIG ? CONFIG.vm : "/static/web/slang.wasm");
          if (!res.ok) throw new Error("slang.wasm is not there (" + res.status + ")");
        }
        return WebAssembly.compile(await res.arrayBuffer());
      })();
      vmPromise.catch(() => { vmPromise = null; });
    }
    return vmPromise;
  }

  let workerScript = null;

  function workerURL() {
    if (!workerScript) {
      const inline = document.getElementById("nb-worker");
      if (inline) workerScript = URL.createObjectURL(new Blob([inline.textContent], { type: "text/javascript" }));
      else workerScript = CONFIG ? CONFIG.worker : "/static/web/worker.js";
    }
    return workerScript;
  }

  // whether this page can stop what runs in a worker of its: it needs
  // memory it shares with the worker, which only an isolated page has
  const canInterrupt = typeof SharedArrayBuffer !== "undefined" && self.crossOriginIsolated === true;

  // A slang program in a worker of the page (web/worker.js): on.message
  // gets what it sends (slang/web), on.output what it prints, on.exit its
  // end.
  class WasmVM {
    constructor(on) {
      this.on = on;
      this.worker = null;
      this.gone = false;
      this.flag = canInterrupt ? new SharedArrayBuffer(4) : null;
      this.ready = null;
    }

    // options: {args, files, cwd, env}
    start(options) {
      this.ready = (async () => {
        const module = await vmModule();
        if (this.gone) return;
        const worker = new Worker(workerURL());
        this.worker = worker;
        worker.onmessage = (e) => {
          if (this.gone) return;
          const m = e.data;
          if (m.type === "message") this.on.message(m.text);
          else if (m.type === "output") this.on.output(m.name, m.text);
          else if (m.type === "exit") { this.gone = true; worker.terminate(); this.on.exit(m.code); }
        };
        worker.onerror = (e) => {
          if (this.gone) return;
          this.gone = true;
          this.on.output("stderr", (e.message || "the worker failed") + "\n");
          this.on.exit(134);
        };
        worker.postMessage({
          op: "start", module: module, args: options.args, files: options.files,
          cwd: options.cwd, env: options.env, flag: this.flag,
        });
      })();
      return this.ready;
    }

    send(text) {
      if (!this.ready) return;
      this.ready.then(() => {
        if (!this.gone && this.worker) this.worker.postMessage({ op: "message", text: text });
      }, () => {});
    }

    // asks the program to stop what it runs; false when the page cannot
    interrupt() {
      if (!this.flag) return false;
      Atomics.store(new Int32Array(this.flag), 0, 1);
      return true;
    }

    stop() {
      this.gone = true;
      if (this.worker) this.worker.terminate();
    }
  }

  // The kernel of a notebook, in a worker of this page: does what the
  // session asks (the operations of notebook/remote) and gives emit the
  // kernel's events.
  class KernelHost {
    constructor(emit) {
      this.emit = emit;
      this.vm = null;
    }

    handle(op) {
      if (op.op === "start") {
        this.stop();
        const vm = new WasmVM({
          message: (text) => { if (this.vm === vm) this.emit(JSON.parse(text)); },
          output: (name, text) => { if (this.vm === vm) this.emit({ event: "stream", name: name, text: text }); },
          exit: (code) => {
            if (this.vm !== vm) return;
            this.vm = null;
            this.emit({ event: "exit", status: code });
          },
        });
        this.vm = vm;
        vm.start(op).catch((e) => {
          if (this.vm !== vm) return;
          this.vm = null;
          toast("slang did not start in the page: " + e.message);
          this.emit({ event: "exit", status: 1 });
        });
      } else if (op.op === "kill") {
        this.stop();
      } else if (op.op === "interrupt") {
        if (this.vm && !this.vm.interrupt()) {
          // nothing reaches a busy worker but its end
          this.stop();
          this.emit({
            event: "exit", status: 130,
            reason: "This page cannot stop a cell and keep the kernel, so the kernel was ended: what the cells had made is gone.",
          });
        }
      } else if (this.vm) {
        this.vm.send(JSON.stringify(op));
      }
    }

    stop() {
      if (this.vm) this.vm.stop();
      this.vm = null;
    }
  }

  // ---------------------------------------------------------------- a folder

  async function showFolder(path) {
    setCrumbs(path, false);
    actions.replaceChildren(themeButton());
    document.title = (path || "notebooks") + " - slang notebooks";
    const res = await fetch("/api/files?dir=" + encodeURIComponent(path));
    if (!res.ok) {
      main.replaceChildren(h("div", { class: "folder" }, h("p", { class: "empty" }, "There is no such folder.")));
      return;
    }
    const data = await res.json();
    const items = [];
    for (const f of list(data.folders)) {
      items.push(h("li", null, h("a", { href: "/nb/" + encodePath(f.path) + "/" },
        icon("folder"), h("span", { class: "name" }, f.name))));
    }
    for (const n of list(data.notebooks)) {
      const meta = [];
      if (n.open) meta.push(h("span", { class: "live" }, "running"));
      else if (n.outputs) meta.push("has outputs");
      if (n.modified) meta.push((meta.length ? " · " : "") + when(n.modified));
      items.push(h("li", { class: "is-notebook" }, h("a", { href: "/nb/" + encodePath(n.path) },
        icon("notebook"), h("span", { class: "name" }, n.name), h("span", { class: "meta" }, meta))));
    }
    const input = h("input", {
      type: "text", placeholder: "name of a new notebook", "aria-label": "Name of a new notebook",
      onkeydown: (e) => { if (e.key === "Enter") create(); },
    });
    async function create() {
      const name = input.value.trim();
      if (name === "") { input.focus(); return; }
      const r = await fetch("/api/new", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ dir: path, name: name }),
      });
      if (!r.ok) { toast(await r.text()); return; }
      location.href = "/nb/" + encodePath((await r.json()).path);
    }
    main.replaceChildren(h("div", { class: "folder" },
      h("h1", null, path === "" ? data.root : path.split("/").pop()),
      h("p", { class: "where" }, "Notebooks are Markdown files: text, and slang code in ```slang blocks."),
      items.length
        ? h("ul", { class: "entries" }, items)
        : h("div", { class: "entries" }, h("div", { class: "empty" }, "No notebooks here yet.")),
      h("div", { class: "create" }, input,
        h("button", { class: "tool primary", onclick: create }, "New notebook"))));
  }

  function when(ms) {
    const d = new Date(ms);
    const days = (Date.now() - ms) / 86400000;
    if (days < 1 && d.getDate() === new Date().getDate()) {
      return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    }
    return d.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
  }

  // ---------------------------------------------------------------- what cells show

  // printed text as a terminal would leave it: colour codes dropped, a
  // carriage return starts its line over
  function printed(text) {
    text = text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r\n/g, "\n");
    if (text.indexOf("\r") >= 0) {
      text = text.split("\n").map((line) => {
        const at = line.lastIndexOf("\r", line.length - 2);
        return (at >= 0 ? line.slice(at + 1) : line).replace(/\r$/, "");
      }).join("\n");
    }
    return text;
  }

  function quote(s) {
    return JSON.stringify(s);
  }

  function leaf(node) {
    const kinds = { string: 1, int: 1, double: 1, bool: 1, null: 1, function: 1 };
    let text = node.v == null ? "" : node.v;
    if (node.t === "string") {
      text = quote(text);
      if (node.more) text += "... " + node.more + " more bytes";
    }
    return h("span", { class: "v-" + (kinds[node.t] ? node.t : "other") }, text);
  }

  // a short look at a table, for its folded line
  function preview(node, budget) {
    if (node.t !== "table") {
      if (node.t === "itself" || node.t === "deep") return "{…}";
      const text = node.t === "string" ? quote(node.v) : String(node.v);
      return text.length > 40 ? text.slice(0, 40) + "…" : text;
    }
    const parts = [];
    let used = 2;
    for (const item of list(node.items)) {
      const piece = (item.k != null ? item.k + ": " : "") + preview(item.v, 24);
      used += piece.length + 2;
      if (used > budget) { parts.push("…"); break; }
      parts.push(piece);
    }
    if (node.more && parts[parts.length - 1] !== "…") parts.push("…");
    return "{" + parts.join(", ") + "}";
  }

  function treeNode(node, key, open) {
    const label = key != null ? [h("span", { class: "nb-key" }, key), ": "] : [];
    if (node.t !== "table" && node.t !== "itself" && node.t !== "deep") {
      return h("div", { class: "nb-leaf" }, label, leaf(node));
    }
    const size = node.t === "itself" ? "itself" : node.n === 1 ? "1 entry" : node.n + " entries";
    const items = list(node.items);
    const type = node.type ? node.type + " " : "";
    if (node.t !== "table" || items.length === 0) {
      return h("div", { class: "nb-leaf" }, label, type, "{", h("span", { class: "nb-meta" }, size), "}");
    }
    const look = h("span", null, preview(node, 64));
    const details = h("details", null,
      h("summary", null, label, type, look, " ", h("span", { class: "nb-meta" }, size)));
    let built = false;
    function build() {
      if (built) return;
      built = true;
      const kids = h("div", { class: "nb-kids" }, items.map((item) => treeNode(item.v, item.k, false)));
      if (node.more) kids.append(h("div", { class: "nb-leaf nb-meta" }, "... " + node.more + " more"));
      details.append(kids);
    }
    details.addEventListener("toggle", () => { if (details.open) build(); });
    if (open) { build(); details.open = true; }
    return details;
  }

  // markup of the notebook's own making, with its scripts run
  function rich(markup) {
    const el = h("div", { class: "nb-rich", html: markup });
    for (const old of el.querySelectorAll("script")) {
      const script = document.createElement("script");
      for (const a of old.attributes) script.setAttribute(a.name, a.value);
      script.textContent = old.textContent;
      old.replaceWith(script);
    }
    return el;
  }

  function dataElement(data) {
    data = data || {};
    if (data["text/html"] != null) return rich(data["text/html"]);
    if (data["image/svg+xml"] != null) return rich(data["image/svg+xml"]);
    for (const mime of ["image/png", "image/jpeg", "image/gif", "image/webp"]) {
      if (data[mime] != null) {
        return h("div", { class: "nb-rich" }, h("img", { alt: "", src: "data:" + mime + ";base64," + data[mime] }));
      }
    }
    if (data["audio/wav"] != null) {
      return h("audio", { controls: true, src: "data:audio/wav;base64," + data["audio/wav"] });
    }
    if (data[VALUE] != null) {
      const node = data[VALUE];
      return h("div", { class: "nb-tree" }, treeNode(node, null, node.n <= 12));
    }
    return h("pre", null, String(data["text/plain"] == null ? "" : data["text/plain"]));
  }

  function errorElement(cell, e) {
    e = e || {};
    let where = null;
    if (e.cell_line != null) {
      where = h("a", {
        class: "nb-error-where", href: "#",
        onclick: (ev) => { ev.preventDefault(); cell.focusLine(e.cell_line); },
      }, "line " + e.cell_line);
    } else if (e.location && e.location.line != null) {
      where = h("span", { class: "nb-error-where" }, e.location.origin + ":" + e.location.line);
    }
    return h("div", { class: "nb-error" },
      h("div", { class: "nb-error-head" },
        h("span", { class: "nb-error-kind" }, (e.kind || "error") + ":"), " ", e.message || "", " ", where),
      e.stack ? h("pre", null, e.stack) : null);
  }

  // ---------------------------------------------------------------- places in text

  function isWordChar(c) {
    return c != null && /[A-Za-z0-9_]/.test(c);
  }

  // the word around a place: [from, to)
  function wordAt(text, offset) {
    let from = offset;
    let to = offset;
    while (from > 0 && isWordChar(text[from - 1])) from--;
    while (to < text.length && isWordChar(text[to])) to++;
    return [from, to];
  }

  // a place as the session names it: {line, character}, both from 0
  function positionOf(text, offset) {
    let line = 0;
    let start = 0;
    for (;;) {
      const next = text.indexOf("\n", start);
      if (next < 0 || next >= offset) break;
      line++;
      start = next + 1;
    }
    return { line: line, character: offset - start };
  }

  function offsetOf(text, line, character) {
    let start = 0;
    for (let i = 0; i < line; i++) {
      const next = text.indexOf("\n", start);
      if (next < 0) return text.length;
      start = next + 1;
    }
    const end = text.indexOf("\n", start);
    return Math.min(start + character, end < 0 ? text.length : end);
  }

  // a range of the session's ([line, character, line, character]) as offsets
  function offsetsOf(text, range) {
    return [offsetOf(text, range[0], range[1]), offsetOf(text, range[2], range[3])];
  }

  // whether the letters of typed are in label in their order
  function fuzzy(typed, label) {
    let i = 0;
    for (let j = 0; j < label.length && i < typed.length; j++) {
      if (label[j] === typed[i]) i++;
    }
    return i === typed.length;
  }

  // ---------------------------------------------------------------- the language

  // What an editor knows about the code: asked of the notebook's session,
  // which asks slang's language server (notebook/language). A question
  // carries the cell as it is now.
  class Language {
    constructor(nb) {
      this.nb = nb;
      this.on = true;
      this.seq = 0;
      this.waiting = new Map();
    }

    // asks about a place in a cell (or about the notebook); the answer,
    // or null when there is none to be had
    // (always: also where there is no language server; the session answers
    // some questions itself)
    ask(method, cell, offset, more, always) {
      if ((!this.on && !always) || !this.nb.loaded) return Promise.resolve(null);
      const m = Object.assign({ op: "language", method: method, seq: ++this.seq }, more || {});
      if (cell) {
        this.nb.syncOthers(cell);
        m.id = cell.id;
        m.source = cell.source;
        cell.sent = cell.source;
        if (offset != null) Object.assign(m, positionOf(cell.source, offset));
      }
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { this.waiting.delete(m.seq); resolve(null); }, 15000);
        this.waiting.set(m.seq, { resolve: resolve, reject: reject, timer: timer });
        this.nb.send(m);
      });
    }

    answer(m) {
      const w = this.waiting.get(m.seq);
      if (!w) return;
      this.waiting.delete(m.seq);
      clearTimeout(w.timer);
      if (m.unavailable) { this.on = false; w.resolve(null); }
      else if (m.error) w.reject(new Error(m.error));
      else w.resolve(m.result == null ? null : m.result);
    }
  }

  // a card over the page, at a place of some text
  class Card {
    constructor(kind) {
      this.el = h("div", { class: "nb-card nb-" + kind, hidden: true });
      document.body.append(this.el);
      this.open = false;
    }

    // box: {left, top, bottom} in the window; above: over the line, not under
    show(box, above) {
      const el = this.el;
      el.hidden = false;
      this.open = true;
      const width = el.offsetWidth;
      const height = el.offsetHeight;
      const left = Math.max(8, Math.min(box.left, document.documentElement.clientWidth - width - 8));
      const room = innerHeight - box.bottom;
      const over = above ? box.top > height + 12 : room < height + 12 && box.top > room;
      el.style.left = (left + scrollX) + "px";
      el.style.top = ((over ? box.top - height - 6 : box.bottom + 6) + scrollY) + "px";
    }

    hide() {
      this.el.hidden = true;
      this.open = false;
    }
  }

  const KIND_LETTER = { function: "ƒ", method: "ƒ", field: "f", variable: "v", module: "M", property: "p", keyword: "k", section: "§", heading: "#" };

  function kindBadge(kind) {
    return h("span", { class: "nb-kind k-" + kind, "aria-hidden": "true" }, KIND_LETTER[kind] || "·");
  }

  // The editor's help in a notebook: what can follow (completion), what
  // is under the mouse (hover), the call being written (signature), where
  // a name is defined and used, renaming, formatting.
  class Assist {
    constructor(nb) {
      this.nb = nb;
      this.language = nb.language;
      this.hover = new Card("hover");
      this.list = new Card("complete");
      this.sig = new Card("signature");
      this.panel = new Card("panel");
      this.completion = null;
      this.completeSeq = 0;
      this.hoverSeq = 0;
      this.sigSeq = 0;
      this.docs = new Map();
      this.hover.el.addEventListener("mouseenter", () => clearTimeout(this.hoverGone));
      this.hover.el.addEventListener("mouseleave", () => this.hideHoverSoon());
      document.addEventListener("selectionchange", () => {
        const el = document.activeElement;
        if (el && el.editor) this.caretMoved(el.editor);
      });
      document.addEventListener("mousedown", (e) => {
        if (this.panel.open && !this.panel.el.contains(e.target)) this.panel.hide();
      });
    }

    // ---- what is under the mouse

    mouse(editor, e) {
      if (editor.cell.type !== "code" || e.buttons) return;
      clearTimeout(this.hoverTimer);
      clearTimeout(this.hoverGone);
      const x = e.clientX;
      const y = e.clientY;
      const on = this.hovering;
      if (on && on.editor === editor && on.boxes.some((r) => x >= r.left - 3 && x <= r.right + 3 && y >= r.top - 2 && y <= r.bottom + 6)) return;
      this.hoverTimer = setTimeout(() => this.showHover(editor, x, y), on ? 180 : 380);
    }

    mouseLeft() {
      clearTimeout(this.hoverTimer);
      this.hideHoverSoon();
    }

    hideHoverSoon() {
      clearTimeout(this.hoverGone);
      this.hoverGone = setTimeout(() => this.hideHover(), 260);
    }

    hideHover() {
      clearTimeout(this.hoverTimer);
      this.hoverSeq++;
      this.hovering = null;
      this.hover.hide();
    }

    showHover(editor, x, y) {
      const offset = editor.offsetAt(x, y);
      if (offset == null || this.list.open || this.panel.open) { this.hideHover(); return; }
      const text = editor.value;
      const [from, to] = wordAt(text, offset);
      const problems = editor.diagnostics.filter((d) => d.from <= offset && offset <= d.to);
      if (from === to && !problems.length) { this.hideHover(); return; }
      const span = from < to ? [from, to] : [problems[0].from, problems[0].to];
      const boxes = editor.rects(span[0], span[1]);
      if (!boxes.some((r) => x >= r.left - 3 && x <= r.right + 3 && y >= r.top - 2 && y <= r.bottom + 2)) {
        this.hideHover();
        return;
      }
      const seq = ++this.hoverSeq;
      const show = (answer) => {
        const parts = problems.map((d) => h("div", { class: "nb-problem " + d.severity }, d.message));
        if (answer && answer.html) {
          parts.push(h("div", { class: "nb-md nb-doc", html: answer.html }));
          const act = (label, title, f) => h("button", {
            title: title,
            onclick: () => { this.hideHover(); f(); },
          }, label);
          parts.push(h("div", { class: "nb-actions" },
            act("Definition", "Where it is defined (" + MOD + "+B, or " + MOD + "+click)", () => this.definition(editor, offset)),
            act("Uses", "Where it is used (shift+F12)", () => this.references(editor, offset)),
            act("Rename", "Rename it in every cell (F2)", () => this.rename(editor, offset))));
        }
        if (!parts.length) { this.hideHover(); return; }
        this.hover.el.replaceChildren(...parts);
        this.hovering = { editor: editor, boxes: boxes };
        this.hover.show(boxes[0]);
      };
      if (problems.length) show(null);
      if (from < to) {
        this.language.ask("hover", editor.cell, offset).then((answer) => {
          if (seq === this.hoverSeq && (answer || !problems.length)) show(answer);
        }, () => {});
      }
    }

    // ---- what can follow

    // the text changed by typing: inserted is what came in ("" when
    // something went)
    typed(editor, inserted) {
      this.hideHover();
      if (this.accepting || editor.cell.type !== "code" || !this.language.on) return;
      if (document.activeElement !== editor.area) return;
      const area = editor.area;
      const caret = area.selectionStart;
      if (caret !== area.selectionEnd) { this.closeCompletion(); return; }
      const text = area.value;
      const last = inserted.length === 1 ? inserted : "";
      const [from] = wordAt(text, caret);
      const word = text.slice(from, caret);
      const open = this.completion && this.completion.editor === editor;
      const trigger = last !== "" && ".:\"/{,".indexOf(last) >= 0 ? last : null;
      const typing = last !== "" && isWordChar(last) && /^[A-Za-z_]/.test(word);
      if (last === "(" || last === "," || this.sig.open) this.signatureSoon(editor);
      if (trigger || typing || (open && inserted === "" && caret >= this.completion.from)) {
        // a name that is being made up is not completed
        if (typing && !open && /\b(local|func|global)\s+$/.test(text.slice(Math.max(0, from - 16), from))) return;
        this.complete(editor, trigger);
      } else {
        this.closeCompletion();
      }
    }

    complete(editor, trigger) {
      if (!this.language.on) return;
      const area = editor.area;
      const caret = area.selectionStart;
      const text = area.value;
      const seq = ++this.completeSeq;
      this.language.ask("complete", editor.cell, caret, trigger ? { trigger: trigger } : null).then((items) => {
        if (seq !== this.completeSeq || document.activeElement !== area || area.value !== text) return;
        if (!items || !items.length) { this.closeCompletion(); return; }
        this.completion = { editor: editor, items: items, index: 0, from: caret, shown: [] };
        this.narrow();
      }, () => this.closeCompletion());
      // until the answer comes: what there is, narrowed by what was typed
      if (this.completion && this.completion.editor === editor) this.narrow();
    }

    // the items that fit what is written before the caret, the best first
    narrow() {
      const c = this.completion;
      const area = c.editor.area;
      const text = area.value;
      const caret = area.selectionStart;
      const [from] = wordAt(text, caret);
      c.from = from;
      const fits = [];
      for (const item of c.items) {
        let start = from;
        if (item.edit) start = Math.min(offsetsOf(text, item.edit.range)[0], caret);
        const typed = text.slice(start, caret).toLowerCase();
        const label = item.label.toLowerCase();
        let score;
        if (label.startsWith(typed)) score = label === typed ? -1 : 0;
        else if (typed.length >= 2 && !item.edit && label[0] === typed[0] && fuzzy(typed, label)) score = 1;
        else continue;
        fits.push({ item: item, score: score, start: start });
      }
      fits.sort((a, b) => a.score - b.score || (a.item.sort < b.item.sort ? -1 : a.item.sort > b.item.sort ? 1 : 0));
      // the word as it stands is all there is: nothing to choose
      const only = fits.length === 1 ? fits[0] : null;
      if (!fits.length || (only && !only.item.insert && only.item.label === text.slice(only.start, caret))) {
        this.closeCompletion();
        return;
      }
      c.shown = fits.slice(0, 150);
      c.index = 0;
      this.showCompletion();
    }

    showCompletion() {
      const c = this.completion;
      const rows = c.shown.map((fit, i) => {
        const item = fit.item;
        return h("div", {
          class: "nb-row" + (i === c.index ? " on" : ""), role: "option",
          onmousedown: (e) => { e.preventDefault(); this.accept(i); },
        }, kindBadge(item.kind), h("span", { class: "nb-label" }, item.label),
          item.detail && item.detail !== item.label ? h("span", { class: "nb-detail" }, item.detail) : null);
      });
      c.rows = rows;
      c.docEl = h("div", { class: "nb-md nb-doc", hidden: true });
      this.list.el.replaceChildren(h("div", { class: "nb-rows", role: "listbox" }, rows), c.docEl);
      this.list.show(c.editor.caretBox(c.from));
      this.showDoc();
    }

    // what the chosen item says about itself, under the list
    showDoc() {
      const c = this.completion;
      const item = c.shown[c.index].item;
      const el = c.docEl;
      if (!item.doc) { el.hidden = true; return; }
      const put = (html) => {
        if (this.completion === c && c.shown[c.index] && c.shown[c.index].item === item) {
          el.innerHTML = html;
          el.hidden = false;
        }
      };
      if (this.docs.has(item.doc)) { put(this.docs.get(item.doc)); return; }
      el.hidden = true;
      this.language.ask("doc", null, null, { text: item.doc }).then((r) => {
        if (r && r.html) { this.docs.set(item.doc, r.html); put(r.html); }
      }, () => {});
    }

    choose(index) {
      const c = this.completion;
      const n = c.shown.length;
      c.rows[c.index].classList.remove("on");
      c.index = Math.max(0, Math.min(n - 1, index));
      const row = c.rows[c.index];
      row.classList.add("on");
      row.scrollIntoView({ block: "nearest" });
      this.showDoc();
    }

    accept(index) {
      const c = this.completion;
      const fit = c.shown[index];
      const area = c.editor.area;
      const text = fit.item.edit ? fit.item.edit.text : (fit.item.insert || fit.item.label);
      this.closeCompletion();
      this.accepting = true;
      try {
        c.editor.insert(text, fit.start, area.selectionStart);
      } finally {
        this.accepting = false;
      }
    }

    closeCompletion() {
      this.completeSeq++;
      this.completion = null;
      this.list.hide();
    }

    // ---- the call being written

    signatureSoon(editor) {
      clearTimeout(this.sigTimer);
      this.sigTimer = setTimeout(() => this.signature(editor), 90);
    }

    signature(editor) {
      const area = editor.area;
      const caret = area.selectionStart;
      const seq = ++this.sigSeq;
      this.language.ask("signature", editor.cell, caret).then((r) => {
        if (seq !== this.sigSeq || document.activeElement !== area) return;
        if (!r) { this.sig.hide(); return; }
        const label = r.label;
        const p = r.parameters[r.active];
        const line = Array.isArray(p)
          ? [label.slice(0, p[0]), h("b", null, label.slice(p[0], p[1])), label.slice(p[1])]
          : [label];
        this.sig.el.replaceChildren(h("div", { class: "nb-sig" }, line),
          r.html ? h("div", { class: "nb-md nb-doc", html: r.html }) : null);
        this.sig.show(editor.caretBox(area.selectionStart), true);
      }, () => this.sig.hide());
    }

    closeSignature() {
      clearTimeout(this.sigTimer);
      this.sigSeq++;
      this.sig.hide();
    }

    // ---- where the caret is

    caretMoved(editor) {
      if (editor.cell.type !== "code") return;
      const area = editor.area;
      const c = this.completion;
      if (c && c.editor === editor && (area.selectionStart < c.from || area.selectionStart !== area.selectionEnd)) {
        this.closeCompletion();
      }
      if (this.sig.open) this.signatureSoon(editor);
      clearTimeout(this.caretTimer);
      this.caretTimer = setTimeout(() => this.occurrences(editor), 220);
    }

    // the other places of the name the caret is in, marked in every cell
    occurrences(editor) {
      const area = editor.area;
      const caret = area.selectionStart;
      const text = area.value;
      const [from, to] = wordAt(text, caret);
      const seq = this.occSeq = (this.occSeq || 0) + 1;
      if (document.activeElement !== area || caret !== area.selectionEnd || from === to || !/^[A-Za-z_]/.test(text.slice(from, to))) {
        this.nb.setOccurrences([]);
        return;
      }
      this.language.ask("occurrences", editor.cell, caret).then((list) => {
        if (seq === this.occSeq && area.value === text) this.nb.setOccurrences(list || []);
      }, () => {});
    }

    blurred(editor) {
      // (a click on a card takes the focus for a moment)
      setTimeout(() => {
        if (document.activeElement === editor.area) return;
        if (this.completion && this.completion.editor === editor) this.closeCompletion();
        this.closeSignature();
        if (!this.panel.el.contains(document.activeElement)) this.nb.setOccurrences([]);
      }, 0);
    }

    // ---- keys in an editor: true when the key was this help's

    key(editor, e) {
      const mod = e.metaKey || e.ctrlKey;
      const c = this.completion;
      if (c && c.editor === editor && this.list.open && !mod && !e.altKey) {
        const page = 7;
        let took = true;
        if (e.key === "ArrowDown") this.choose(c.index + 1 >= c.shown.length ? 0 : c.index + 1);
        else if (e.key === "ArrowUp") this.choose(c.index === 0 ? c.shown.length - 1 : c.index - 1);
        else if (e.key === "PageDown") this.choose(c.index + page);
        else if (e.key === "PageUp") this.choose(c.index - page);
        else if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") this.accept(c.index);
        else if (e.key === "Escape") this.closeCompletion();
        else took = false;
        if (took) { e.preventDefault(); return true; }
      }
      if (e.key === "Escape" && (this.sig.open || this.panel.open || this.hover.open)) {
        e.preventDefault();
        this.closeSignature();
        this.panel.hide();
        this.hideHover();
        return true;
      }
      if (editor.cell.type !== "code") return false;
      const caret = editor.area.selectionStart;
      let took = true;
      if ((e.key === " " && e.ctrlKey) || (e.code === "KeyI" && mod && !e.shiftKey && !e.altKey)) this.complete(editor, null);
      else if ((e.code === "KeyB" && mod && !e.shiftKey && !e.altKey) || (e.key === "F12" && !e.shiftKey)) this.definition(editor, caret);
      else if (e.key === "F12" && e.shiftKey) this.references(editor, caret);
      else if (e.key === "F2") this.rename(editor, caret);
      else if (e.code === "KeyF" && e.altKey && e.shiftKey && !mod) this.format(editor.cell);
      else took = false;
      if (took) e.preventDefault();
      return took;
    }

    // ---- where a name is defined, and used

    definition(editor, offset) {
      this.language.ask("definition", editor.cell, offset).then((places) => {
        if (!places || !places.length) { toast("There is no definition to go to here.", 2600); return; }
        const at = places[0];
        if (at.id) this.nb.reveal(at.id, at.range);
        else this.peek(editor, offset, at);
      }, (e) => toast(e.message));
    }

    // a place in a file, shown where one asked: the lines around it
    peek(editor, offset, at) {
      const [from, to] = wordAt(editor.value, offset);
      const code = h("pre", { class: "nb-peek-code" }, h("code", { html: at.html || escapeHtml(at.text || "") }));
      if (at.html != null) {
        const mark = h("div", { class: "nb-peek-mark" });
        mark.style.top = "calc(8px + " + (at.range[0] - at.first) + " * 12.5px * 1.55)";
        code.prepend(mark);
      }
      this.panel.el.replaceChildren(
        h("div", { class: "nb-panel-head" },
          h("span", { class: "nb-path", title: at.path }, at.shown + ":" + (at.range[0] + 1)),
          h("button", { title: "Close (escape)", onclick: () => this.closePanel(editor) }, "Close")),
        code);
      this.panel.show(editor.rects(from, Math.max(to, from + 1))[0] || editor.caretBox(offset));
      const mark = code.querySelector(".nb-peek-mark");
      if (mark) code.scrollTop = Math.max(0, mark.offsetTop - 60);
    }

    closePanel(editor) {
      this.panel.hide();
      if (editor) editor.area.focus({ preventScroll: true });
    }

    references(editor, offset) {
      const [from, to] = wordAt(editor.value, offset);
      const name = editor.value.slice(from, to);
      this.language.ask("references", editor.cell, offset).then((places) => {
        if (!places || !places.length) { toast("No uses found.", 2600); return; }
        const rows = places.map((at) => {
          if (at.id) {
            const cell = this.nb.byId.get(at.id);
            const n = this.nb.cells.indexOf(cell) + 1;
            const line = cell ? cell.source.split("\n")[at.range[0]] || "" : "";
            return h("button", {
              class: "nb-place", onclick: () => { this.panel.hide(); this.nb.reveal(at.id, at.range); },
            }, h("span", { class: "nb-where" }, "cell " + n + ", line " + (at.range[0] + 1)),
              h("code", null, line.trim()));
          }
          return h("div", { class: "nb-place", title: at.path },
            h("span", { class: "nb-where" }, at.shown + ":" + (at.range[0] + 1)), h("code", null, at.text || ""));
        });
        this.panel.el.replaceChildren(
          h("div", { class: "nb-panel-head" },
            h("span", null, places.length + (places.length === 1 ? " place has " : " places have "), h("code", null, name)),
            h("button", { title: "Close (escape)", onclick: () => this.closePanel(editor) }, "Close")),
          h("div", { class: "nb-places" }, rows));
        this.panel.show(editor.rects(from, Math.max(to, from + 1))[0] || editor.caretBox(offset));
      }, (e) => toast(e.message));
    }

    // ---- renaming

    rename(editor, offset) {
      this.language.ask("prepare_rename", editor.cell, offset).then((r) => {
        if (!r) { toast("There is no name to rename here.", 2600); return; }
        const [from] = offsetsOf(editor.value, r.range);
        const input = h("input", {
          type: "text", value: r.name, spellcheck: "false", autocapitalize: "off", autocomplete: "off",
          "aria-label": "The new name of " + r.name,
        });
        const done = () => this.closePanel(editor);
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            const name = input.value.trim();
            done();
            if (name !== "" && name !== r.name) this.applyRename(editor, from, name);
          } else if (e.key === "Escape") {
            e.preventDefault();
            done();
          }
          e.stopPropagation();
        });
        this.panel.el.replaceChildren(h("div", { class: "nb-rename" }, input,
          h("span", { class: "nb-hint" }, "enter renames it in every cell")));
        this.panel.show(editor.caretBox(from));
        input.focus();
        input.select();
      }, (e) => toast(e.message));
    }

    applyRename(editor, offset, name) {
      this.language.ask("rename", editor.cell, offset, { name: name }).then((r) => {
        if (!r) return;
        let n = 0;
        for (const [id, edits] of Object.entries(r.changes || {})) {
          const cell = this.nb.byId.get(id);
          if (cell) { cell.editor.applyEdits(edits); n += edits.length; }
        }
        toast(n + (n === 1 ? " place renamed." : " places renamed."), 2600);
      }, (e) => toast(e.message));
    }

    // ---- formatting

    format(cell) {
      if (cell.type !== "code") return;
      this.language.ask("format", cell, null).then((edits) => {
        if (edits == null) return;
        if (!edits.length) {
          toast(cell.editor.diagnostics.some((d) => d.severity === "error")
            ? "Not formatted: the code does not parse yet."
            : "The code is formatted already.", 2600);
          return;
        }
        cell.editor.applyEdits(edits);
      }, (e) => toast(e.message));
    }
  }

  const MOD = /Mac|iPhone|iPad/.test(navigator.platform) ? "cmd" : "ctrl";

  // ---------------------------------------------------------------- the editor

  // A textarea over a block of the same text, highlighted: the textarea
  // takes the typing, the block shows the colours.
  class Editor {
    constructor(cell) {
      this.cell = cell;
      this.spans = [];
      this.code = h("code");
      this.pre = h("pre", { "aria-hidden": "true" }, this.code);
      this.area = h("textarea", {
        spellcheck: "false", autocapitalize: "off", autocomplete: "off", autocorrect: "off",
        "aria-label": cell.type === "code" ? "Code" : "Text (Markdown)",
      });
      this.mark = null;
      // under the code, the same text again: it carries what is marked in
      // it (mistakes underlined, the uses of the name at the caret)
      this.marks = h("pre", { class: "marks", "aria-hidden": "true" });
      this.diagnostics = [];
      this.occurrences = [];
      this.el = h("div", { class: "editor" }, this.marks, this.pre, this.area);
      this.last = "";
      const assist = cell.nb.assist;
      this.area.editor = this;
      this.area.addEventListener("input", () => this.changed());
      this.area.addEventListener("keydown", (e) => this.key(e));
      this.area.addEventListener("focus", () => cell.nb.editing(cell));
      this.area.addEventListener("blur", () => { cell.blurred(); assist.blurred(this); });
      this.area.addEventListener("mousemove", (e) => assist.mouse(this, e));
      this.area.addEventListener("mouseleave", () => assist.mouseLeft());
      this.area.addEventListener("mousedown", () => { assist.hideHover(); assist.closeCompletion(); });
      this.area.addEventListener("click", (e) => {
        if ((e.metaKey || e.ctrlKey) && cell.type === "code") assist.definition(this, this.area.selectionStart);
      });
    }

    get value() { return this.area.value; }

    set(text, spans) {
      this.area.value = text;
      this.last = text;
      this.spans = spans || [];
      this.diagnostics = [];
      this.occurrences = [];
      this.paint();
    }

    // what the language server found wrong: {range, severity, message}s
    setDiagnostics(items) {
      const text = this.area.value;
      this.diagnostics = items.map((d) => {
        let [from, to] = offsetsOf(text, d.range);
        // something to underline, also at the end of a line
        if (to <= from) {
          if (from < text.length && text[from] !== "\n") to = from + 1;
          else if (from > 0 && text[from - 1] !== "\n") from = from - 1;
        }
        return { from: from, to: Math.max(to, from), severity: d.severity, message: d.message, unused: d.unused === true };
      });
      this.el.classList.toggle("has-error", this.diagnostics.some((d) => d.severity === "error"));
      this.paintMarks();
    }

    // the uses of the name at the caret that are in this cell
    setOccurrences(items) {
      if (!items.length && !this.occurrences.length) return;
      const text = this.area.value;
      this.occurrences = items.map((o) => {
        const [from, to] = offsetsOf(text, o.range);
        return { from: from, to: to, write: o.write === true };
      });
      this.paintMarks();
    }

    paintMarks() {
      const text = this.area.value;
      const marked = [];
      if (this.cell.type === "code") {
        for (const d of this.diagnostics) marked.push([d.from, d.to, "d-" + d.severity + (d.unused ? " d-unused" : "")]);
        for (const o of this.occurrences) marked.push([o.from, o.to, o.write ? "o-write" : "o-read"]);
      }
      if (!marked.length) { this.marks.textContent = ""; return; }
      const points = new Set([0, text.length]);
      for (const m of marked) {
        m[0] = Math.max(0, Math.min(text.length, m[0]));
        m[1] = Math.max(m[0], Math.min(text.length, m[1]));
        points.add(m[0]);
        points.add(m[1]);
      }
      const cuts = Array.from(points).sort((a, b) => a - b);
      let html = "";
      for (let i = 0; i + 1 < cuts.length; i++) {
        const a = cuts[i];
        const b = cuts[i + 1];
        const classes = marked.filter((m) => m[0] <= a && m[1] >= b && m[1] > m[0]).map((m) => m[2]);
        const piece = escapeHtml(text.slice(a, b));
        html += classes.length ? '<span class="' + classes.join(" ") + '">' + piece + "</span>" : piece;
      }
      this.marks.innerHTML = html + "\n";
    }

    // ---- where the text is on the page

    // the text node of the painted code that has a place, and the place in
    // it (end: for the end of a stretch)
    locate(offset, end) {
      const walker = document.createTreeWalker(this.code, NodeFilter.SHOW_TEXT);
      let last = null;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (offset < node.length || (end && offset === node.length)) return [node, offset];
        offset -= node.length;
        last = node;
      }
      return last ? [last, last.length] : [this.code, 0];
    }

    // the boxes of a stretch of the text, in the window (one a line)
    rects(from, to) {
      const range = document.createRange();
      const a = this.locate(from, false);
      const b = this.locate(Math.max(to, from), true);
      range.setStart(a[0], a[1]);
      range.setEnd(b[0], b[1]);
      return Array.from(range.getClientRects()).filter((r) => r.height > 0);
    }

    // where a place of the text is: {left, top, bottom}
    caretBox(offset) {
      // (the painted code ends in a line break, so there is always a
      // character at a place)
      let r = this.rects(offset, offset + 1)[0];
      if (r) return { left: r.left, top: r.top, bottom: r.bottom };
      r = offset > 0 ? this.rects(offset - 1, offset).pop() : null;
      if (r) return { left: r.right, top: r.top, bottom: r.bottom };
      const box = this.pre.getBoundingClientRect();
      return { left: box.left + 14, top: box.top + 10, bottom: box.top + 30 };
    }

    // the place of the text at a point of the window, or null
    offsetAt(x, y) {
      // the textarea is over the painted code: out of the way for a moment
      this.el.classList.add("probing");
      let node = null;
      let offset = 0;
      try {
        if (document.caretPositionFromPoint) {
          const p = document.caretPositionFromPoint(x, y);
          if (p) { node = p.offsetNode; offset = p.offset; }
        } else if (document.caretRangeFromPoint) {
          const r = document.caretRangeFromPoint(x, y);
          if (r) { node = r.startContainer; offset = r.startOffset; }
        }
      } finally {
        this.el.classList.remove("probing");
      }
      if (node === this.area) return Math.min(offset, this.area.value.length);
      if (!node || node.nodeType !== 3 || !this.code.contains(node)) return null;
      const walker = document.createTreeWalker(this.code, NodeFilter.SHOW_TEXT);
      let at = 0;
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n === node) return Math.min(at + offset, this.area.value.length);
        at += n.length;
      }
      return null;
    }

    // edits of the session's ({range, text}s) made to the text
    applyEdits(edits) {
      const area = this.area;
      const text = area.value;
      const caret = area.selectionStart;
      const focused = document.activeElement === area;
      const list = edits.map((e) => {
        const [from, to] = offsetsOf(text, e.range);
        return { from: from, to: to, text: e.text };
      }).sort((a, b) => b.from - a.from);
      if (list.length === 1 && focused) {
        // (as typing would, so that it can be undone)
        this.insert(list[0].text, list[0].from, list[0].to);
      } else {
        for (const e of list) area.setRangeText(e.text, e.from, e.to, "preserve");
        this.changed();
      }
      if (focused) {
        const at = Math.min(caret, area.value.length);
        area.setSelectionRange(at, at);
      }
    }

    setSpans(spans) {
      this.spans = spans;
      this.paint();
    }

    paint() {
      const text = this.area.value;
      let html = "";
      let pos = 0;
      if (this.cell.type === "code") {
        for (const [start, stop, kind] of this.spans) {
          if (start < pos || stop > text.length) continue;
          html += escapeHtml(text.slice(pos, start)) +
            '<span class="t-' + kind + '">' + escapeHtml(text.slice(start, stop)) + "</span>";
          pos = stop;
        }
      }
      // (a last empty line needs something to have a height)
      this.code.innerHTML = html + escapeHtml(text.slice(pos)) + "\n";
      this.paintMarks();
    }

    // the typing changed the text: the colours before the change stay,
    // those after it move with their text, until the server's arrive
    changed() {
      const text = this.area.value;
      const old = this.last;
      if (text === old) return;
      let a = 0;
      const most = Math.min(old.length, text.length);
      while (a < most && old.charCodeAt(a) === text.charCodeAt(a)) a++;
      let b = 0;
      while (b < most - a && old.charCodeAt(old.length - 1 - b) === text.charCodeAt(text.length - 1 - b)) b++;
      const delta = text.length - old.length;
      const kept = [];
      for (const [start, stop, kind] of this.spans) {
        if (stop <= a) kept.push([start, stop, kind]);
        else if (start >= old.length - b) kept.push([start + delta, stop + delta, kind]);
      }
      this.spans = kept;
      // what was marked moves with its text too; what the change touched
      // is no longer marked
      const edge = old.length - b;
      this.diagnostics = this.diagnostics.filter((d) => d.to <= a || d.from >= edge);
      for (const d of this.diagnostics) {
        if (d.from >= edge) { d.from += delta; d.to += delta; }
      }
      this.last = text;
      this.setMark(null);
      this.paint();
      this.cell.nb.setOccurrences([]);
      this.cell.edited();
      this.cell.nb.assist.typed(this, text.slice(a, text.length - b));
    }

    // replaces the selection (or a range) as typing would, so undo works
    insert(text, from, to) {
      const area = this.area;
      if (from != null) area.setSelectionRange(from, to);
      if (!document.execCommand || !document.execCommand("insertText", false, text)) {
        area.setRangeText(text, area.selectionStart, area.selectionEnd, "end");
        this.changed();
      }
    }

    key(e) {
      const area = this.area;
      const nb = this.cell.nb;
      const mod = e.metaKey || e.ctrlKey;
      if (nb.assist.key(this, e)) return;
      if (e.key === "Enter" && e.shiftKey) {
        e.preventDefault();
        nb.runAndAdvance(this.cell);
      } else if (e.key === "Enter" && mod) {
        e.preventDefault();
        nb.runStay(this.cell);
      } else if (e.key === "s" && mod) {
        e.preventDefault();
        nb.saveNow();
      } else if (e.key === "Escape") {
        e.preventDefault();
        area.blur();
        nb.select(this.cell);
      } else if (e.key === "Tab" && !mod && !e.altKey) {
        e.preventDefault();
        this.indent(e.shiftKey);
      } else if (e.key === "Enter" && !e.altKey && this.cell.type === "code") {
        e.preventDefault();
        this.newline();
      } else if (e.key === "}" && this.cell.type === "code") {
        // a closing brace on a line of its own steps back
        const at = area.selectionStart;
        const start = area.value.lastIndexOf("\n", at - 1) + 1;
        const before = area.value.slice(start, at);
        if (at === area.selectionEnd && before.length >= 2 && before.trim() === "") {
          e.preventDefault();
          this.insert("}", at - 2, at);
        }
      } else if (e.key === "ArrowUp" && !e.shiftKey && area.selectionEnd === 0) {
        if (nb.focusNeighbour(this.cell, -1)) e.preventDefault();
      } else if (e.key === "ArrowDown" && !e.shiftKey && area.selectionStart === area.value.length) {
        if (nb.focusNeighbour(this.cell, 1)) e.preventDefault();
      }
    }

    newline() {
      const area = this.area;
      const text = area.value;
      const at = area.selectionStart;
      const start = text.lastIndexOf("\n", at - 1) + 1;
      const line = text.slice(start, at);
      let indent = line.match(/^[ \t]*/)[0];
      const opens = /[{(\[]\s*$/.test(line);
      const closes = /^[})\]]/.test(text.slice(area.selectionEnd));
      if (opens && closes) {
        this.insert("\n" + indent + "  \n" + indent);
        const caret = at + 1 + indent.length + 2;
        area.setSelectionRange(caret, caret);
      } else {
        this.insert("\n" + indent + (opens ? "  " : ""));
      }
    }

    indent(back) {
      const area = this.area;
      const text = area.value;
      const from = area.selectionStart;
      const to = area.selectionEnd;
      if (from === to && !back) {
        this.insert("  ");
        return;
      }
      const start = text.lastIndexOf("\n", from - 1) + 1;
      const lines = text.slice(start, to).split("\n");
      const changedLines = lines.map((line) => back ? line.replace(/^ {1,2}/, "") : "  " + line);
      const first = changedLines[0].length - lines[0].length;
      const all = changedLines.join("\n");
      this.insert(all, start, to);
      area.setSelectionRange(Math.max(start, from + first), start + all.length);
    }

    setMark(line) {
      if (this.mark) { this.mark.remove(); this.mark = null; }
      if (line == null) return;
      this.mark = h("div", { class: "mark" });
      const lineHeight = parseFloat(getComputedStyle(this.pre).lineHeight) || 20;
      this.mark.style.top = (10 + (line - 1) * lineHeight) + "px";
      this.el.insertBefore(this.mark, this.pre);
    }

    focus(at) {
      this.area.focus({ preventScroll: true });
      if (at === "start") this.area.setSelectionRange(0, 0);
      else if (at === "end") this.area.setSelectionRange(this.area.value.length, this.area.value.length);
      this.cell.el.scrollIntoView({ block: "nearest" });
    }
  }

  // ---------------------------------------------------------------- a cell

  class Cell {
    constructor(nb, view) {
      this.nb = nb;
      this.id = view.id;
      this.type = view.type;
      this.outputs = [];
      this.state = "idle";
      this.count = null;
      this.seq = 0;
      this.streams = false;
      // the text the session has of this cell
      this.sent = view.source || "";
      this.build(view);
    }

    get source() { return this.editor.value; }

    build(view) {
      const nb = this.nb;
      this.editor = new Editor(this);
      this.countEl = h("span", { class: "count" });
      this.runButton = h("button", {
        class: "run", title: "Run (shift+enter)", "aria-label": "Run this cell",
        onclick: () => nb.runStay(this),
      }, icon("play"));
      this.out = h("div", { class: "nb-out" });
      this.took = h("span", { class: "took" });
      this.rendered = h("div", {
        class: "rendered nb-md",
        ondblclick: () => this.edit(),
        onclick: () => nb.select(this),
      });
      this.typeButton = h("button", {
        title: "Change between code and text",
        onclick: () => nb.setType(this, this.type === "code" ? "markdown" : "code"),
      });
      const tools = h("div", { class: "cell-tools" },
        h("button", {
          class: "format", title: "Format the code (alt+shift+F)",
          onclick: () => nb.assist.format(this),
        }, "Format"),
        this.typeButton,
        h("button", { title: "Move up", "aria-label": "Move up", onclick: () => nb.move(this, -1) }, icon("up")),
        h("button", { title: "Move down", "aria-label": "Move down", onclick: () => nb.move(this, 1) }, icon("down")),
        h("button", { class: "danger", title: "Delete", "aria-label": "Delete this cell", onclick: () => nb.remove(this) }, icon("trash")));
      this.frame = h("div", { class: "frame" }, tools, this.editor.el, this.rendered, this.out, this.took);
      this.el = h("section", { class: "cell", "data-id": this.id },
        h("div", { class: "gutter" }, this.runButton, this.countEl), this.frame);
      this.el.addEventListener("mousedown", (e) => {
        if (e.target === this.el || e.target.classList.contains("gutter")) nb.select(this);
      });
      this.adder = nb.adder(this);
      this.editor.set(view.source || "", list(view.spans));
      this.setType(this.type);
      this.setRendered(view.html);
      this.setOutputs(list(view.outputs));
      this.setCount(view.count, view.ms);
      this.setState(view.state || "idle");
    }

    setType(type) {
      this.type = type;
      this.el.classList.toggle("code", type === "code");
      this.el.classList.toggle("markdown", type === "markdown");
      this.typeButton.textContent = type === "code" ? "Code" : "Text";
      this.editor.area.setAttribute("aria-label", type === "code" ? "Code" : "Text (Markdown)");
      this.editor.paint();
    }

    setRendered(html) {
      if (this.type !== "markdown") return;
      if (html == null || html.trim() === "") {
        this.rendered.classList.add("blank");
        this.rendered.textContent = "Empty text. Double-click to write.";
      } else {
        this.rendered.classList.remove("blank");
        this.rendered.innerHTML = html;
      }
    }

    setState(state) {
      this.state = state;
      this.el.classList.toggle("running", state === "running");
      this.el.classList.toggle("queued", state === "queued");
      this.runButton.title = state === "idle" ? "Run (shift+enter)" : state === "running" ? "Running" : "Waiting to run";
      if (state !== "idle") this.countEl.textContent = state === "running" ? "[*]" : "[ ]";
      else this.setCount(this.count, this.ms);
    }

    setCount(count, ms) {
      this.count = count;
      this.ms = ms;
      this.countEl.textContent = this.type === "code" && count != null ? "[" + count + "]" : "";
      this.took.textContent = ms == null ? "" : ms < 1000 ? Math.max(1, Math.round(ms)) + " ms" : (ms / 1000).toFixed(ms < 10000 ? 2 : 1) + " s";
    }

    // ---- what it showed

    setOutputs(outputs) {
      this.outputs = [];
      this.out.replaceChildren();
      for (const o of outputs) this.addOutput(o);
    }

    addOutput(o) {
      let el;
      if (o.type === "stream") {
        el = h("pre", { class: o.name === "stderr" ? "nb-stderr" : "nb-stdout" }, printed(o.text || ""));
      } else if (o.type === "error") {
        el = errorElement(this, o.error);
      } else {
        el = dataElement(o.data);
      }
      this.outputs.push({ o: o, el: el });
      this.out.append(el);
    }

    // an event of the kernel about this cell
    apply(e) {
      const kind = e.event;
      if (kind === "start" || kind === "clear") {
        this.setOutputs([]);
        this.editor.setMark(null);
        if (kind === "start") this.ms = null;
        if (kind === "clear") this.setCount(null, null);
      } else if (kind === "stream") {
        const last = this.outputs[this.outputs.length - 1];
        if (last && last.o.type === "stream" && last.o.name === e.name) {
          if (last.o.text.length < 400000) {
            last.o.text += e.text;
            // painted once a frame, however fast it prints
            if (!this.streams) {
              this.streams = true;
              requestAnimationFrame(() => {
                this.streams = false;
                const now = this.outputs[this.outputs.length - 1];
                for (const entry of this.outputs) {
                  if (entry.o.type === "stream") entry.el.textContent = printed(entry.o.text);
                }
                if (now && this.out.scrollHeight > this.out.clientHeight) this.out.scrollTop = this.out.scrollHeight;
              });
            }
          }
        } else {
          this.addOutput({ type: "stream", name: e.name, text: e.text });
        }
      } else if (kind === "display" || kind === "result") {
        this.addOutput({ type: kind, data: e.data });
      } else if (kind === "error") {
        this.addOutput({ type: "error", error: e.error });
        if (e.error && e.error.cell_line != null) this.editor.setMark(e.error.cell_line);
      } else if (kind === "done") {
        this.ms = e.ms;
      }
    }

    // ---- editing

    edited() {
      this.nb.changed();
      if (this.type === "code") {
        this.askTokens();
        this.nb.checkSoon(this);
      }
    }

    askTokens() {
      clearTimeout(this.tokenTimer);
      this.tokenTimer = setTimeout(() => {
        this.seq++;
        this.asked = this.source;
        this.nb.send({ op: "highlight", id: this.id, seq: this.seq, source: this.source });
      }, 120);
    }

    tokens(m) {
      if (m.seq === this.seq && this.asked === this.source) this.editor.setSpans(list(m.spans));
    }

    askRender() {
      this.seq++;
      this.nb.send({ op: "render", id: this.id, seq: this.seq, source: this.source });
    }

    edit(at) {
      this.el.classList.add("editing");
      this.editor.paint();
      this.editor.focus(at);
    }

    blurred() {
      this.el.classList.remove("editing");
      if (this.type === "markdown") this.askRender();
    }

    focusLine(line) {
      const text = this.source;
      let at = 0;
      for (let i = 1; i < line; i++) {
        const next = text.indexOf("\n", at);
        if (next < 0) break;
        at = next + 1;
      }
      this.edit();
      this.editor.area.setSelectionRange(at, at);
    }
  }

  // ---------------------------------------------------------------- a notebook

  class Notebook {
    constructor(path) {
      this.path = path;
      this.local = CONFIG !== null;
      this.kind = null;
      this.kinds = [];
      this.kernelId = 0;
      this.kernelHost = new KernelHost((e) => {
        if (this.local) this.toService({ kernel: e });
        else this.send({ op: "kernel_event", kernel: this.kernelId, e: e });
      });
      this.cells = [];
      this.byId = new Map();
      this.selected = null;
      this.loaded = false;
      this.dirty = false;
      // cells came, went or moved since the session was told
      this.structureDirty = false;
      this.checkSeq = 0;
      this.language = new Language(this);
      this.assist = new Assist(this);
      this.kernel = "none";
      this.retry = 500;
      this.lastD = 0;
      this.list = h("div", { class: "notebook" });
      this.banner = null;
      this.buildBar();
      main.replaceChildren(this.list);
      document.addEventListener("keydown", (e) => this.command(e));
      addEventListener("pagehide", () => this.flush());
      document.addEventListener("visibilitychange", () => { if (document.hidden) this.flush(); });
      if (this.local) this.startService();
      else this.connect();
    }

    buildBar() {
      this.setName(this.path);
      this.status = h("span", { class: "status", "data-kernel": "none" }, h("span", { class: "dot" }), h("span", { class: "text" }, "not started"));
      this.savedEl = h("span", { class: "saved" });
      this.stopButton = h("button", { class: "tool", title: "Stop the running cell", onclick: () => this.send({ op: "interrupt" }) }, icon("stop"), h("span", { class: "label" }, "Stop"));
      // where the cells run, when there is a choice
      this.kindSelect = h("select", {
        class: "tool kind", title: "Where the cells run", "aria-label": "Where the cells run", hidden: true,
        onchange: () => { this.flush(); this.send({ op: "kernel", kind: this.kindSelect.value }); },
      });
      const files = [];
      if (this.local) {
        files.push(
          h("button", { class: "tool", title: "A new, empty notebook", onclick: () => this.newNotebook() }, icon("new"), h("span", { class: "label" }, "New")),
          h("button", { class: "tool", title: "Open a notebook (a Markdown file) from this machine", onclick: () => this.openFile() }, icon("open"), h("span", { class: "label" }, "Open")),
          h("button", { class: "tool", title: "Save the notebook to a file on this machine", onclick: () => this.saveFile() }, icon("save"), h("span", { class: "label" }, "Save")));
        if (CONFIG.notebook) {
          files.push(h("button", {
            class: "tool", title: "The notebook as this page came with it; your changes to it are dropped",
            onclick: () => this.resetNotebook(),
          }, h("span", null, "Reset")));
        }
      }
      actions.replaceChildren(
        ...files,
        this.savedEl,
        this.kindSelect,
        this.status,
        h("button", { class: "tool primary", title: "Run every cell from the top", onclick: () => this.runAll() }, icon("play"), h("span", { class: "label" }, "Run all")),
        this.stopButton,
        h("button", {
          class: "tool", title: "Start the kernel over: the cells' state is forgotten",
          onclick: () => { this.flush(); this.send({ op: "restart" }); },
        }, icon("restart"), h("span", { class: "label" }, "Restart")),
        h("button", { class: "tool", title: "Take away what the cells showed", onclick: () => this.send({ op: "clear" }) }, h("span", null, "Clear")),
        h("button", { class: "tool", title: "The notebook's headings and what its code defines", onclick: () => this.toggleOutline() }, h("span", null, "Outline")),
        themeButton());
      this.setKernel("none", null);
    }

    setName(name) {
      this.path = name;
      setCrumbs(name, true);
      document.title = name.split("/").pop() + " - slang notebook";
    }

    setKernel(status, project) {
      this.kernel = status;
      const names = { none: "not started", starting: "starting", idle: "idle", busy: "running", dead: "ended", offline: "offline" };
      this.status.dataset.kernel = status;
      let text = names[status] || status;
      const where = this.kind === "wasm"
        ? "The cells run in this page (slang as WebAssembly): they see the notebook's project and nothing else of this machine. "
        : "";
      if (project) {
        const parts = project.split("/");
        text += " · " + (parts[parts.length - 2] || "project");
        this.status.title = where + "The cells run in the project " + project;
      } else {
        this.status.title = where + (status === "none" ? "The kernel starts when a cell is run" : "The cells run without a project file");
      }
      this.status.querySelector(".text").textContent = text;
      this.stopButton.disabled = status !== "busy";
    }

    // the kinds of kernel there are here, and the one this notebook has
    setKinds(kinds, kind) {
      if (kinds) this.kinds = kinds;
      if (kind) this.kind = kind;
      const labels = { process: "On this machine", wasm: "In the page" };
      this.kindSelect.replaceChildren(...this.kinds.map((k) => h("option", { value: k }, labels[k] || k)));
      this.kindSelect.value = this.kind || "";
      this.kindSelect.hidden = this.kinds.length < 2;
    }

    // ---- the connection

    connect() {
      const scheme = location.protocol === "https:" ? "wss://" : "ws://";
      const ws = new WebSocket(scheme + location.host + "/ws?path=" + encodeURIComponent(this.path));
      this.ws = ws;
      ws.onopen = () => { this.retry = 500; this.setBanner(null); };
      ws.onmessage = (e) => this.message(JSON.parse(e.data));
      ws.onclose = () => {
        if (this.gone) return;
        this.setKernel("offline", null);
        this.setBanner("The server does not answer. Trying again; if it was started anew, open the link it printed.");
        setTimeout(() => this.connect(), this.retry);
        this.retry = Math.min(this.retry * 2, 5000);
      };
    }

    send(m) {
      if (this.local) this.toService({ page: m });
      else if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(m));
    }

    // ---- without a server: the session is a worker of this page

    startService() {
      this.setBanner("Starting slang in this page ...");
      const said = [];
      this.service = new WasmVM({
        message: (text) => this.fromService(JSON.parse(text)),
        output: (name, text) => { said.push(text); console.warn(text); },
        exit: (code) => {
          this.gone = true;
          this.kernelHost.stop();
          this.setKernel("offline", null);
          this.setBanner("The notebook's worker ended. Load the page again. " + said.join("").slice(-400));
        },
      });
      this.service.start({
        args: ["slang", "run", "/pkg/notebook/bin/service_web.slang"], files: CONFIG.files, cwd: "/work",
      }).catch((e) => this.setBanner("slang did not start: " + e.message));
    }

    toService(m) {
      if (this.service) this.service.send(JSON.stringify(m));
    }

    fromService(m) {
      if (m.page) this.message(m.page);
      else if (m.kernel) this.kernelHost.handle(m.kernel);
      else if (m.timer) setTimeout(() => this.toService({ timer: m.timer.id }), m.timer.ms);
      else if (m.store) this.store(m.store);
      else if (m.ready) {
        this.setBanner(null);
        this.openDocument(this.draft() || CONFIG.notebook || this.blank(), null);
      }
    }

    // ---- without a server: the notebook is the page's to keep

    get draftKey() {
      return "slang-notebook:" + (CONFIG.key || "");
    }

    draft() {
      try {
        const d = JSON.parse(localStorage.getItem(this.draftKey) || "null");
        return d && typeof d.text === "string" ? d : null;
      } catch (e) {
        return null;
      }
    }

    blank() {
      return { name: "notebook.md", text: "# Untitled\n\n```slang\n\n```\n" };
    }

    // shows a notebook: {name, text, outputs}, and the file it is, if any
    openDocument(doc, handle) {
      this.handle = handle;
      this.latest = null;
      this.loaded = false;
      this.dirty = false;
      clearTimeout(this.syncTimer);
      this.kernelHost.stop();
      this.setName(doc.name || "notebook.md");
      this.savedEl.textContent = "";
      this.toService({ open: { name: this.path, text: doc.text, outputs: doc.outputs || null } });
    }

    // the session saved: the notebook goes to the browser's storage, and
    // to its file when it has one
    store(s) {
      this.latest = s;
      try {
        localStorage.setItem(this.draftKey, JSON.stringify(s));
      } catch (e) {
        // too much for the storage: the text alone
        try { localStorage.setItem(this.draftKey, JSON.stringify({ name: s.name, text: s.text })); } catch (e2) {}
      }
      if (this.handle) this.write(this.handle, s.text).catch((e) => toast("not saved to " + this.path + ": " + e.message));
    }

    async write(handle, text) {
      const out = await handle.createWritable();
      await out.write(text);
      await out.close();
    }

    newNotebook() {
      if (!this.handle && this.latest && !confirm("Start a new notebook? This one is only kept in this browser, and is replaced.")) return;
      try { localStorage.removeItem(this.draftKey); } catch (e) {}
      this.openDocument(this.blank(), null);
    }

    resetNotebook() {
      if (!confirm("Go back to the notebook as this page came with it? Your changes are dropped.")) return;
      try { localStorage.removeItem(this.draftKey); } catch (e) {}
      this.openDocument(CONFIG.notebook, null);
    }

    async openFile() {
      this.flush();
      if (window.showOpenFilePicker) {
        let handle;
        try {
          [handle] = await showOpenFilePicker({
            types: [{ description: "Notebooks (Markdown)", accept: { "text/markdown": [".md", ".markdown"] } }],
          });
        } catch (e) {
          return; // not chosen
        }
        const file = await handle.getFile();
        this.openDocument({ name: file.name, text: await file.text() }, handle);
        return;
      }
      // a browser without file handles: the file is read, and saving
      // downloads a copy
      const input = h("input", { type: "file", accept: ".md,.markdown,text/markdown" });
      input.onchange = async () => {
        const file = input.files[0];
        if (file) this.openDocument({ name: file.name, text: await file.text() }, null);
      };
      input.click();
    }

    // the notebook's text as it is now, from the session
    currentText() {
      this.sync();
      this.send({ op: "save" });
      return new Promise((resolve) => {
        const wait = (tries) => {
          if (this.latest || tries <= 0) resolve(this.latest ? this.latest.text : null);
          else setTimeout(() => wait(tries - 1), 50);
        };
        this.latest = null;
        wait(60);
      });
    }

    async saveFile() {
      const text = await this.currentText();
      if (text == null) { toast("The notebook is not loaded yet."); return; }
      try {
        if (!this.handle && window.showSaveFilePicker) {
          this.handle = await showSaveFilePicker({
            suggestedName: this.path,
            types: [{ description: "Notebooks (Markdown)", accept: { "text/markdown": [".md"] } }],
          });
          this.setName(this.handle.name);
        }
        if (this.handle) {
          await this.write(this.handle, text);
          this.savedEl.textContent = "Saved to " + this.path;
          return;
        }
      } catch (e) {
        if (e.name !== "AbortError") toast("not saved: " + e.message);
        return;
      }
      // no file handles here: a download
      const url = URL.createObjectURL(new Blob([text], { type: "text/markdown" }));
      const a = h("a", { href: url, download: this.path });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      this.savedEl.textContent = "Downloaded";
    }

    setBanner(text) {
      if (this.banner) { this.banner.remove(); this.banner = null; }
      if (text) {
        this.banner = h("div", { class: "banner" }, text);
        main.prepend(this.banner);
      }
    }

    message(m) {
      const cell = m.id != null ? this.byId.get(m.id) : null;
      switch (m.event) {
        case "notebook":
          if (this.loaded && this.dirty) {
            // we have edits the server has not: ours stay, its outputs come
            this.sync();
            for (const view of list(m.cells)) {
              const mine = this.byId.get(view.id);
              if (mine) {
                mine.setOutputs(list(view.outputs));
                mine.setCount(view.count, view.ms);
                mine.setState(view.state || "idle");
              }
            }
          } else {
            this.load(list(m.cells));
          }
          this.loaded = true;
          this.setKinds(list(m.kinds), m.kind);
          this.setKernel(m.kernel, m.project);
          this.language.on = m.language !== false;
          this.check(null);
          break;
        case "cells":
          this.reconcile(list(m.cells));
          break;
        case "cell":
          if (cell) {
            cell.apply(m.e);
            if (m.count != null) cell.count = m.count;
            if (m.state) cell.setState(m.state);
          }
          break;
        case "state":
          if (cell) cell.setState(m.state);
          break;
        case "kernel":
          this.setKinds(null, m.kind);
          this.setKernel(m.status, m.project);
          break;
        case "kernel_op":
          // the server's session asks something of the kernel in this page
          if (m.op && m.op.op === "start") this.kernelId = m.kernel;
          if (m.kernel === this.kernelId) this.kernelHost.handle(m.op);
          break;
        case "tokens":
          if (cell) cell.tokens(m);
          break;
        case "diagnostics":
          // what the language server found, in every code cell; the answer
          // to an older question than the last is out of date
          if (m.unavailable) { this.language.on = false; break; }
          if (m.seq != null && m.seq !== this.checkSeq) break;
          for (const [id, items] of Object.entries(m.cells || {})) {
            const c = this.byId.get(id);
            if (c && c.type === "code" && c.source === c.sent) c.editor.setDiagnostics(list(items));
          }
          this.refreshOutline();
          break;
        case "language":
          this.language.answer(m);
          break;
        case "rendered":
          if (cell && m.seq === cell.seq) cell.setRendered(m.html);
          break;
        case "saved":
          if (this.local) {
            this.savedEl.textContent = this.dirty ? "Edited" : this.handle ? "Saved to " + this.path : "Kept in this browser";
          } else {
            this.savedEl.textContent = this.dirty ? "Edited" : "Saved";
          }
          break;
        case "problem":
          if (m.fatal) { this.gone = true; this.setBanner(m.message); }
          else toast(m.message);
          break;
      }
    }

    // ---- the cells

    load(views) {
      this.cells = [];
      this.byId.clear();
      this.list.replaceChildren();
      for (const view of views) this.place(new Cell(this, view), this.cells.length);
      this.list.append(this.lastAdder());
      this.structureDirty = false;
      if (this.cells.length === 0) this.insert(0, "code");
    }

    // another page changed the cells: ours follow
    reconcile(views) {
      const focused = document.activeElement;
      const next = [];
      for (const view of views) {
        let cell = this.byId.get(view.id);
        if (!cell) {
          cell = new Cell(this, view);
        } else {
          if (cell.type !== view.type) cell.setType(view.type);
          if (cell.source !== view.source && cell.editor.area !== focused) {
            cell.editor.set(view.source, list(view.spans));
            cell.sent = view.source;
            cell.setRendered(view.html);
          }
        }
        next.push(cell);
      }
      this.cells = [];
      this.byId.clear();
      this.list.replaceChildren();
      for (const cell of next) this.place(cell, this.cells.length);
      this.list.append(this.lastAdder());
    }

    place(cell, at) {
      const before = this.cells[at];
      this.cells.splice(at, 0, cell);
      this.byId.set(cell.id, cell);
      const anchor = before ? before.adder : this.list.querySelector(".adder.last");
      this.list.insertBefore(cell.adder, anchor);
      this.list.insertBefore(cell.el, anchor);
    }

    // the line above a cell where a new one can go
    adder(cell) {
      return h("div", { class: "adder" },
        h("button", { onclick: () => this.insert(this.cells.indexOf(cell), "code", true) }, "+ Code"),
        h("button", { onclick: () => this.insert(this.cells.indexOf(cell), "markdown", true) }, "+ Text"));
    }

    lastAdder() {
      return h("div", { class: "adder last" },
        h("button", { onclick: () => this.insert(this.cells.length, "code", true) }, "+ Code"),
        h("button", { onclick: () => this.insert(this.cells.length, "markdown", true) }, "+ Text"));
    }

    insert(at, type, focus) {
      const id = "n" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
      const cell = new Cell(this, { id: id, type: type, source: "", outputs: [] });
      this.place(cell, at);
      this.structureDirty = true;
      this.changed();
      if (focus) cell.edit("start");
      return cell;
    }

    remove(cell) {
      const at = this.cells.indexOf(cell);
      if (at < 0) return;
      this.cells.splice(at, 1);
      this.byId.delete(cell.id);
      cell.el.remove();
      cell.adder.remove();
      if (this.selected === cell) this.selected = null;
      this.structureDirty = true;
      this.changed();
      if (this.cells.length === 0) this.insert(0, "code");
      else this.select(this.cells[Math.min(at, this.cells.length - 1)]);
    }

    move(cell, by) {
      const at = this.cells.indexOf(cell);
      const to = at + by;
      if (at < 0 || to < 0 || to >= this.cells.length) return;
      this.cells.splice(at, 1);
      cell.el.remove();
      cell.adder.remove();
      this.byId.delete(cell.id);
      this.place(cell, to);
      this.select(cell);
      cell.el.scrollIntoView({ block: "nearest" });
      this.structureDirty = true;
      this.changed();
    }

    setType(cell, type) {
      if (cell.type === type) return;
      cell.setType(type);
      cell.setOutputs([]);
      cell.setCount(null, null);
      if (type === "markdown") cell.askRender();
      else cell.askTokens();
      this.structureDirty = true;
      this.changed();
    }

    select(cell) {
      if (this.selected && this.selected !== cell) this.selected.el.classList.remove("selected");
      this.selected = cell;
      if (cell) cell.el.classList.add("selected");
    }

    editing(cell) {
      this.select(cell);
      cell.el.classList.add("editing");
    }

    focusNeighbour(cell, by) {
      const next = this.cells[this.cells.indexOf(cell) + by];
      if (!next) return false;
      next.edit(by < 0 ? "end" : "start");
      return true;
    }

    // ---- saving

    changed() {
      this.dirty = true;
      this.savedEl.textContent = "Edited";
      clearTimeout(this.syncTimer);
      this.syncTimer = setTimeout(() => this.sync(), 600);
    }

    // the server gets the cells as they are now
    sync() {
      clearTimeout(this.syncTimer);
      if (!this.dirty || !this.loaded) return;
      if (!this.local && (!this.ws || this.ws.readyState !== 1)) return;
      this.dirty = false;
      this.structureDirty = false;
      for (const c of this.cells) c.sent = c.source;
      this.send({
        op: "update",
        cells: this.cells.map((c) => ({ id: c.id, type: c.type, source: c.source })),
      });
    }

    // ---- what the language server says

    // before a question about a cell: the session has the other cells as
    // they are (the one asked about comes with the question)
    syncOthers(cell) {
      if (this.structureDirty || this.cells.some((c) => c !== cell && c.type === "code" && c.sent !== c.source)) {
        this.dirty = true;
        this.sync();
      }
    }

    checkSoon(cell) {
      clearTimeout(this.checkTimer);
      this.checkTimer = setTimeout(() => this.check(cell), 320);
    }

    // asks what is wrong in the cells; the one being edited goes along
    check(cell) {
      clearTimeout(this.checkTimer);
      if (!this.language.on || !this.loaded) return;
      this.syncOthers(cell);
      const m = { op: "check", seq: ++this.checkSeq };
      if (cell && cell.type === "code" && this.byId.has(cell.id)) {
        m.id = cell.id;
        m.source = cell.source;
        cell.sent = cell.source;
      }
      this.send(m);
    }

    // the uses of a name, marked in the cells they are in
    setOccurrences(places) {
      const by = new Map();
      for (const at of places) {
        if (!by.has(at.id)) by.set(at.id, []);
        by.get(at.id).push(at);
      }
      for (const c of this.cells) {
        if (c.type === "code") c.editor.setOccurrences(c.source === c.sent ? by.get(c.id) || [] : []);
      }
    }

    // goes to a place in a cell
    reveal(id, range) {
      const cell = this.byId.get(id);
      if (!cell) return;
      if (cell.type !== "code") {
        this.select(cell);
        cell.el.scrollIntoView({ block: "center" });
        return;
      }
      cell.edit();
      const [from, to] = offsetsOf(cell.source, range);
      cell.editor.area.setSelectionRange(from, to);
      const box = cell.editor.caretBox(from);
      if (box.top < 70 || box.bottom > innerHeight - 30) scrollBy({ top: box.top - innerHeight / 3 });
    }

    // ---- the outline: the text's headings and what the code defines

    toggleOutline() {
      document.body.classList.toggle("outline-open", !this.outline);
      if (this.outline) {
        this.outline.remove();
        this.outline = null;
        return;
      }
      this.outlineList = h("div", { class: "outline-list" });
      this.outline = h("aside", { class: "outline", "aria-label": "Outline" },
        h("div", { class: "outline-head" }, h("span", null, "Outline"),
          h("button", { title: "Close", onclick: () => this.toggleOutline() }, "Close")),
        this.outlineList);
      document.body.append(this.outline);
      this.refreshOutline();
    }

    refreshOutline() {
      if (!this.outline) return;
      clearTimeout(this.outlineTimer);
      this.outlineTimer = setTimeout(() => {
        const row = (item, depth) => {
          const heading = item.kind === "heading";
          const el = h("button", {
            class: "outline-row" + (heading ? " heading h" + item.level : ""),
            title: item.detail ? item.name + item.detail : item.name,
            onclick: () => this.reveal(item.id, item.range),
          }, heading ? null : kindBadge(item.kind), h("span", { class: "nb-label" }, item.name));
          el.style.paddingLeft = (10 + depth * 14) + "px";
          const out = [el];
          for (const kid of list(item.children)) {
            kid.id = item.id;
            out.push(...row(kid, depth + 1));
          }
          return out;
        };
        this.language.ask("outline", null, null, null, true).then((items) => {
          if (!this.outline || !items) return;
          let depth = 0;
          const rows = [];
          for (const item of items) {
            if (item.kind === "heading") {
              depth = Math.min(item.level - 1, 3);
              rows.push(...row(item, depth));
            } else {
              rows.push(...row(item, depth + 1));
            }
          }
          this.outlineList.replaceChildren(...(rows.length ? rows : [h("div", { class: "outline-empty" }, "Nothing to list yet.")]));
        }, () => {});
      }, 150);
    }

    flush() {
      this.sync();
    }

    saveNow() {
      if (this.local) { this.saveFile(); return; }
      this.dirty = this.dirty || true;
      this.sync();
      this.send({ op: "save" });
    }

    // ---- running

    run(cells) {
      this.sync();
      const ids = cells.filter((c) => c.type === "code" && c.source.trim() !== "").map((c) => c.id);
      if (ids.length) this.send({ op: "run", ids: ids });
    }

    runStay(cell) {
      if (cell.type === "markdown") { cell.editor.area.blur(); return; }
      this.run([cell]);
    }

    runAndAdvance(cell) {
      if (cell.type === "markdown") cell.editor.area.blur();
      else this.run([cell]);
      const at = this.cells.indexOf(cell);
      let next = this.cells[at + 1];
      if (!next) next = this.insert(this.cells.length, "code");
      if (next.type === "code") next.edit("end");
      else { cell.editor.area.blur(); this.select(next); next.el.scrollIntoView({ block: "nearest" }); }
    }

    runAll() {
      this.run(this.cells);
    }

    // ---- keys outside an editor: a cell is selected

    command(e) {
      const target = e.target;
      if (target instanceof HTMLTextAreaElement || target instanceof HTMLInputElement) return;
      if ((e.metaKey || e.ctrlKey) && e.key === "s") { e.preventDefault(); this.saveNow(); return; }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const cell = this.selected;
      if (!cell) return;
      const at = this.cells.indexOf(cell);
      const now = Date.now();
      let handled = true;
      if (e.key === "Enter" && e.shiftKey) this.runAndAdvance(cell);
      else if (e.key === "Enter") cell.edit("end");
      else if (e.key === "ArrowUp" || e.key === "k") this.step(at - 1);
      else if (e.key === "ArrowDown" || e.key === "j") this.step(at + 1);
      else if (e.key === "a") this.select(this.insert(at, "code"));
      else if (e.key === "b") this.select(this.insert(at + 1, "code"));
      else if (e.key === "m") this.setType(cell, "markdown");
      else if (e.key === "y") this.setType(cell, "code");
      else if (e.key === "d") {
        if (now - this.lastD < 600) { this.remove(cell); this.lastD = 0; }
        else this.lastD = now;
      } else handled = false;
      if (handled) e.preventDefault();
    }

    step(to) {
      const cell = this.cells[to];
      if (!cell) return;
      this.select(cell);
      cell.el.scrollIntoView({ block: "nearest" });
    }
  }

  // ---------------------------------------------------------------- start

  const where = decodeURIComponent(location.pathname);
  if (CONFIG) {
    new Notebook("notebook.md");
  } else if (where.startsWith("/nb/") && /\.(md|markdown)$/i.test(where)) {
    new Notebook(where.slice(4));
  } else {
    const path = where.startsWith("/nb/") ? where.slice(4).replace(/\/+$/, "") : "";
    showFolder(path).catch((e) => toast(String(e)));
  }
})();
