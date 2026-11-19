// The notebook package's browser half, run by Node in place of a page:
// slang.wasm under web/wasi.js as the kernel (notebook/kernel_web) and as
// a page's session (notebook/service_web), with this script passing their
// messages on as a page does.
//
//   node test/web_test.mjs <slang.wasm>      (make notebook-test runs it)
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { run } from "../web/wasi.js";

const pkg = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wasm = process.argv[2];
if (!wasm || !fs.existsSync(wasm)) {
  console.error("usage: node test/web_test.mjs <slang.wasm>");
  process.exit(2);
}
const module = await WebAssembly.compile(fs.readFileSync(wasm));

// the package as a worker has it
const files = { "/pkg/notebook/slang.project": fs.readFileSync(path.join(pkg, "slang.project"), "utf8") };
for (const name of fs.readdirSync(pkg)) {
  if (name.endsWith(".slang")) files["/pkg/notebook/" + name] = fs.readFileSync(path.join(pkg, name), "utf8");
}
for (const name of ["kernel_web.slang", "service_web.slang"]) {
  files["/pkg/notebook/bin/" + name] = fs.readFileSync(path.join(pkg, "bin", name), "utf8");
}

// a slang program as a worker runs it: what it sends and prints, in order
async function start(args, more, cwd, interrupted) {
  const inbox = [];
  const said = [];
  const dec = new TextDecoder();
  const vm = await run(module, args, { ...files, ...more }, {
    env: { SLANG_NO_CACHE: "1" }, cwd: cwd, collect: false,
    onOutput: (fd, bytes) => said.push({ event: "stream", name: fd === 1 ? "stdout" : "stderr", text: dec.decode(bytes) }),
    host: { send: (text) => said.push(JSON.parse(text)), receive: () => (inbox.length ? inbox.shift() : null), interrupted: interrupted || (() => false) },
  });
  return {
    vm, said,
    // gives the program messages and lets it run until it waits again
    send(...messages) {
      for (const m of messages) inbox.push(JSON.stringify(m));
      const from = said.length;
      vm.resume();
      return said.slice(from);
    },
  };
}

let passed = 0;
async function test(name, f) {
  try {
    await f();
    passed++;
    console.log("  Test: " + name + " Passed");
  } catch (e) {
    console.log("  Test: " + name + " Failed\n" + (e.stack || e));
    process.exitCode = 1;
  }
}

console.log("Group: a notebook in a browser (slang.wasm)");

await test("the kernel: cells share a session, see the project's files, and can be stopped", async () => {
  let polls = 0, stopAt = -1;
  const k = await start(["slang", "run", "/pkg/notebook/bin/kernel_web.slang", "/work/notes/a.md"], {
    "/work/slang.project": '{name: "proj"}\n',
    "/work/lib.slang": "return {twice: func(x){ return x * 2 }}\n",
    "/work/notes/a.md": "# A\n",
    "/work/notes/data.txt": "from a file",
  }, "/work/notes", () => ++polls === stopAt);
  assert.equal(k.vm.parked, true, "it waits for commands");
  assert.equal(k.said[0].event, "ready");
  assert.equal(k.said[0].project, "/work/slang.project");
  assert.equal(k.said[0].interrupts, true);
  const events = k.send(
    { op: "execute", id: "c1", code: 'local os = require("slang/os")\nlocal n = 20\nprint("hi\\n")\nn + 1', origin: "a.md", line: 2 },
    { op: "execute", id: "c2", code: 'require("lib").twice(n) .. ""', origin: "a.md", line: 9 },
    { op: "execute", id: "c3", code: 'require("lib").twice(n)', origin: "a.md", line: 12 },
    { op: "execute", id: "c4", code: 'os.read_file("data.txt")', origin: "a.md", line: 15 },
    { op: "execute", id: "c5", code: 'local nb = require("notebook")\nnb.display(nb.markdown("**b**"))\nnb.plot({1, 4, 9})', origin: "a.md", line: 18 },
    { op: "execute", id: "c5b", code: "nb.pixels(4, 3, func(x, y){ return {x / 3, y / 2, 0.5} })", origin: "a.md", line: 22 },
    { op: "variables", id: "v1" },
  );
  const of = (id, kind) => events.filter((e) => e.id === id && e.event === kind);
  // printing and events come in the order they were made
  assert.deepEqual(events.slice(0, 4).map((e) => e.event), ["start", "stream", "result", "done"]);
  assert.equal(events[1].text, "hi\n");
  assert.equal(of("c1", "result")[0].data["text/plain"], "21");
  // an error is the cell's, with the line it has in the notebook
  assert.equal(of("c2", "error")[0].error.kind, "syntax");
  assert.equal(of("c2", "error")[0].error.location.line, 10);
  assert.equal(of("c2", "done")[0].status, "error");
  assert.equal(of("c3", "result")[0].data["text/plain"], "40");
  assert.equal(of("c4", "result")[0].data["text/plain"], '"from a file"');
  assert.equal(of("c5", "display")[0].data["text/markdown"], "**b**");
  assert.ok(of("c5", "result")[0].data["image/svg+xml"].startsWith("<svg"));
  // an image is a PNG here too, though a browser has no zlib for it
  const png = Buffer.from(of("c5b", "result")[0].data["image/png"], "base64");
  assert.equal(png.subarray(1, 4).toString(), "PNG");
  assert.equal(png.readUInt32BE(16), 4);
  assert.equal(png.readUInt32BE(20), 3);
  const idat = png.subarray(41, 41 + png.readUInt32BE(33));
  assert.equal(zlib.inflateSync(idat).length, 3 * (1 + 4 * 3));
  const names = events.find((e) => e.event === "variables").variables.map((v) => v.name);
  assert.deepEqual(names.sort(), ["n", "nb", "os"]);
  // an endless loop ends when the page says so, and the session is kept
  stopAt = polls + 3;
  const stopped = k.send({ op: "execute", id: "c6", code: "for(true){}", origin: "a.md", line: 30 });
  assert.equal(stopped.find((e) => e.event === "error").error.kind, "interrupted");
  assert.equal(stopped.find((e) => e.event === "done").status, "interrupted");
  assert.equal(k.send({ op: "execute", id: "c7", code: "n", origin: "a.md", line: 33 })[1].data["text/plain"], "20");
  k.send({ op: "shutdown" });
  assert.equal(k.vm.parked, false);
  assert.equal(k.vm.code, 0);
});

await test("a page's session: it shows, colours, runs through the page's kernel, and saves", async () => {
  const service = await start(["slang", "run", "/pkg/notebook/bin/service_web.slang"], {}, "/work");
  assert.deepEqual(service.said[0], { ready: true });
  let out = service.send(
    { open: { name: "demo.md", text: "# Demo\n\n```slang\nlocal x = 6 * 7\nx\n```\n\n```slang\nx + 1\n```\n" } },
    { page: { op: "highlight", id: "c2", seq: 4, source: 'local y = "s"' } },
    { page: { op: "render", id: "c1", seq: 5, source: "*hi*" } },
  );
  const shown = out[0].page;
  assert.equal(shown.event, "notebook");
  assert.equal(shown.title, "Demo");
  assert.deepEqual(shown.kinds, ["wasm"]);
  assert.ok(shown.cells[0].html.includes("<h1"));
  assert.equal(shown.cells[1].spans[0][2], "keyword");
  assert.deepEqual(out[1].page.spans[3], [10, 13, "string"]);
  assert.equal(out[2].page.html, "<p><em>hi</em></p>\n");
  // run: the service asks the page for a kernel, and the page gives it one
  out = service.send({ page: { op: "run", ids: ["c2", "c3"] } });
  const ops = out.filter((m) => m.kernel).map((m) => m.kernel);
  assert.equal(ops[0].op, "start");
  assert.equal(ops[1].op, "execute");
  assert.equal(ops[1].id, "c2");
  const kernel = await start(ops[0].args, ops[0].files, ops[0].cwd);
  // the page passes on what the kernel says, and the service's answers
  let toKernel = [ops[1]];
  let results = {};
  let pending = kernel.said.splice(0);
  for (let round = 0; round < 20 && (pending.length || toKernel.length); round++) {
    if (toKernel.length) pending.push(...kernel.send(...toKernel.splice(0)));
    const back = service.send(...pending.splice(0).map((e) => ({ kernel: e })));
    for (const m of back) {
      if (m.kernel) toKernel.push(m.kernel);
      else if (m.page && m.page.event === "cell" && m.page.e.event === "result") results[m.page.id] = m.page.e.data["text/plain"];
    }
  }
  assert.deepEqual(results, { c2: "42", c3: "43" });
  // the save the session asked a timer for
  const timer = service.said.find((m) => m.timer);
  assert.ok(timer, "a save was planned");
  out = service.send({ timer: timer.timer.id });
  const store = out.find((m) => m.store).store;
  assert.equal(store.name, "demo.md");
  assert.ok(store.text.includes("local x = 6 * 7"));
  assert.ok(store.outputs.includes('"42"'));
  assert.ok(out.some((m) => m.page && m.page.event === "saved"));
  // another notebook is opened: the kernel of the first is ended
  out = service.send({ open: { name: "other.md", text: "```slang\n1\n```\n", outputs: store.outputs } });
  assert.equal(out.find((m) => m.kernel).kernel.op, "kill");
  assert.equal(out.find((m) => m.page).page.cells.length, 1);
});

await test("a page's language: the language server in the worker, with the library's sources", async () => {
  // what notebook/browser's language_files gives a page: the lsp package
  // where the notebook package's project says it is, the lock that says
  // so, and the library to read about
  const lsp = path.resolve(pkg, "../../lsp");
  const more = { "/pkg/notebook/slang.lock": '{\n  ["lsp"]: {path: "../../lsp"},\n}\n' };
  for (const name of ["server.slang", "navigate.slang", "slang.project"]) {
    more["/lsp/" + name] = fs.readFileSync(path.join(lsp, name), "utf8");
  }
  const stubs = path.resolve(pkg, "../../slang/stubs");
  more["/slang/stubs/slang/string.slang"] = fs.readFileSync(path.join(stubs, "slang/string.slang"), "utf8");
  more["/slang/stubs/globals.slang"] = fs.readFileSync(path.join(stubs, "globals.slang"), "utf8");
  more["/slang/lib/json.slang"] = fs.readFileSync(path.resolve(pkg, "../../slang/lib/json.slang"), "utf8");
  const service = await start(["slang", "run", "/pkg/notebook/bin/service_web.slang"], more, "/work");
  let out = service.send(
    { open: { name: "demo.md", text: '```slang\nlocal str = require("slang/string")\n// doubles a number\nlocal func twice(n){ return n * 2 }\n```\n\n```slang\ntwice(2)\nnowhere\n```\n' } },
    { page: { op: "check", seq: 1 } },
  );
  assert.equal(out[0].page.language, true);
  const found = out.find((m) => m.page && m.page.event === "diagnostics").page;
  assert.deepEqual(found.cells.c1, []);
  assert.equal(found.cells.c2[0].severity, "warning");
  assert.deepEqual(found.cells.c2[0].range, [1, 0, 1, 7]);
  out = service.send(
    { page: { op: "language", seq: 2, method: "hover", id: "c2", line: 0, character: 2 } },
    { page: { op: "language", seq: 3, method: "definition", id: "c2", line: 0, character: 2 } },
    // the cell as it is being typed comes with the question
    { page: { op: "language", seq: 4, method: "complete", id: "c2", line: 0, character: 4, trigger: ".", source: "str.\ntwice(2)" } },
  );
  const answers = out.filter((m) => m.page && m.page.event === "language").map((m) => m.page);
  assert.ok(answers[0].result.html.includes("doubles a number"));
  assert.deepEqual(answers[1].result[0], { id: "c1", range: [2, 11, 2, 16] });
  // the library's names come from its sources in the page
  assert.ok(answers[2].result.some((item) => item.label === "upper" && item.kind === "function"));
});

console.log("Tests succeeded: " + passed);
if (process.exitCode) console.log("Some tests failed");
else console.log("All tests passed");
