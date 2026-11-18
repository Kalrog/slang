// The worker that runs slang.wasm for a notebook's page: a kernel
// (notebook/kernel_web) or the notebook's session (notebook/service_web).
// A classic script: wasi.js's run() is put in front of it (notebook/
// browser's worker_source).
//
// In:  {op: "start", module, args, files, cwd, env, flag}   once
//      {op: "message", text}        a message for the program (slang/web)
// Out: {type: "message", text}      a message from the program
//      {type: "output", name, text} what it printed ("stdout", "stderr")
//      {type: "exit", code}         it ended
//
// files: {path: text | {b64}}. flag: a SharedArrayBuffer the page sets
// to 1 to interrupt the program (slang/vm's catch_interrupt asks for it),
// where the page has one.
"use strict";

let vm = null;
let flag = null;
const inbox = [];
const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
const pending = { name: null, text: "" };
let last = 0;

// what the program printed goes out in batches, and before any message
// it sent after it
function flush() {
  if (pending.text) postMessage({ type: "output", name: pending.name, text: pending.text });
  pending.text = "";
  last = performance.now();
}

function output(fd, bytes) {
  const name = fd === 1 ? "stdout" : "stderr";
  if (name !== pending.name) flush();
  pending.name = name;
  pending.text += decoders[fd].decode(bytes, { stream: true });
  if (pending.text.length > 8192 || performance.now() - last > 50) flush();
}

function settle(state) {
  flush();
  if (!state.parked) {
    vm = null;
    postMessage({ type: "exit", code: state.code });
  }
}

function resume() {
  if (vm && vm.parked) settle(vm.resume());
}

function bytesOf(b64) {
  const text = atob(b64);
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
  return out;
}

onmessage = async (e) => {
  const m = e.data;
  if (m.op === "message") {
    inbox.push(m.text);
    resume();
    return;
  }
  if (m.op !== "start") return;
  flag = m.flag ? new Int32Array(m.flag) : null;
  try {
    const files = {};
    for (const [path, v] of Object.entries(m.files || {})) {
      files[path] = typeof v === "string" ? v : bytesOf(v.b64);
    }
    const started = await run(m.module, m.args, files, {
      env: { SLANG_NO_CACHE: "1", ...(m.env || {}) }, cwd: m.cwd, collect: false, onOutput: output,
      host: {
        send: (text) => { flush(); postMessage({ type: "message", text: text }); },
        receive: () => (inbox.length ? inbox.shift() : null),
        interrupted: () => flag !== null && Atomics.exchange(flag, 0, 0) === 1,
      },
    });
    vm = started;
    settle(started);
    // (what arrived while it started)
    if (inbox.length) resume();
  } catch (err) {
    postMessage({ type: "output", name: "stderr", text: String((err && err.message) || err) + "\n" });
    postMessage({ type: "exit", code: 134 });
  }
};
