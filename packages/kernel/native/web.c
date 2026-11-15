// The browser's half of the kernel JIT (wasm.zig): a program's module,
// compiled and instantiated by the browser against the VM's own memory,
// its function put in the VM's function table. Built by emcc into the
// graphics VM (website/web/build.sh); the VM exports the functions of libm
// the modules import (sin, pow, round, ...), so that compiled kernels
// compute what the interpreter does.
#include <emscripten.h>

// the table index of the module's run function, or 0 when the browser
// would not take it (the interpreter runs the program then)
EM_JS(int, kernel_wasm_load, (const unsigned char *bytes, int len), {
  try {
    var code = HEAPU8.slice(bytes, bytes + len);
    // (globalThis.kernelKeep = [] keeps every module made, to look at)
    if (globalThis.kernelKeep) globalThis.kernelKeep.push(code);
    var module = new WebAssembly.Module(code);
    var env = { memory: wasmMemory };
    WebAssembly.Module.imports(module).forEach(function (imp) {
      if (imp.kind == 'function') {
        var f = wasmExports[imp.name];
        if (!f) throw new Error('the VM does not export ' + imp.name);
        env[imp.name] = f;
      }
    });
    var instance = new WebAssembly.Instance(module, { env: env });
    var free = Module.kernelFreeSlots || (Module.kernelFreeSlots = []);
    var index = free.length ? free.pop() : wasmTable.grow(1);
    wasmTable.set(index, instance.exports.run);
    return index;
  } catch (e) {
    if (!Module.kernelWarned) {
      Module.kernelWarned = true;
      err('kernel: compiling to WebAssembly failed, interpreting instead: ' + e);
    }
    return 0;
  }
});

EM_JS(void, kernel_wasm_free, (int index), {
  wasmTable.set(index, null);
  (Module.kernelFreeSlots || (Module.kernelFreeSlots = [])).push(index);
});
