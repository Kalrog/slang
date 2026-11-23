//! slang/crypto_core: the common cryptography from Zig's std.crypto, the
//! same on every platform (no OpenSSL): hash, hmac, hasher, random_bytes,
//! equal, pbkdf2, scrypt (and their _async forms on libuv's pool), encrypt
//! and decrypt (AES-GCM, ChaCha20-Poly1305). slang/crypto is built on it;
//! keys (RSA, EC, Ed25519 in PEM) and TLS stay with OpenSSL (the crypto and
//! tls extensions).
//!
//! The names, arguments, results and error messages are those of the
//! crypto extension's functions, which they replace in slang/crypto. Bytes
//! are strings or buffers.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const oom = vm_mod.oom;
const stdlib = @import("stdlib.zig");
const ctypes = @import("ctypes.zig");
const capi = @import("../capi.zig");

const hash = std.crypto.hash;
const Hmac = std.crypto.auth.hmac.Hmac;

/// The digests, by their OpenSSL names (any case).
const digests = .{
    .{ "md5", hash.Md5 },
    .{ "sha1", hash.Sha1 },
    .{ "sha224", hash.sha2.Sha224 },
    .{ "sha256", hash.sha2.Sha256 },
    .{ "sha384", hash.sha2.Sha384 },
    .{ "sha512", hash.sha2.Sha512 },
    .{ "sha512-224", hash.sha2.Sha512_224 },
    .{ "sha512-256", hash.sha2.Sha512_256 },
    .{ "sha3-224", hash.sha3.Sha3_224 },
    .{ "sha3-256", hash.sha3.Sha3_256 },
    .{ "sha3-384", hash.sha3.Sha3_384 },
    .{ "sha3-512", hash.sha3.Sha3_512 },
    .{ "blake2b512", hash.blake2.Blake2b512 },
    .{ "blake2s256", hash.blake2.Blake2s256 },
};

/// The index of a digest in digests, or null.
fn digestIndex(name: []const u8) ?usize {
    inline for (digests, 0..) |d, i| {
        if (std.ascii.eqlIgnoreCase(name, d[0])) return i;
    }
    return null;
}

const max_digest = 64;

fn unknownDigest(vm: *VM, name: []const u8) Error {
    return vm.raiseKind("argument", "crypto: unknown digest {s}", .{name});
}

fn argDigest(th: *Thread, args: []Value, i: usize) Error!usize {
    const name = try api.argString(th, args, i, "digest");
    return digestIndex(name) orelse unknownDigest(th.vm, name);
}

/// A string's or a buffer's bytes.
fn argBytes(th: *Thread, args: []Value, i: usize, name: []const u8) Error![]const u8 {
    const v = api.arg(args, i);
    if (v.asString()) |s| return s.bytes();
    if (ctypes.asBuffer(v)) |u| {
        const p = u.as(ctypes.Ptr);
        const n = p.count * p.ty.?.size;
        if (n == 0) return "";
        return @as([*]const u8, @ptrFromInt(p.addr))[0..n];
    }
    return api.argError(th, name, i, "string or buffer", v);
}

pub fn module(vm: *VM) *Table {
    const t = stdlib.makeModule(vm, &.{
        .{ .name = "hash", .f = cryptoHash },
        .{ .name = "hmac", .f = cryptoHmac },
        .{ .name = "random_bytes", .f = randomBytes },
        .{ .name = "equal", .f = equal },
        .{ .name = "hasher", .f = newHasher },
        .{ .name = "pbkdf2", .f = pbkdf2 },
        .{ .name = "scrypt", .f = scrypt },
        .{ .name = "encrypt", .f = encrypt },
        .{ .name = "decrypt", .f = decrypt },
    });
    t.set(vm.gpa, vm.str("pbkdf2_async"), .{ .function = capi.newCClosure(vm, pbkdf2Async, "pbkdf2_async", &.{}) });
    t.set(vm.gpa, vm.str("scrypt_async"), .{ .function = capi.newCClosure(vm, scryptAsync, "scrypt_async", &.{}) });
    const meta = vm.newTable(0, 2);
    stdlib.setClass(vm, meta, &.{
        .{ .name = "update", .f = hasherUpdate },
        .{ .name = "digest", .f = hasherDigest },
    }, &.{});
    meta.set(vm.gpa, vm.str("__type"), vm.str(hasher_tname));
    vm.type_metas.set(vm.gpa, vm.str(hasher_tname), .{ .table = meta });
    return t;
}

// ---- hashes and MACs ----

/// hash(digest, data) -> raw bytes
fn cryptoHash(th: *Thread, args: []Value) Error!Value {
    const d = try argDigest(th, args, 0);
    const data = try argBytes(th, args, 1, "data");
    inline for (digests, 0..) |entry, i| {
        if (i == d) {
            const H = entry[1];
            var out: [H.digest_length]u8 = undefined;
            H.hash(data, &out, .{});
            return th.vm.str(&out);
        }
    }
    unreachable;
}

/// hmac(digest, key, data) -> raw bytes
fn cryptoHmac(th: *Thread, args: []Value) Error!Value {
    const d = try argDigest(th, args, 0);
    const key = try argBytes(th, args, 1, "key");
    const data = try argBytes(th, args, 2, "data");
    inline for (digests, 0..) |entry, i| {
        if (i == d) {
            const M = Hmac(entry[1]);
            var out: [M.mac_length]u8 = undefined;
            M.create(&out, data, key);
            return th.vm.str(&out);
        }
    }
    unreachable;
}

/// random_bytes(n) -> n bytes from the system's secure source
fn randomBytes(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const n = try api.argInt(th, args, 0, "n");
    if (n < 0 or n > (1 << 20)) return vm.raiseKind("argument", "bad argument #1 to 'random_bytes' (a length from 0 to 1048576 expected)", .{});
    const buf = vm.gpa.alloc(u8, @intCast(n)) catch oom();
    defer vm.gpa.free(buf);
    vm.io.randomSecure(buf) catch return vm.raiseKind("error", "crypto: random_bytes: no entropy from the system", .{});
    return vm.str(buf);
}

/// equal(a, b): whether a and b are equal, in time that depends only on
/// their lengths (for MACs and tokens)
fn equal(th: *Thread, args: []Value) Error!Value {
    const a = try argBytes(th, args, 0, "a");
    const b = try argBytes(th, args, 1, "b");
    if (a.len != b.len) return .{ .bool = false };
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    std.mem.doNotOptimizeAway(&diff);
    return .{ .bool = diff == 0 };
}

// ---- streaming hashes ----

const hasher_tname = "crypto.hasher";

/// A hasher's running state, one field per entry of digests (same names).
const State = union {
    md5: hash.Md5,
    sha1: hash.Sha1,
    sha224: hash.sha2.Sha224,
    sha256: hash.sha2.Sha256,
    sha384: hash.sha2.Sha384,
    sha512: hash.sha2.Sha512,
    @"sha512-224": hash.sha2.Sha512_224,
    @"sha512-256": hash.sha2.Sha512_256,
    @"sha3-224": hash.sha3.Sha3_224,
    @"sha3-256": hash.sha3.Sha3_256,
    @"sha3-384": hash.sha3.Sha3_384,
    @"sha3-512": hash.sha3.Sha3_512,
    blake2b512: hash.blake2.Blake2b512,
    blake2s256: hash.blake2.Blake2s256,
};

const Hasher = struct {
    digest: usize,
    done: bool = false,
    state: State,
};

/// hasher(digest) -> a hasher: update(data) as often as needed, digest() once
fn newHasher(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const d = try argDigest(th, args, 0);
    var h: Hasher = .{ .digest = d, .state = undefined };
    inline for (digests, 0..) |entry, i| {
        if (i == d) h.state = @unionInit(State, entry[0], entry[1].init(.{}));
    }
    const u = vm.newUserdataOf(Hasher, h, hasher_tname, vm.type_metas.getName(hasher_tname).asTable());
    return .{ .userdata = u };
}

fn checkHasher(th: *Thread, args: []Value) Error!*Hasher {
    const h = try api.argUserdata(th, args, 0, "hasher", Hasher, hasher_tname);
    if (h.done) return th.vm.raiseKind("state", "crypto: the hasher has already given its digest", .{});
    return h;
}

fn hasherUpdate(th: *Thread, args: []Value) Error!Value {
    const h = try checkHasher(th, args);
    const data = try argBytes(th, args, 1, "data");
    inline for (digests, 0..) |entry, i| {
        if (i == h.digest) @field(h.state, entry[0]).update(data);
    }
    return args[0];
}

fn hasherDigest(th: *Thread, args: []Value) Error!Value {
    const h = try checkHasher(th, args);
    h.done = true;
    inline for (digests, 0..) |entry, i| {
        if (i == h.digest) {
            var out: [entry[1].digest_length]u8 = undefined;
            @field(h.state, entry[0]).final(&out);
            return th.vm.str(&out);
        }
    }
    unreachable;
}

// ---- key derivation (synchronous, or on libuv's pool) ----

/// A derivation, its inputs copied (the pool's thread may not touch slang).
const Kdf = struct {
    scrypt: bool,
    digest: usize = 0,
    password: []u8,
    salt: []u8,
    iterations: u32 = 0,
    ln: u6 = 0,
    r: u30 = 0,
    p: u30 = 0,
    out: []u8,
    ok: bool = false,
    err: []const u8 = "",

    const gpa = std.heap.page_allocator;

    fn run(k: *Kdf) void {
        if (k.scrypt) {
            std.crypto.pwhash.scrypt.kdf(gpa, k.out, k.password, k.salt, .{ .ln = k.ln, .r = k.r, .p = k.p }) catch |e| {
                k.err = switch (e) {
                    error.OutOfMemory => "crypto: scrypt: out of memory",
                    else => "crypto: scrypt: bad parameters",
                };
                return;
            };
        } else {
            inline for (digests, 0..) |entry, i| {
                if (i == k.digest) {
                    std.crypto.pwhash.pbkdf2(k.out, k.password, k.salt, k.iterations, Hmac(entry[1])) catch {
                        k.err = "crypto: pbkdf2: bad parameters";
                        return;
                    };
                }
            }
        }
        k.ok = true;
    }

    fn free(k: *Kdf) void {
        std.crypto.secureZero(u8, k.password);
        std.crypto.secureZero(u8, k.out);
        gpa.free(k.password);
        gpa.free(k.salt);
        gpa.free(k.out);
        gpa.destroy(k);
    }
};

fn checkOutLen(vm: *VM, n: i64, arg: usize) Error!usize {
    if (n < 1 or n > 4096) return vm.raiseKind("argument", "bad argument #{d} (an output length from 1 to 4096 expected)", .{arg});
    return @intCast(n);
}

fn newKdf(scrypt_kind: bool, password: []const u8, salt: []const u8, out_len: usize) *Kdf {
    const gpa = Kdf.gpa;
    const k = gpa.create(Kdf) catch oom();
    k.* = .{
        .scrypt = scrypt_kind,
        .password = gpa.dupe(u8, password) catch oom(),
        .salt = gpa.dupe(u8, salt) catch oom(),
        .out = gpa.alloc(u8, out_len) catch oom(),
    };
    return k;
}

/// The scrypt parameters n, r and p checked: n a power of two above 1.
fn scryptParams(vm: *VM, n: i64, r: i64, p: i64) Error!struct { u6, u30, u30 } {
    if (n < 2 or (n & (n - 1)) != 0 or r < 1 or p < 1 or r >= 1 << 30 or p >= 1 << 30)
        return vm.raiseKind("argument", "crypto: scrypt: n must be a power of two above 1, r and p positive", .{});
    return .{ @intCast(std.math.log2_int(u64, @intCast(n))), @intCast(r), @intCast(p) };
}

fn finishSync(vm: *VM, k: *Kdf) Error!Value {
    defer k.free();
    k.run();
    if (!k.ok) return vm.raiseKind("argument", "{s}", .{k.err});
    return vm.str(k.out);
}

/// pbkdf2(digest, password, salt, iterations, length)
fn pbkdf2(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const d = try argDigest(th, args, 0);
    const password = try argBytes(th, args, 1, "password");
    const salt = try argBytes(th, args, 2, "salt");
    const iterations = try api.argInt(th, args, 3, "iterations");
    const out_len = try checkOutLen(vm, try api.argInt(th, args, 4, "length"), 5);
    if (iterations < 1 or iterations > std.math.maxInt(u32)) return vm.raiseKind("argument", "bad argument #4 to 'pbkdf2' (at least one iteration expected)", .{});
    const k = newKdf(false, password, salt, out_len);
    k.digest = d;
    k.iterations = @intCast(iterations);
    return finishSync(vm, k);
}

/// scrypt(password, salt, n, r, p, length): n a power of two
fn scrypt(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const password = try argBytes(th, args, 0, "password");
    const salt = try argBytes(th, args, 1, "salt");
    const n = try api.argInt(th, args, 2, "n");
    const r = try api.argInt(th, args, 3, "r");
    const p = try api.argInt(th, args, 4, "p");
    const out_len = try checkOutLen(vm, try api.argInt(th, args, 5, "length"), 6);
    const params = try scryptParams(vm, n, r, p);
    const k = newKdf(true, password, salt, out_len);
    k.ln, k.r, k.p = params;
    return finishSync(vm, k);
}

// The _async forms are written against slang.h (as the crypto extension's
// were): the uv extension's C API queues work on libuv's pool and calls
// the callback, at a stack index, with (err, key).

const UvApi = extern struct {
    version: c_int,
    queue: *const fn (
        th: *Thread,
        cb_idx: c_int,
        keep_idx: c_int,
        work: *const fn (?*anyopaque) callconv(.c) void,
        push: *const fn (*Thread, ?*anyopaque) callconv(.c) c_int,
        done: *const fn (?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
    ) callconv(.c) c_int,
};

const SLANG_ERROR: c_int = -1;

fn uvApi(th: *Thread) ?*const UvApi {
    const top = capi.slang_gettop(th);
    defer capi.slang_settop(th, top);
    capi.slang_getglobal(th, "require");
    capi.slang_pushstring(th, "uv");
    if (capi.slang_call(th, 1) != 0) return null;
    _ = capi.slang_getfield(th, -1, "c_api");
    const box: ?*const ?*const UvApi = @ptrCast(@alignCast(capi.slang_testudata(th, -1, "uv.c_api")));
    const a = (box orelse return null).* orelse return null;
    if (a.version < 1) return null;
    return a;
}

fn kdfWork(data: ?*anyopaque) callconv(.c) void {
    const k: *Kdf = @ptrCast(@alignCast(data.?));
    k.run();
}

fn kdfPush(th: *Thread, data: ?*anyopaque) callconv(.c) c_int {
    const k: *Kdf = @ptrCast(@alignCast(data.?));
    if (!k.ok) {
        capi.slang_pushlstring(th, k.err.ptr, k.err.len);
        capi.slang_pushnull(th);
    } else {
        capi.slang_pushnull(th);
        capi.slang_pushlstring(th, k.out.ptr, k.out.len);
    }
    return 2;
}

fn kdfDone(data: ?*anyopaque) callconv(.c) void {
    const k: *Kdf = @ptrCast(@alignCast(data.?));
    k.free();
}

/// The bytes at idx (a string or a buffer), or null after raising.
fn checkBytes(th: *Thread, idx: c_int) ?[]const u8 {
    var n: usize = 0;
    const p = capi.slang_checkbytes(th, idx, &n) orelse return null;
    return p[0..n];
}

fn queueKdf(th: *Thread, cb_idx: c_int, k: *Kdf) c_int {
    const a = uvApi(th) orelse {
        k.free();
        if (th.vm.err == null) th.vm.setErrorKind("unsupported", "crypto: the uv extension does not offer a compatible C API", .{});
        return SLANG_ERROR;
    };
    return a.queue(th, cb_idx, 0, kdfWork, kdfPush, kdfDone, k);
}

/// pbkdf2_async(digest, password, salt, iterations, length, cb)
fn pbkdf2Async(th: *Thread) callconv(.c) c_int {
    capi.slang_checkfunction(th, 6);
    var name_len: usize = 0;
    const name = capi.slang_checklstring(th, 1, &name_len);
    const password = checkBytes(th, 2);
    const salt = checkBytes(th, 3);
    const iterations = capi.slang_checkint(th, 4);
    const out_len = capi.slang_checkint(th, 5);
    if (capi.slang_failed(th)) return SLANG_ERROR;
    const d = digestIndex(name[0..name_len]) orelse {
        th.vm.setErrorKind("argument", "crypto: unknown digest {s}", .{name[0..name_len]});
        return SLANG_ERROR;
    };
    if (out_len < 1 or out_len > 4096) return capi.slang_argerror(th, 5, "an output length from 1 to 4096 expected");
    if (iterations < 1 or iterations > std.math.maxInt(u32)) return capi.slang_argerror(th, 4, "at least one iteration expected");
    const k = newKdf(false, password.?, salt.?, @intCast(out_len));
    k.digest = d;
    k.iterations = @intCast(iterations);
    return queueKdf(th, 6, k);
}

/// scrypt_async(password, salt, n, r, p, length, cb)
fn scryptAsync(th: *Thread) callconv(.c) c_int {
    capi.slang_checkfunction(th, 7);
    const password = checkBytes(th, 1);
    const salt = checkBytes(th, 2);
    const n = capi.slang_checkint(th, 3);
    const r = capi.slang_checkint(th, 4);
    const p = capi.slang_checkint(th, 5);
    const out_len = capi.slang_checkint(th, 6);
    if (capi.slang_failed(th)) return SLANG_ERROR;
    if (out_len < 1 or out_len > 4096) return capi.slang_argerror(th, 6, "an output length from 1 to 4096 expected");
    const params = scryptParams(th.vm, n, r, p) catch return SLANG_ERROR;
    const k = newKdf(true, password.?, salt.?, @intCast(out_len));
    k.ln, k.r, k.p = params;
    return queueKdf(th, 7, k);
}

// ---- authenticated encryption ----

const aes_gcm = std.crypto.aead.aes_gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const ciphers = .{
    .{ "aes-128-gcm", aes_gcm.Aes128Gcm },
    .{ "aes-256-gcm", aes_gcm.Aes256Gcm },
    .{ "chacha20-poly1305", ChaCha20Poly1305 },
};

const tag_len = 16;

fn argCipher(th: *Thread, args: []Value) Error!usize {
    const name = try api.argString(th, args, 0, "cipher");
    inline for (ciphers, 0..) |c, i| {
        if (std.ascii.eqlIgnoreCase(name, c[0])) return i;
    }
    return th.vm.raiseKind("argument", "bad argument #1 (\"aes-128-gcm\", \"aes-256-gcm\" or \"chacha20-poly1305\" expected)", .{});
}

/// The key and the iv checked for cipher C: {key, iv}.
fn keyAndIv(th: *Thread, args: []Value, comptime C: type, name: []const u8) Error!struct { [C.key_length]u8, [C.nonce_length]u8 } {
    const vm = th.vm;
    const key = try argBytes(th, args, 1, "key");
    const iv = try argBytes(th, args, 2, "iv");
    if (key.len != C.key_length) return vm.raiseKind("argument", "crypto: {s} needs a {d}-byte key, got {d} bytes", .{ name, C.key_length, key.len });
    if (iv.len != C.nonce_length) return vm.raiseKind("argument", "crypto: the iv must be {d} bytes, got {d}", .{ C.nonce_length, iv.len });
    return .{ key[0..C.key_length].*, iv[0..C.nonce_length].* };
}

fn aad(th: *Thread, args: []Value) Error![]const u8 {
    if (api.arg(args, 4) == .null) return "";
    return argBytes(th, args, 4, "aad");
}

/// encrypt(cipher, key, iv, plaintext, [aad]) -> ciphertext followed by the tag
fn encrypt(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const c = try argCipher(th, args);
    const plain = try argBytes(th, args, 3, "plaintext");
    const ad = try aad(th, args);
    inline for (ciphers, 0..) |entry, i| {
        if (i == c) {
            const C = entry[1];
            const key, const iv = try keyAndIv(th, args, C, entry[0]);
            const out = vm.gpa.alloc(u8, plain.len + tag_len) catch oom();
            defer vm.gpa.free(out);
            C.encrypt(out[0..plain.len], out[plain.len..][0..tag_len], plain, ad, iv, key);
            return vm.str(out);
        }
    }
    unreachable;
}

/// decrypt(cipher, key, iv, sealed, [aad]) -> plaintext, or null when the
/// data, the aad, the key or the iv do not match
fn decrypt(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const c = try argCipher(th, args);
    const sealed = try argBytes(th, args, 3, "sealed");
    const ad = try aad(th, args);
    inline for (ciphers, 0..) |entry, i| {
        if (i == c) {
            const C = entry[1];
            const key, const iv = try keyAndIv(th, args, C, entry[0]);
            if (sealed.len < tag_len) return .null;
            const n = sealed.len - tag_len;
            const out = vm.gpa.alloc(u8, n) catch oom();
            defer {
                std.crypto.secureZero(u8, out);
                vm.gpa.free(out);
            }
            C.decrypt(out, sealed[0..n], sealed[n..][0..tag_len].*, ad, iv, key) catch return .null;
            return vm.str(out);
        }
    }
    unreachable;
}
