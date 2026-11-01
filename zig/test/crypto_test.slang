// the crypto extension (OpenSSL), slang/crypto and slang/jwt
local t = require("slang/test")
local str = require("slang/string")
local native = require("crypto")
local crypto = require("slang/crypto")
local jwt = require("slang/jwt")
local e = require("slang/encoding")
local hex = e.hex.encode

local func fails_with(f, text){
  local r = pcall(f)
  assert(r[0] == "err", concat("should fail with ", text))
  assert(str.index_of(r[1].message, text) >= 0, r[1].message)
}

t.group("crypto binding"){
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
  }
  t.test("keys sign and verify; PEM round trips"){
    local specs = {
      {"rsa", 2048, "sha256", {}},
      {"rsa", 2048, "sha256", {padding: "pss"}},
      {"ec", "P-256", "sha256", {encoding: "raw"}},
      {"ec", "P-384", "sha384", {}},
      {"ed25519", null, null, {}},
    }
    for(let local s in values(specs)){
      local k = native.generate_key(s[0], s[1])
      assert(k:is_private() and k:type() == s[0])
      local sig = k:sign(s[2], "message", s[3])
      local pub = native.public_key(k:public_pem())
      assert(not pub:is_private())
      assert(pub:verify(s[2], "message", sig, s[3]), concat(s[0], " verifies"))
      assert(
        not pub:verify(s[2], "massage", sig, s[3]),
        concat(s[0], " rejects other data"),
      )
      local again = native.private_key(k:private_pem())
      assert(
        pub:verify(s[2], "x", again:sign(s[2], "x", s[3]), s[3]),
        concat(s[0], " from PEM"),
      )
    }
    local ec = native.generate_key("ec")
    assert(len(ec:sign("sha256", "m", {encoding: "raw"})) == 64)
    fails_with(func(){
      ec:public_key():sign("sha256", "m")
    }, "needs a private key")
    fails_with(func(){ native.private_key("junk") }, "crypto: private_key:")
    fails_with(func(){
      native.generate_key("dsa")
    }, "\"rsa\", \"ec\" or \"ed25519\" expected")
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
    local signed = crypto.sign_value("key", "user.42")
    assert(crypto.unsign_value("key", signed) == "user.42")
    assert(crypto.unsign_value("other", signed) == null)
    assert(crypto.unsign_value(
      "key",
      concat("user.43", str.substring(signed, 7)),
    ) == null)
    assert(crypto.unsign_value("key", "nodot") == null and crypto.unsign_value(
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

t.group("slang/jwt"){
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
  t.test("every algorithm round trips with the key that fits it"){
    local keys = {
      {"secret", "HS256"},
      {native.generate_key("rsa"), "RS256"},
      {native.generate_key("ec"), "ES256"},
      {native.generate_key("ec", "P-384"), "ES384"},
      {native.generate_key("ec", "P-521"), "ES512"},
      {native.generate_key("ed25519"), "EdDSA"},
    }
    for(let local k in values(keys)){
      local token = jwt.sign({sub: "ada", n: 1}, k[0], {
        expires_in: 60, issuer: "me"
      })
      assert(jwt.decode(token).header.alg == k[1], k[1])
      local verify_key = type(k[0]) == "string" and k[0] or k[0]:public_key()
      local c = jwt.verify(token, verify_key, {issuer: "me"})
      assert(c.sub == "ada" and c.n == 1 and c.iss == "me" and type(
          c.iat,
        ) == "int" and c.exp == c.iat + 60)
    }
    local rsa = native.generate_key("rsa")
    for(let local alg in values({"RS384", "RS512", "PS256", "PS512", "HS512"})){
      local k = str.starts_with(alg, "HS") and "s" or rsa
      local token = jwt.sign({}, k, {alg: alg})
      assert(jwt.verify(token, k, {alg: alg}) != null, alg)
    }
  }
  t.test("tokens that must not verify do not"){
    local rsa = native.generate_key("rsa")
    local hs = jwt.sign({a: 1}, "s")
    fails_with(func(){ jwt.verify(hs, "t") }, "jwt: bad signature")
    fails_with(func(){ jwt.verify(concat(hs, "x"), "s") }, "jwt: bad signature")
    fails_with(func(){
      jwt.verify("eyJhbGciOiJub25lIn0.eyJhIjoxfQ.", "s")
    }, "jwt: algorithm none not accepted")
    fails_with(func(){
      jwt.verify(jwt.sign({}, rsa, {alg: "PS256"}), rsa)
    }, "algorithm PS256 not accepted")
    // the classic confusion: HS256 keyed with the RSA public key's PEM
    local confused = jwt.sign({a: 1}, rsa:public_pem(), {alg: "HS256"})
    fails_with(func(){
      jwt.verify(confused, rsa:public_key(), {algs: {"HS256", "RS256"}})
    }, "the key does not fit HS256")
    fails_with(func(){ jwt.verify("a.b", "s") }, "jwt: malformed token")
    fails_with(func(){ jwt.verify("e30.e30.!!!", "s") }, "jwt: malformed token")
    fails_with(func(){
      jwt.verify(jwt.sign({}, "s", {not_before: 100}), "s")
    }, "jwt: not valid yet")
    fails_with(func(){
      jwt.verify(jwt.sign({}, "s", {issuer: "a"}), "s", {issuer: "b"})
    }, "jwt: wrong issuer")
    assert(jwt.verify(jwt.sign({}, "s", {audience: {"x", "y"}}), "s", {
      audience: "y",
    }) != null)
    fails_with(func(){
      jwt.verify(jwt.sign({}, "s", {audience: "x"}), "s", {audience: "z"})
    }, "jwt: wrong audience")
    fails_with(func(){
      jwt.sign({}, rsa:public_key())
    }, "jwt: signing needs a private key")
    fails_with(func(){ jwt.sign({}, 42) }, "jwt: a key must be")
  }
}
