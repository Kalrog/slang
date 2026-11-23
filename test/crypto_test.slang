// slang/crypto (its own hashes, MACs, key derivation and encryption, on
// every platform) and slang/jwt with secrets; keys are in
// zig/test/crypto_test.slang (OpenSSL)
local t = require("slang/test")
local str = require("slang/string")
local buffer = require("slang/buffer")
local native = require("slang/crypto")
local crypto = native
local jwt = require("slang/jwt")
local e = require("slang/encoding")
local hex = e.hex.encode

// the error f raises; its message must contain text
local func fails_with(f, text){
  local e = t.raises(f)
  assert(str.index_of(e.message, text) >= 0, e.message)
  return e
}

t.group("crypto: hashes, MACs, derivation, encryption"){
  t.test("hashes and HMAC match the published vectors"){
    assert(hex(
      native.hash("sha256", "abc"),
    ) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    assert(hex(
      native.hash("sha1", "abc"),
    ) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert(hex(
      native.hash("sha512", ""),
    ) == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    assert(hex(native.hash("md5", "")) == "d41d8cd98f00b204e9800998ecf8427e")
    // RFC 4231 test case 2
    assert(hex(native.hmac(
      "sha256", "Jefe", "what do ya want for nothing?"
    )) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    assert(
      hex(native.hasher("sha256"):update("a"):update("bc"):digest()) ==
        hex(native.hash("sha256", "abc")),
    )
    fails_with(func(){
      native.hash("sha999", "x")
    }, "crypto: unknown digest sha999")
    local h = native.hasher("sha1")
    h:digest()
    fails_with(func(){ h:update("x") }, "already given its digest")
  }
  t.test("key derivation matches the RFC vectors, also on the pool"){
    assert(hex(
      native.pbkdf2("sha256", "password", "salt", 1, 32),
    ) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    // RFC 7914, section 12
    local want = "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
    assert(hex(native.scrypt("password", "NaCl", 1024, 8, 16, 64)) == want)
    local got = null
    native.scrypt_async("password", "NaCl", 1024, 8, 16, 64, func(err, key){
      got = hex(key)
    })
    require("uv").run()
    assert(got == want)
    fails_with(func(){
      native.scrypt("p", "s", 1000, 8, 1, 32)
    }, "power of two")
  }
  t.test("random bytes and constant-time comparison"){
    assert(len(native.random_bytes(0)) == 0 and len(
        native.random_bytes(33),
      ) == 33)
    assert(native.random_bytes(16) != native.random_bytes(16))
    assert(
      native.equal("abc", "abc") and not native.equal("abc", "abd") and
        not native.equal("ab", "abc"),
    )
  }
  t.test("authenticated encryption rejects anything changed"){
    for(let local cipher in values({
      "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305"
    })){
      local key = native.random_bytes(cipher == "aes-128-gcm" and 16 or 32)
      local iv = native.random_bytes(12)
      local sealed = native.encrypt(cipher, key, iv, "attack at dawn", "header")
      assert(len(sealed) == 14 + 16)
      assert(
        native.decrypt(cipher, key, iv, sealed, "header") == "attack at dawn",
        cipher,
      )
      assert(native.decrypt(cipher, key, iv, sealed, "other") == null, "aad")
      assert(
        native.decrypt(
          cipher, key, native.random_bytes(12), sealed, "header"
        ) == null,
        "iv",
      )
      // a different byte at 3 (a fixed "X" is the same byte one time in 256)
      local other = str.from_bytes({(str.byte_at(sealed, 3) + 1) & 255})
      local flipped = concat(
        str.substring(sealed, 0, 3),
        other,
        str.substring(sealed, 4),
      )
      assert(
        native.decrypt(cipher, key, iv, flipped, "header") == null,
        "ciphertext",
      )
    }
    fails_with(func(){
      native.encrypt("aes-256-gcm", "short", native.random_bytes(12), "x")
    }, "needs a 32-byte key")
    fails_with(func(){ native.encrypt("des", "k", "iv", "x") }, "aes-128-gcm")
  }  t.test("more digests and HMACs match the published vectors"){
    assert(hex(native.hash("sha3-256", "abc")) ==
      "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    assert(hex(native.hash("blake2b512", "abc")) ==
      "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    assert(hex(native.hash("SHA256", "abc")) == hex(native.hash("sha256", "abc")))
    // RFC 4231 test case 2, SHA-512
    assert(hex(native.hmac(
      "sha512", "Jefe", "what do ya want for nothing?"
    )) == "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737")
    // a buffer's bytes as well as a string's
    local b = buffer.from_string("abc")
    assert(native.hash("sha256", b) == native.hash("sha256", "abc"))
  }
  t.test("AES-GCM matches the published vector"){
    // McGrew and Viega's GCM test case 2: zero key, iv and block
    local func zeros(n){
      local bytes = {}
      for(local i = 0; i < n; i = i + 1){ append(bytes, 0) }
      return str.from_bytes(bytes)
    }
    local zero = zeros(16)
    local sealed = native.encrypt("aes-128-gcm", zero, zeros(12), zero)
    assert(hex(sealed) ==
      "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf", hex(sealed))
    fails_with(func(){
      native.encrypt("aes-256-gcm", native.random_bytes(32), "short iv", "x")
    }, "the iv must be 12 bytes")
  }
}

t.group("slang/crypto"){
  t.test("password hashes verify and resist tampering"){
    local h = crypto.hash_password("hunter2")
    assert(str.starts_with(h, "$scrypt$ln=15,r=8,p=1$"), h)
    assert(crypto.verify_password("hunter2", h))
    assert(not crypto.verify_password("hunter3", h))
    assert(crypto.hash_password("hunter2") != h, "salted")
    assert(
      not crypto.verify_password("x", "junk") and
        not crypto.verify_password("x", null),
    )
    assert(
      not crypto.verify_password("x", "$scrypt$ln=99,r=8,p=1$AAAA$AAAA"),
      "absurd parameters",
    )
    // a PBKDF2 hash from elsewhere
    local salt = "saltsaltsaltsalt"
    local stored = concat(
      "$pbkdf2-sha256$i=1000$",
      e.base64.encode(salt),
      "$",
      e.base64.encode(native.pbkdf2("sha256", "pw", salt, 1000, 32)),
    )
    assert(crypto.verify_password("pw", stored) and not crypto.verify_password(
        "pv", stored
      ))
  }
  t.test("the async password functions are futures"){
    local async = require("slang/async")
    async.main(func(){
      local h = async.await(crypto.hash_password_async("s3cret"))
      assert(async.await(crypto.verify_password_async("s3cret", h)) == true)
      assert(async.await(crypto.verify_password_async("nope", h)) == false)
      assert(async.await(crypto.verify_password_async("nope", "junk")) == false)
    })
  }
  t.test("signed values and sealed values"){
    local signed = crypto.sign("key", "user.42")
    assert(crypto.verify_signed("key", signed) == "user.42")
    assert(crypto.verify_signed("other", signed) == null)
    assert(crypto.verify_signed(
      "key",
      concat("user.43", str.substring(signed, 7)),
    ) == null)
    assert(crypto.verify_signed("key", "nodot") == null and crypto.verify_signed(
        "key", null
      ) == null)
    local k = native.random_bytes(32)
    local sealed = crypto.seal(k, "private", "ctx")
    assert(crypto.unseal(k, sealed, "ctx") == "private")
    assert(crypto.unseal(k, sealed, "other") == null and crypto.unseal(
        native.random_bytes(32), sealed, "ctx"
      ) == null)
    assert(crypto.unseal(k, "!!") == null and crypto.unseal(k, null) == null)
    assert(len(crypto.token()) == 43 and crypto.hex(
        "sha1", "abc"
      ) == "a9993e364706816aba3e25717850c26c9cd0d89d")
  }
}

t.group("slang/jwt with secrets"){
  // RFC 7515, appendix A.1
  local rfc_key = e.base64url.decode(
    "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow",
  )
  local rfc_token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  t.test("the RFC 7515 example verifies, and expires on time"){
    local c = jwt.verify(rfc_token, rfc_key, {now: 1300819379})
    assert(c.iss == "joe" and c["http://example.com/is_root"] == true)
    fails_with(func(){
      jwt.verify(rfc_token, rfc_key, {now: 1300819380})
    }, "jwt: expired")
    assert(jwt.verify(rfc_token, rfc_key, {
      now: 1300819385, leeway: 10
    }).iss == "joe")
    assert(jwt.decode(rfc_token).header.alg == "HS256")
  }
}
