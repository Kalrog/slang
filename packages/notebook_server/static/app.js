// The notebook server's page: a folder's notebooks, or one notebook with
// its cells. No libraries: the server highlights code (with slang's own
// parser) and renders Markdown; this script edits, asks and shows.
(function () {
  "use strict";

  const VALUE = "application/vnd.slang.value+json";
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
      this.el = h("div", { class: "editor" }, this.pre, this.area);
      this.last = "";
      this.area.addEventListener("input", () => this.changed());
      this.area.addEventListener("keydown", (e) => this.key(e));
      this.area.addEventListener("focus", () => cell.nb.editing(cell));
      this.area.addEventListener("blur", () => cell.blurred());
    }

    get value() { return this.area.value; }

    set(text, spans) {
      this.area.value = text;
      this.last = text;
      this.spans = spans || [];
      this.paint();
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
      this.last = text;
      this.setMark(null);
      this.paint();
      this.cell.edited();
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
      if (this.type === "code") this.askTokens();
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
      this.cells = [];
      this.byId = new Map();
      this.selected = null;
      this.loaded = false;
      this.dirty = false;
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
      this.connect();
    }

    buildBar() {
      setCrumbs(this.path, true);
      document.title = this.path.split("/").pop() + " - slang notebook";
      this.status = h("span", { class: "status", "data-kernel": "none" }, h("span", { class: "dot" }), h("span", { class: "text" }, "not started"));
      this.savedEl = h("span", { class: "saved" });
      this.stopButton = h("button", { class: "tool", title: "Stop the running cell", onclick: () => this.send({ op: "interrupt" }) }, icon("stop"), h("span", { class: "label" }, "Stop"));
      actions.replaceChildren(
        this.savedEl,
        this.status,
        h("button", { class: "tool primary", title: "Run every cell from the top", onclick: () => this.runAll() }, icon("play"), h("span", { class: "label" }, "Run all")),
        this.stopButton,
        h("button", {
          class: "tool", title: "Start the kernel over: the cells' state is forgotten",
          onclick: () => { this.flush(); this.send({ op: "restart" }); },
        }, icon("restart"), h("span", { class: "label" }, "Restart")),
        h("button", { class: "tool", title: "Take away what the cells showed", onclick: () => this.send({ op: "clear" }) }, h("span", null, "Clear")),
        themeButton());
      this.setKernel("none", null);
    }

    setKernel(status, project) {
      this.kernel = status;
      const names = { none: "not started", starting: "starting", idle: "idle", busy: "running", dead: "ended", offline: "offline" };
      this.status.dataset.kernel = status;
      let text = names[status] || status;
      if (project) {
        const parts = project.split("/");
        text += " · " + (parts[parts.length - 2] || "project");
        this.status.title = "The cells run in the project " + project;
      } else {
        this.status.title = status === "none" ? "The kernel starts when a cell is run" : "The cells run without a project file";
      }
      this.status.querySelector(".text").textContent = text;
      this.stopButton.disabled = status !== "busy";
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
      if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(m));
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
          this.setKernel(m.kernel, m.project);
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
          this.setKernel(m.status, m.project);
          break;
        case "tokens":
          if (cell) cell.tokens(m);
          break;
        case "rendered":
          if (cell && m.seq === cell.seq) cell.setRendered(m.html);
          break;
        case "saved":
          this.savedEl.textContent = this.dirty ? "Edited" : "Saved";
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
      this.changed();
    }

    setType(cell, type) {
      if (cell.type === type) return;
      cell.setType(type);
      cell.setOutputs([]);
      cell.setCount(null, null);
      if (type === "markdown") cell.askRender();
      else cell.askTokens();
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
      if (!this.ws || this.ws.readyState !== 1) return;
      this.dirty = false;
      this.send({
        op: "update",
        cells: this.cells.map((c) => ({ id: c.id, type: c.type, source: c.source })),
      });
    }

    flush() {
      this.sync();
    }

    saveNow() {
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
  if (where.startsWith("/nb/") && /\.(md|markdown)$/i.test(where)) {
    new Notebook(where.slice(4));
  } else {
    const path = where.startsWith("/nb/") ? where.slice(4).replace(/\/+$/, "") : "";
    showFolder(path).catch((e) => toast(String(e)));
  }
})();
