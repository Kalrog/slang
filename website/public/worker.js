// Runs slang.wasm for the page: {id, cmd: "run" | "fmt" | "check" |
// "expand", code, files} in (files: more files next to main.slang, such as
// an extension the code loads), {id, stream, text} while a program prints and {id, done, code,
// stdout, stderr, ms} at the end out.
import { run } from "./wasi.js";

const module = fetch(new URL("slang.wasm", import.meta.url))
  .then((r) => {
    if (!r.ok) throw new Error(`slang.wasm: ${r.status}`);
    return r.arrayBuffer();
  })
  .then((b) => WebAssembly.compile(b));

const ARGS = {
  run: ["slang", "run", "/work/main.slang"],
  fmt: ["slang", "fmt", "--stdout", "/work/main.slang"],
  check: ["slang", "highlight", "--check", "/work/main.slang"],
  expand: ["slang", "expand", "/work/main.slang"],
};

self.onmessage = async (e) => {
  const { id, cmd, code, files } = e.data;
  // a program's output goes out in batches while it runs
  let pending = "", last = performance.now();
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
  const flush = (fd) => {
    if (pending) self.postMessage({ id, stream: fd, text: pending });
    pending = "";
    last = performance.now();
  };
  let pendingFd = 1;
  const onOutput = cmd !== "run" ? null : (fd, bytes) => {
    if (fd !== pendingFd) flush(pendingFd);
    pendingFd = fd;
    pending += decoders[fd].decode(bytes, { stream: true });
    if (pending.length > 8192 || performance.now() - last > 50) flush(fd);
  };
  try {
    const m = await module;
    const t0 = performance.now();
    const r = await run(m, ARGS[cmd], { ...(files || {}), "main.slang": code }, { env: { SLANG_NO_CACHE: "1" }, onOutput });
    flush(pendingFd);
    self.postMessage({ id, done: true, code: r.code, stdout: r.stdout, stderr: r.stderr, ms: performance.now() - t0 });
  } catch (err) {
    self.postMessage({ id, done: true, code: -1, stdout: "", stderr: String(err.message || err), ms: 0 });
  }
};
