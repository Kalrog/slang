// A small WASI (preview 1) for running slang.wasm in a browser or a worker:
// an in-memory file system under one preopened directory, stdout and
// stderr collected as text, no network. Enough for `slang run`, `slang fmt`
// and `slang highlight`; everything else answers ENOSYS.

const ESUCCESS = 0, EBADF = 8, EEXIST = 20, EINVAL = 28, EISDIR = 31,
  ENOENT = 44, ENOSYS = 52, ENOTDIR = 54, ENOTEMPTY = 55;
const FILETYPE_CHAR = 2, FILETYPE_DIR = 3, FILETYPE_FILE = 4;
const O_CREAT = 1, O_DIRECTORY = 2, O_EXCL = 4, O_TRUNC = 8;
const FD_APPEND = 1;

class Exit extends Error {
  constructor(code) { super(`exit ${code}`); this.code = code; }
}

function normalize(path) {
  const out = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop(); else out.push(part);
  }
  return "/" + out.join("/");
}

// run(wasm: WebAssembly.Module, args: string[], files: {[path]: string})
//   -> {code, stdout, stderr, files}
// Runs the module once with a fresh memory. files are written under /work
// first (paths relative to it); what the program leaves there comes back.
export async function run(module, args, files = {}, options = {}) {
  const enc = new TextEncoder(), dec = new TextDecoder();
  const fs = new Map(); // absolute path -> Uint8Array; directories: null
  fs.set("/", null);
  fs.set("/work", null);
  for (const [name, text] of Object.entries(files)) {
    const path = normalize("/work/" + name);
    const parts = path.split("/");
    for (let i = 2; i < parts.length; i++) fs.set(parts.slice(0, i).join("/") || "/", null);
    fs.set(path, typeof text === "string" ? enc.encode(text) : text);
  }
  let stdout = "", stderr = "";
  const decOut = new TextDecoder(), decErr = new TextDecoder();
  // open descriptors: {path, pos, dir, append}; 3 is /work
  const fds = new Map([[3, { path: "/work", pos: 0, dir: true, preopen: "/work" }]]);
  let nextFd = 4;
  const argv = args.map((a) => enc.encode(a + "\0"));
  const envp = Object.entries(options.env || {}).map(([k, v]) => enc.encode(`${k}=${v}\0`));
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const bytes = () => new Uint8Array(memory.buffer);
  const str = (ptr, len) => dec.decode(bytes().subarray(ptr, ptr + len));
  const now = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

  const resolve = (fd, ptr, len) => {
    const d = fds.get(fd);
    if (!d || !d.dir) return null;
    const p = str(ptr, len);
    return normalize(p.startsWith("/") ? p : d.path + "/" + p);
  };
  const children = (dir) => {
    const prefix = dir === "/" ? "/" : dir + "/";
    const out = [];
    for (const k of fs.keys()) {
      if (k !== dir && k.startsWith(prefix) && !k.slice(prefix.length).includes("/")) {
        out.push(k.slice(prefix.length));
      }
    }
    return out.sort();
  };
  const stat = (path, ptr) => {
    const v = view();
    const data = fs.get(path);
    for (let i = 0; i < 64; i += 8) v.setBigUint64(ptr + i, 0n, true);
    v.setBigUint64(ptr + 8, BigInt(path.length), true);
    v.setUint8(ptr + 16, data === null ? FILETYPE_DIR : FILETYPE_FILE);
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(data ? data.length : 0), true);
    const t = now();
    v.setBigUint64(ptr + 40, t, true);
    v.setBigUint64(ptr + 48, t, true);
    v.setBigUint64(ptr + 56, t, true);
  };
  const iovs = (ptr, n) => {
    const v = view(), out = [];
    for (let i = 0; i < n; i++) {
      out.push([v.getUint32(ptr + i * 8, true), v.getUint32(ptr + i * 8 + 4, true)]);
    }
    return out;
  };
  const write = (fd, chunks, at) => {
    let total = 0;
    if (fd === 1 || fd === 2) {
      for (const [p, l] of chunks) {
        const piece = bytes().slice(p, p + l);
        if (fd === 1) stdout += decOut.decode(piece, { stream: true });
        else stderr += decErr.decode(piece, { stream: true });
        if (options.onOutput) options.onOutput(fd, piece);
        total += l;
      }
      return total;
    }
    const d = fds.get(fd);
    let data = fs.get(d.path);
    let pos = at ?? (d.append ? data.length : d.pos);
    for (const [p, l] of chunks) {
      if (pos + l > data.length) {
        const grown = new Uint8Array(Math.max(pos + l, data.length * 2));
        grown.set(data);
        data = grown.subarray(0, pos + l);
      }
      data.set(bytes().subarray(p, p + l), pos);
      pos += l;
      total += l;
    }
    fs.set(d.path, data);
    if (at === undefined) d.pos = pos;
    return total;
  };
  const read = (fd, chunks, at) => {
    if (fd === 0) return 0;
    const d = fds.get(fd);
    const data = fs.get(d.path);
    let pos = at ?? d.pos, total = 0;
    for (const [p, l] of chunks) {
      const n = Math.max(0, Math.min(l, data.length - pos));
      bytes().set(data.subarray(pos, pos + n), p);
      pos += n;
      total += n;
      if (n < l) break;
    }
    if (at === undefined) d.pos = pos;
    return total;
  };
  const isFile = (fd) => fd <= 2 || (fds.has(fd) && !fds.get(fd).dir);

  const wasi = {
    args_sizes_get(argc, size) {
      view().setUint32(argc, argv.length, true);
      view().setUint32(size, argv.reduce((n, a) => n + a.length, 0), true);
      return ESUCCESS;
    },
    args_get(list, buf) {
      for (const a of argv) {
        view().setUint32(list, buf, true);
        bytes().set(a, buf);
        list += 4;
        buf += a.length;
      }
      return ESUCCESS;
    },
    environ_sizes_get(count, size) {
      view().setUint32(count, envp.length, true);
      view().setUint32(size, envp.reduce((n, a) => n + a.length, 0), true);
      return ESUCCESS;
    },
    environ_get(list, buf) {
      for (const e of envp) {
        view().setUint32(list, buf, true);
        bytes().set(e, buf);
        list += 4;
        buf += e.length;
      }
      return ESUCCESS;
    },
    clock_res_get(id, ptr) {
      view().setBigUint64(ptr, 1000n, true);
      return ESUCCESS;
    },
    clock_time_get(id, precision, ptr) {
      view().setBigUint64(ptr, id === 0 ? now() : BigInt(Math.round(performance.now() * 1e6)), true);
      return ESUCCESS;
    },
    fd_write(fd, ptr, n, written) {
      if (!isFile(fd)) return EBADF;
      view().setUint32(written, write(fd, iovs(ptr, n)), true);
      return ESUCCESS;
    },
    fd_pwrite(fd, ptr, n, offset, written) {
      if (!isFile(fd)) return EBADF;
      view().setUint32(written, write(fd, iovs(ptr, n), Number(offset)), true);
      return ESUCCESS;
    },
    fd_read(fd, ptr, n, nread) {
      if (!isFile(fd)) return EBADF;
      view().setUint32(nread, read(fd, iovs(ptr, n)), true);
      return ESUCCESS;
    },
    fd_pread(fd, ptr, n, offset, nread) {
      if (!isFile(fd)) return EBADF;
      view().setUint32(nread, read(fd, iovs(ptr, n), Number(offset)), true);
      return ESUCCESS;
    },
    fd_seek(fd, offset, whence, ptr) {
      const d = fds.get(fd);
      if (!d || d.dir) return fd <= 2 ? 70 /* ESPIPE */ : EBADF;
      const size = fs.get(d.path).length;
      const base = whence === 0 ? 0 : whence === 1 ? d.pos : size;
      const pos = base + Number(offset);
      if (pos < 0) return EINVAL;
      d.pos = pos;
      view().setBigUint64(ptr, BigInt(pos), true);
      return ESUCCESS;
    },
    fd_tell(fd, ptr) {
      const d = fds.get(fd);
      if (!d) return EBADF;
      view().setBigUint64(ptr, BigInt(d.pos), true);
      return ESUCCESS;
    },
    fd_close(fd) {
      if (!fds.has(fd) || fd === 3) return fd <= 2 ? ESUCCESS : EBADF;
      fds.delete(fd);
      return ESUCCESS;
    },
    fd_sync: () => ESUCCESS,
    fd_datasync: () => ESUCCESS,
    fd_advise: () => ESUCCESS,
    fd_fdstat_get(fd, ptr) {
      const v = view();
      let type = FILETYPE_CHAR;
      if (fd > 2) {
        const d = fds.get(fd);
        if (!d) return EBADF;
        type = d.dir ? FILETYPE_DIR : FILETYPE_FILE;
      }
      v.setUint8(ptr, type);
      v.setUint16(ptr + 2, 0, true);
      v.setBigUint64(ptr + 8, 0xffffffffffffffffn, true);
      v.setBigUint64(ptr + 16, 0xffffffffffffffffn, true);
      return ESUCCESS;
    },
    fd_fdstat_set_flags: () => ESUCCESS,
    fd_fdstat_set_rights: () => ESUCCESS,
    fd_filestat_get(fd, ptr) {
      if (fd <= 2) {
        for (let i = 0; i < 64; i += 8) view().setBigUint64(ptr + i, 0n, true);
        view().setUint8(ptr + 16, FILETYPE_CHAR);
        return ESUCCESS;
      }
      const d = fds.get(fd);
      if (!d) return EBADF;
      stat(d.path, ptr);
      return ESUCCESS;
    },
    fd_filestat_set_size(fd, size) {
      const d = fds.get(fd);
      if (!d || d.dir) return EBADF;
      const data = fs.get(d.path), n = Number(size);
      const out = new Uint8Array(n);
      out.set(data.subarray(0, Math.min(n, data.length)));
      fs.set(d.path, out);
      return ESUCCESS;
    },
    fd_filestat_set_times: () => ESUCCESS,
    fd_prestat_get(fd, ptr) {
      const d = fds.get(fd);
      if (!d || !d.preopen) return EBADF;
      view().setUint8(ptr, 0);
      view().setUint32(ptr + 4, enc.encode(d.preopen).length, true);
      return ESUCCESS;
    },
    fd_prestat_dir_name(fd, ptr, len) {
      const d = fds.get(fd);
      if (!d || !d.preopen) return EBADF;
      bytes().set(enc.encode(d.preopen).subarray(0, len), ptr);
      return ESUCCESS;
    },
    fd_readdir(fd, buf, len, cookie, used) {
      const d = fds.get(fd);
      if (!d || !d.dir) return EBADF;
      const names = [".", "..", ...children(d.path)];
      let off = 0;
      for (let i = Number(cookie); i < names.length; i++) {
        const name = enc.encode(names[i]);
        const entry = new Uint8Array(24 + name.length);
        const ev = new DataView(entry.buffer);
        ev.setBigUint64(0, BigInt(i + 1), true);
        ev.setBigUint64(8, BigInt(i + 1), true);
        ev.setUint32(16, name.length, true);
        const full = names[i] === "." || names[i] === ".." ? null : normalize(d.path + "/" + names[i]);
        ev.setUint8(20, full === null || fs.get(full) === null ? FILETYPE_DIR : FILETYPE_FILE);
        entry.set(name, 24);
        const n = Math.min(entry.length, len - off);
        bytes().set(entry.subarray(0, n), buf + off);
        off += n;
        if (off >= len) break;
      }
      view().setUint32(used, off, true);
      return ESUCCESS;
    },
    path_open(dirfd, dirflags, ptr, len, oflags, rightsBase, rightsInherit, fdflags, out) {
      const path = resolve(dirfd, ptr, len);
      if (path === null) return EBADF;
      const exists = fs.has(path);
      if (exists && (oflags & O_EXCL) && (oflags & O_CREAT)) return EEXIST;
      if (!exists) {
        if (!(oflags & O_CREAT)) return ENOENT;
        const parent = path.slice(0, path.lastIndexOf("/")) || "/";
        if (fs.get(parent) !== null) return ENOENT;
        fs.set(path, new Uint8Array(0));
      }
      const isDir = fs.get(path) === null;
      if ((oflags & O_DIRECTORY) && !isDir) return ENOTDIR;
      if (isDir && (oflags & O_TRUNC)) return EISDIR;
      if (oflags & O_TRUNC) fs.set(path, new Uint8Array(0));
      const fd = nextFd++;
      fds.set(fd, { path, pos: 0, dir: isDir, append: (fdflags & FD_APPEND) !== 0 });
      view().setUint32(out, fd, true);
      return ESUCCESS;
    },
    path_filestat_get(dirfd, flags, ptr, len, out) {
      const path = resolve(dirfd, ptr, len);
      if (path === null) return EBADF;
      if (!fs.has(path)) return ENOENT;
      stat(path, out);
      return ESUCCESS;
    },
    path_filestat_set_times: () => ESUCCESS,
    path_create_directory(dirfd, ptr, len) {
      const path = resolve(dirfd, ptr, len);
      if (path === null) return EBADF;
      if (fs.has(path)) return EEXIST;
      fs.set(path, null);
      return ESUCCESS;
    },
    path_remove_directory(dirfd, ptr, len) {
      const path = resolve(dirfd, ptr, len);
      if (!fs.has(path)) return ENOENT;
      if (fs.get(path) !== null) return ENOTDIR;
      if (children(path).length) return ENOTEMPTY;
      fs.delete(path);
      return ESUCCESS;
    },
    path_unlink_file(dirfd, ptr, len) {
      const path = resolve(dirfd, ptr, len);
      if (!fs.has(path)) return ENOENT;
      if (fs.get(path) === null) return EISDIR;
      fs.delete(path);
      return ESUCCESS;
    },
    path_rename(fd1, p1, l1, fd2, p2, l2) {
      const from = resolve(fd1, p1, l1), to = resolve(fd2, p2, l2);
      if (!fs.has(from)) return ENOENT;
      fs.set(to, fs.get(from));
      fs.delete(from);
      return ESUCCESS;
    },
    random_get(ptr, len) {
      for (let i = 0; i < len; i += 65536) {
        crypto.getRandomValues(bytes().subarray(ptr + i, ptr + Math.min(len, i + 65536)));
      }
      return ESUCCESS;
    },
    proc_exit(code) {
      throw new Exit(code);
    },
    sched_yield: () => ESUCCESS,
  };
  const imports = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== "wasi_snapshot_preview1") continue;
    imports[imp.name] = wasi[imp.name] || (() => ENOSYS);
  }
  const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: imports });
  memory = instance.exports.memory;
  let code = 0;
  try {
    instance.exports._start();
  } catch (e) {
    if (e instanceof Exit) code = e.code;
    else {
      code = 134;
      stderr += `\n${e.message === "unreachable" ? "the program crashed (out of memory or a VM error)" : e.message}\n`;
    }
  }
  stdout += decOut.decode();
  stderr += decErr.decode();
  const left = {};
  for (const [path, data] of fs) {
    if (data !== null && path.startsWith("/work/")) left[path.slice(6)] = dec.decode(data);
  }
  return { code, stdout, stderr, files: left };
}
