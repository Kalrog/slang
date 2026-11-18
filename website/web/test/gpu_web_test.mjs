// The gpu and window packages in a browser: runs packages/gpu's tests and
// the examples of examples/gpu on the graphics VM (website/public/
// slang-gfx.js, `make wasm-gfx`) in headless Chrome, on the machine's own
// GPU. `make gpu-web-test` runs it.
//
//   node website/web/test/gpu_web_test.mjs
//
// Needs Chrome (CHROME names another browser of its kind) and a GPU that
// Chrome's WebGPU takes. Exits with 0 when everything passed, 1 when
// something failed, and 0 with a note when there is no browser to test in.
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const chrome = process.env.CHROME || [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
].find((p) => fs.existsSync(p));
if (!chrome) {
  console.log("no Chrome found (CHROME names one): the gpu package in a browser is not tested");
  process.exit(0);
}
if (!fs.existsSync(path.join(root, "website/public/slang-gfx.wasm"))) {
  console.log("no website/public/slang-gfx.wasm (make wasm-gfx): the gpu package in a browser is not tested");
  process.exit(0);
}

// the page, the VM and the repository's files, from this machine only
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  let file = null;
  if (url.pathname === "/page.html") file = path.join(root, "website/web/test/page.html");
  else if (url.pathname.startsWith("/public/")) file = path.join(root, "website/public", url.pathname.slice(8));
  else if (url.pathname.startsWith("/repo/")) file = path.join(root, url.pathname.slice(6));
  if (!file || !path.resolve(file).startsWith(root) || !fs.existsSync(file)) {
    res.writeHead(404).end("not found");
    return;
  }
  res.writeHead(200, { "Content-Type": types[path.extname(file)] || "text/plain" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = "http://127.0.0.1:" + server.address().port;

// headless Chrome, driven over its DevTools protocol
const debugPort = 9300 + Math.floor(Math.random() * 500);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "slang-gpu-test-"));
const browser = spawn(chrome, [
  "--headless=new", `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--enable-unsafe-webgpu",
  "--enable-features=WebGPU", "--ignore-gpu-blocklist", "about:blank",
], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target = null;
for (let i = 0; i < 80 && !target; i++) {
  try {
    target = (await (await fetch(`http://127.0.0.1:${debugPort}/json`)).json()).find((t) => t.type === "page");
  } catch (e) {}
  if (!target) await sleep(100);
}
let failed = 0;
const finish = async (code) => {
  const gone = new Promise((r) => browser.once("exit", r));
  browser.kill();
  server.close();
  await Promise.race([gone, sleep(3000)]);
  // (the browser may still be writing its profile as it goes)
  try {
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch (e) {}
  process.exit(code);
};
if (!target) {
  console.log("Chrome did not start: the gpu package in a browser is not tested");
  await finish(0);
}
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (socket.onopen = r));
let nextId = 1;
const waiting = new Map();
socket.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) {
    waiting.get(m.id)(m.result || {});
    waiting.delete(m.id);
  }
};
const send = (method, params = {}) => new Promise((resolve) => {
  const id = nextId++;
  waiting.set(id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (js) => (await send("Runtime.evaluate", { expression: js, returnByValue: true })).result?.value;

// runs one file; gives {done, lines}
async function run(file, cmd, env, ms) {
  const query = new URLSearchParams({ file, cmd, env: env || "" });
  await send("Page.navigate", { url: `${base}/page.html?${query}` });
  let done = null;
  for (let waited = 0; waited < ms && done == null; waited += 100) {
    await sleep(100);
    done = await evaluate("window.done");
  }
  return { done, lines: (await evaluate("window.lines")) || [] };
}

await send("Page.enable");
await send("Runtime.enable");

// is there WebGPU here at all?
await send("Page.navigate", { url: `${base}/page.html?file=website/web/test/page.html` });
await sleep(300);
const adapter = (await send("Runtime.evaluate", {
  expression: "navigator.gpu ? navigator.gpu.requestAdapter().then((a) => !!a) : false",
  awaitPromise: true, returnByValue: true,
})).result?.value;
if (!adapter) {
  console.log("this Chrome has no WebGPU adapter here: the gpu package in a browser is not tested");
  await finish(0);
}

console.log("Group: the gpu package in a browser (the graphics VM)");
const tests = await run("packages/gpu/test/gpu_test.slang", "test", "", 60000);
for (const line of tests.lines) console.log("  " + line);
if (tests.done !== "exit 0") {
  failed++;
  console.log("  packages/gpu/test/gpu_test.slang ended with " + tests.done);
}

console.log("Group: WGSL blocks in a browser (gpu/wgsl, gpu/syntax)");
const blocks = await run("packages/gpu/test/wgsl_test.slang", "test", "", 60000);
for (const line of blocks.lines) console.log("  " + line);
if (blocks.done !== "exit 0") {
  failed++;
  console.log("  packages/gpu/test/wgsl_test.slang ended with " + blocks.done);
}

console.log("Group: examples/gpu in a browser (gpu and window)");
for (const [file, env] of [
  ["packages/gpu/examples/compute.slang", ""],
  ["examples/gpu/triangle.slang", "TRIANGLE_FRAMES=20"],
  ["examples/gpu/cube.slang", "CUBE_FRAMES=20"],
  ["examples/gpu/waves.slang", "WAVES_FRAMES=20"],
]) {
  const r = await run(file, "run", env, 30000);
  const ok = r.done === "exit 0" && !r.lines.some((l) => l.startsWith("[stderr]"));
  console.log(`  Test: ${file} ${ok ? "Passed" : "Failed"}`);
  if (!ok) {
    failed++;
    console.log("    ended with " + r.done);
    for (const line of r.lines) console.log("    " + line);
  }
}

// raylib shares the VM (and the page's canvas, when it is the one drawing):
// a raylib program still runs, frame after frame, until it is stopped
console.log("Group: raylib next to them");
{
  const r = await run("packages/raylib/examples/cubes.slang", "run", "", 3000);
  const ok = r.done === null && !r.lines.some((l) => l.startsWith("[stderr]"));
  console.log(`  Test: packages/raylib/examples/cubes.slang draws on ${ok ? "Passed" : "Failed"}`);
  if (!ok) {
    failed++;
    console.log("    ended with " + r.done);
    for (const line of r.lines) console.log("    " + line);
  }
}
console.log(failed ? "Some tests failed" : "All tests passed");
await finish(failed ? 1 : 0);
