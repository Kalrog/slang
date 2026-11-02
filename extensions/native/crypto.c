/*
 * crypto: a native extension exposing the parts of OpenSSL 3 (libcrypto)
 * that web applications need; slang/crypto and slang/jwt build on it.
 *
 *   local crypto = require("crypto")
 *   crypto.hash("sha256", "abc")               -> 32 raw bytes
 *   crypto.hmac("sha256", key, data)            -> raw bytes
 *   crypto.random_bytes(32)
 *   crypto.equal(a, b)                          constant-time comparison
 *   crypto.pbkdf2("sha256", password, salt, iterations, length)
 *   crypto.scrypt(password, salt, n, r, p, length)
 *   crypto.pbkdf2_async(..., cb) / crypto.scrypt_async(..., cb)
 *                                               on libuv's thread pool
 *   crypto.hasher("sha256"):update(data):digest()
 *   crypto.encrypt(cipher, key, iv, plaintext, [aad]) -> ciphertext .. tag
 *   crypto.decrypt(cipher, key, iv, sealed, [aad])    -> plaintext or null
 *   crypto.private_key(pem, [passphrase]), crypto.public_key(pem),
 *   crypto.generate_key("rsa", bits | "ec", curve | "ed25519") -> key
 *   key:sign(digest, data, [options]), key:verify(digest, data, signature,
 *   [options]), key.type, key.bits, key.private, key:public_pem(),
 *   key:private_pem(), key:public_key()
 *
 * Digests are OpenSSL names ("sha1", "sha256", "sha384", "sha512",
 * "sha3-256", "md5", ...). Results are raw byte strings; slang/encoding
 * makes hex or base64 of them. Ciphers are AEADs: "aes-128-gcm",
 * "aes-256-gcm", "chacha20-poly1305"; the 16-byte tag follows the
 * ciphertext, and decrypt returns null when it does not match. Signing
 * options: {padding: "pss"} for RSA-PSS (salt as long as the digest), and
 * {encoding: "raw"} for ECDSA signatures as r || s (the JWT form) instead
 * of DER. Ed25519 ignores the digest (pass null). Errors are raised with
 * OpenSSL's message.
 */
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "slang.h"
#include "slang_uv.h"

static const char *key_tname = "crypto.key";
static const char *hasher_tname = "crypto.hasher";

/* raises "crypto: <what>: <openssl's reason>" and clears the error queue */
static int ssl_error(slang_State *S, const char *what) {
    unsigned long e = ERR_get_error();
    char buf[256] = "unknown error";
    if (e != 0) ERR_error_string_n(e, buf, sizeof buf);
    ERR_clear_error();
    return slang_error(S, "crypto: %s: %s", what, buf);
}

static EVP_MD *fetch_md(slang_State *S, int idx) {
    const char *name = slang_checklstring(S, idx, NULL);
    if (name == NULL) return NULL;
    EVP_MD *md = EVP_MD_fetch(NULL, name, NULL);
    if (md == NULL) {
        ERR_clear_error();
        slang_error(S, "crypto: unknown digest %s", name);
    }
    return md;
}

/* ---- hashes and MACs ---- */

/* hash(digest, data) -> raw bytes */
static int l_hash(slang_State *S) {
    EVP_MD *md = fetch_md(S, 1);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (md == NULL || data == NULL) {
        EVP_MD_free(md);
        return SLANG_ERROR;
    }
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    int ok = EVP_Digest(data, len, out, &n, md, NULL);
    EVP_MD_free(md);
    if (!ok) return ssl_error(S, "hash");
    slang_pushlstring(S, (const char *)out, n);
    return 1;
}

/* hmac(digest, key, data) -> raw bytes */
static int l_hmac(slang_State *S) {
    const char *name = slang_checklstring(S, 1, NULL);
    size_t klen = 0, dlen = 0;
    const char *key = slang_checkbytes(S, 2, &klen);
    const char *data = slang_checkbytes(S, 3, &dlen);
    if (slang_failed(S)) return SLANG_ERROR;
    unsigned char out[EVP_MAX_MD_SIZE];
    size_t n = 0;
    if (EVP_Q_mac(NULL, "HMAC", NULL, name, NULL, key, klen, (const unsigned char *)data, dlen, out, sizeof out, &n) == NULL)
        return ssl_error(S, "hmac");
    slang_pushlstring(S, (const char *)out, n);
    return 1;
}

static int l_random_bytes(slang_State *S) {
    int64_t n = slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    if (n < 0 || n > (1 << 20)) return slang_argerror(S, 1, "a length from 0 to 1048576 expected");
    unsigned char *buf = malloc(n > 0 ? (size_t)n : 1);
    if (RAND_bytes(buf, (int)n) != 1) {
        free(buf);
        return ssl_error(S, "random_bytes");
    }
    slang_pushlstring(S, (const char *)buf, (size_t)n);
    free(buf);
    return 1;
}

/* equal(a, b): true when the strings are equal, in time that depends only
 * on their lengths (for comparing MACs and tokens) */
static int l_equal(slang_State *S) {
    size_t alen = 0, blen = 0;
    const char *a = slang_checkbytes(S, 1, &alen);
    const char *b = slang_checkbytes(S, 2, &blen);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushbool(S, alen == blen && CRYPTO_memcmp(a, b, alen) == 0);
    return 1;
}

/* ---- streaming hashes ---- */

typedef struct hasher {
    EVP_MD_CTX *ctx;
    int done;
} hasher;

static void hasher_finalize(void *data) {
    hasher *h = data;
    EVP_MD_CTX_free(h->ctx);
    h->ctx = NULL;
}

/* hasher(digest) -> a hasher: update(data) as often as needed, digest() once */
static int l_hasher(slang_State *S) {
    EVP_MD *md = fetch_md(S, 1);
    if (md == NULL) return SLANG_ERROR;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int ok = ctx != NULL && EVP_DigestInit_ex2(ctx, md, NULL);
    EVP_MD_free(md);
    if (!ok) {
        EVP_MD_CTX_free(ctx);
        return ssl_error(S, "hasher");
    }
    hasher *h = slang_newuserdata(S, sizeof(hasher), hasher_tname, hasher_finalize);
    h->ctx = ctx;
    return 1;
}

static hasher *check_hasher(slang_State *S) {
    hasher *h = slang_checkudata(S, 1, hasher_tname);
    if (h == NULL) return NULL;
    if (h->done) {
        slang_error(S, "crypto: the hasher has already given its digest");
        return NULL;
    }
    return h;
}

static int hasher_update(slang_State *S) {
    hasher *h = check_hasher(S);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (h == NULL || data == NULL) return SLANG_ERROR;
    if (!EVP_DigestUpdate(h->ctx, data, len)) return ssl_error(S, "update");
    slang_pushvalue(S, 1);
    return 1;
}

static int hasher_digest(slang_State *S) {
    hasher *h = check_hasher(S);
    if (h == NULL) return SLANG_ERROR;
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    h->done = 1;
    if (!EVP_DigestFinal_ex(h->ctx, out, &n)) return ssl_error(S, "digest");
    slang_pushlstring(S, (const char *)out, n);
    return 1;
}

/* ---- key derivation (synchronous, or on the pool) ---- */

typedef struct kdf_job {
    int scrypt;
    char *md_name;
    char *password, *salt;
    size_t plen, slen, outlen;
    uint64_t n, r, p;
    int64_t iterations;
    unsigned char *out;
    int ok;
    char err[256];
} kdf_job;

static void kdf_run(kdf_job *j) {
    j->out = malloc(j->outlen > 0 ? j->outlen : 1);
    if (j->scrypt) {
        uint64_t maxmem = 128 * j->r * (j->n + j->p + 2) + (1 << 20);
        j->ok = EVP_PBE_scrypt(j->password, j->plen, (const unsigned char *)j->salt, j->slen,
                               j->n, j->r, j->p, maxmem, j->out, j->outlen) == 1;
    } else {
        EVP_MD *md = EVP_MD_fetch(NULL, j->md_name, NULL);
        j->ok = md != NULL && PKCS5_PBKDF2_HMAC(j->password, (int)j->plen, (const unsigned char *)j->salt, (int)j->slen,
                                                 (int)j->iterations, md, (int)j->outlen, j->out) == 1;
        EVP_MD_free(md);
    }
    if (!j->ok) {
        unsigned long e = ERR_get_error();
        snprintf(j->err, sizeof j->err, "crypto: %s: ", j->scrypt ? "scrypt" : "pbkdf2");
        size_t used = strlen(j->err);
        if (e != 0) ERR_error_string_n(e, j->err + used, sizeof j->err - used);
        else snprintf(j->err + used, sizeof j->err - used, "%s", j->scrypt ? "bad parameters" : "unknown digest");
        ERR_clear_error();
    }
}

static void kdf_free(void *data) {
    kdf_job *j = data;
    if (j->password) OPENSSL_cleanse(j->password, j->plen);
    free(j->password);
    free(j->salt);
    free(j->md_name);
    if (j->out) OPENSSL_cleanse(j->out, j->outlen);
    free(j->out);
    free(j);
}

static char *copy_arg(slang_State *S, int idx, size_t *len) {
    size_t n = 0;
    const char *s = slang_checkbytes(S, idx, &n);
    if (s == NULL) return NULL;
    char *d = malloc(n + 1);
    memcpy(d, s, n);
    d[n] = 0;
    *len = n;
    return d;
}

static int check_outlen(slang_State *S, int idx, size_t *out) {
    int64_t n = slang_checkint(S, idx);
    if (slang_failed(S)) return 0;
    if (n < 1 || n > 4096) {
        slang_argerror(S, idx, "an output length from 1 to 4096 expected");
        return 0;
    }
    *out = (size_t)n;
    return 1;
}

/* pbkdf2(digest, password, salt, iterations, length) */
static kdf_job *pbkdf2_args(slang_State *S) {
    kdf_job *j = calloc(1, sizeof(kdf_job));
    size_t ignore = 0;
    j->md_name = copy_arg(S, 1, &ignore);
    j->password = copy_arg(S, 2, &j->plen);
    j->salt = copy_arg(S, 3, &j->slen);
    j->iterations = slang_checkint(S, 4);
    if (slang_failed(S) || !check_outlen(S, 5, &j->outlen)) {
        kdf_free(j);
        return NULL;
    }
    if (j->iterations < 1) {
        kdf_free(j);
        slang_argerror(S, 4, "at least one iteration expected");
        return NULL;
    }
    return j;
}

/* scrypt(password, salt, n, r, p, length): n a power of two */
static kdf_job *scrypt_args(slang_State *S) {
    kdf_job *j = calloc(1, sizeof(kdf_job));
    j->scrypt = 1;
    j->password = copy_arg(S, 1, &j->plen);
    j->salt = copy_arg(S, 2, &j->slen);
    int64_t n = slang_checkint(S, 3), r = slang_checkint(S, 4), p = slang_checkint(S, 5);
    if (slang_failed(S) || !check_outlen(S, 6, &j->outlen)) {
        kdf_free(j);
        return NULL;
    }
    if (n < 2 || (n & (n - 1)) != 0 || r < 1 || p < 1) {
        kdf_free(j);
        slang_error(S, "crypto: scrypt: n must be a power of two above 1, r and p positive");
        return NULL;
    }
    j->n = (uint64_t)n;
    j->r = (uint64_t)r;
    j->p = (uint64_t)p;
    return j;
}

static int kdf_sync(slang_State *S, kdf_job *j) {
    if (j == NULL) return SLANG_ERROR;
    kdf_run(j);
    if (!j->ok) {
        slang_error(S, "%s", j->err);
        kdf_free(j);
        return SLANG_ERROR;
    }
    slang_pushlstring(S, (const char *)j->out, j->outlen);
    kdf_free(j);
    return 1;
}

static int l_pbkdf2(slang_State *S) { return kdf_sync(S, pbkdf2_args(S)); }
static int l_scrypt(slang_State *S) { return kdf_sync(S, scrypt_args(S)); }

static void kdf_work(void *data) { kdf_run(data); }

static int kdf_push(slang_State *S, void *data) {
    kdf_job *j = data;
    if (!j->ok) {
        slang_pushstring(S, j->err);
        slang_pushnull(S);
    } else {
        slang_pushnull(S);
        slang_pushlstring(S, (const char *)j->out, j->outlen);
    }
    return 2;
}

static const slang_uv_api *uv_api = NULL;

static const slang_uv_api *get_uv_api(slang_State *S) {
    if (uv_api != NULL) return uv_api;
    int top = slang_gettop(S);
    slang_getglobal(S, "require");
    slang_pushstring(S, "uv");
    if (slang_call(S, 1) != SLANG_OK) return NULL;
    slang_getfield(S, -1, "c_api");
    uv_api = slang_uv_get(S, -1);
    slang_settop(S, top);
    if (uv_api == NULL) slang_error(S, "crypto: the uv extension does not offer a compatible C API");
    return uv_api;
}

/* the *_async forms take the same arguments and a callback cb(err, key) */
static int kdf_async(slang_State *S, kdf_job *(*args)(slang_State *), int cb_idx) {
    slang_checkfunction(S, cb_idx);
    if (slang_failed(S)) return SLANG_ERROR;
    const slang_uv_api *api = get_uv_api(S);
    if (api == NULL) return SLANG_ERROR;
    kdf_job *j = args(S);
    if (j == NULL) return SLANG_ERROR;
    return api->queue(S, cb_idx, 0, kdf_work, kdf_push, kdf_free, j);
}

static int l_pbkdf2_async(slang_State *S) { return kdf_async(S, pbkdf2_args, 6); }
static int l_scrypt_async(slang_State *S) { return kdf_async(S, scrypt_args, 7); }

/* ---- authenticated encryption ---- */

static EVP_CIPHER *fetch_cipher(slang_State *S, int idx) {
    const char *name = slang_checklstring(S, idx, NULL);
    if (name == NULL) return NULL;
    if (strcasecmp(name, "aes-128-gcm") != 0 && strcasecmp(name, "aes-256-gcm") != 0 &&
        strcasecmp(name, "chacha20-poly1305") != 0) {
        slang_argerror(S, idx, "\"aes-128-gcm\", \"aes-256-gcm\" or \"chacha20-poly1305\" expected");
        return NULL;
    }
    EVP_CIPHER *c = EVP_CIPHER_fetch(NULL, name, NULL);
    if (c == NULL) ssl_error(S, name);
    return c;
}

#define TAG_LEN 16

/* encrypt and decrypt share the setup: cipher, key and iv checked */
static EVP_CIPHER_CTX *aead_init(slang_State *S, int encrypt) {
    EVP_CIPHER *c = fetch_cipher(S, 1);
    size_t klen = 0, ivlen = 0;
    const char *key = slang_checkbytes(S, 2, &klen);
    const char *iv = slang_checkbytes(S, 3, &ivlen);
    if (c == NULL || slang_failed(S)) {
        EVP_CIPHER_free(c);
        return NULL;
    }
    if ((int)klen != EVP_CIPHER_get_key_length(c)) {
        slang_error(S, "crypto: %s needs a %d-byte key, got %d bytes", EVP_CIPHER_get0_name(c),
                    EVP_CIPHER_get_key_length(c), (int)klen);
        EVP_CIPHER_free(c);
        return NULL;
    }
    if (ivlen < 8 || ivlen > 64) {
        slang_error(S, "crypto: the iv must be 8 to 64 bytes (12 is usual), got %d", (int)ivlen);
        EVP_CIPHER_free(c);
        return NULL;
    }
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    size_t ivl = ivlen;
    OSSL_PARAM params[] = {OSSL_PARAM_construct_size_t(OSSL_CIPHER_PARAM_AEAD_IVLEN, &ivl), OSSL_PARAM_construct_end()};
    int ok = EVP_CipherInit_ex2(ctx, c, NULL, NULL, encrypt, params) &&
             EVP_CipherInit_ex2(ctx, NULL, (const unsigned char *)key, (const unsigned char *)iv, encrypt, NULL);
    EVP_CIPHER_free(c);
    if (!ok) {
        EVP_CIPHER_CTX_free(ctx);
        ssl_error(S, encrypt ? "encrypt" : "decrypt");
        return NULL;
    }
    return ctx;
}

static int add_aad(EVP_CIPHER_CTX *ctx, slang_State *S, int idx) {
    if (!slang_isstring(S, idx)) return 1;
    size_t alen = 0;
    const char *aad = slang_tolstring(S, idx, &alen);
    int outl = 0;
    return EVP_CipherUpdate(ctx, NULL, &outl, (const unsigned char *)aad, (int)alen);
}

/* encrypt(cipher, key, iv, plaintext, [aad]) -> ciphertext followed by the tag */
static int l_encrypt(slang_State *S) {
    size_t len = 0;
    const char *plain = slang_checkbytes(S, 4, &len);
    if (plain == NULL) return SLANG_ERROR;
    EVP_CIPHER_CTX *ctx = aead_init(S, 1);
    if (ctx == NULL) return SLANG_ERROR;
    unsigned char *out = malloc(len + TAG_LEN + 32);
    int n = 0, fin = 0;
    int ok = add_aad(ctx, S, 5) && EVP_EncryptUpdate(ctx, out, &n, (const unsigned char *)plain, (int)len) &&
             EVP_EncryptFinal_ex(ctx, out + n, &fin) &&
             EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, TAG_LEN, out + n + fin);
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) {
        free(out);
        return ssl_error(S, "encrypt");
    }
    slang_pushlstring(S, (const char *)out, (size_t)(n + fin + TAG_LEN));
    free(out);
    return 1;
}

/* decrypt(cipher, key, iv, sealed, [aad]) -> plaintext, or null when the
 * data, the aad, the key or the iv do not match */
static int l_decrypt(slang_State *S) {
    size_t len = 0;
    const char *sealed = slang_checkbytes(S, 4, &len);
    if (sealed == NULL) return SLANG_ERROR;
    if (len < TAG_LEN) {
        slang_pushnull(S);
        return 1;
    }
    EVP_CIPHER_CTX *ctx = aead_init(S, 0);
    if (ctx == NULL) return SLANG_ERROR;
    size_t clen = len - TAG_LEN;
    unsigned char *out = malloc(clen + 32);
    int n = 0, fin = 0;
    int ok = add_aad(ctx, S, 5) && EVP_DecryptUpdate(ctx, out, &n, (const unsigned char *)sealed, (int)clen) &&
             EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN, (void *)(sealed + clen)) &&
             EVP_DecryptFinal_ex(ctx, out + n, &fin) > 0;
    EVP_CIPHER_CTX_free(ctx);
    ERR_clear_error();
    if (!ok) {
        OPENSSL_cleanse(out, clen);
        free(out);
        slang_pushnull(S);
        return 1;
    }
    slang_pushlstring(S, (const char *)out, (size_t)(n + fin));
    OPENSSL_cleanse(out, clen);
    free(out);
    return 1;
}

/* ---- keys ---- */

typedef struct key {
    EVP_PKEY *pkey;
    int is_private;
} key;

static void key_finalize(void *data) {
    key *k = data;
    EVP_PKEY_free(k->pkey);
    k->pkey = NULL;
}

static void push_key(slang_State *S, EVP_PKEY *pkey, int is_private) {
    key *k = slang_newuserdata(S, sizeof(key), key_tname, key_finalize);
    k->pkey = pkey;
    k->is_private = is_private;
}

static key *check_key(slang_State *S, int idx) {
    return slang_checkudata(S, idx, key_tname);
}

/* private_key(pem, [passphrase]) */
static int l_private_key(slang_State *S) {
    size_t len = 0;
    const char *pem = slang_checklstring(S, 1, &len);
    if (pem == NULL) return SLANG_ERROR;
    const char *pass = slang_isstring(S, 2) ? slang_tolstring(S, 2, NULL) : NULL;
    BIO *bio = BIO_new_mem_buf(pem, (int)len);
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, (void *)(pass ? pass : ""));
    BIO_free(bio);
    if (pkey == NULL) return ssl_error(S, "private_key");
    push_key(S, pkey, 1);
    return 1;
}

/* public_key(pem): a SubjectPublicKeyInfo ("BEGIN PUBLIC KEY") */
static int l_public_key(slang_State *S) {
    size_t len = 0;
    const char *pem = slang_checklstring(S, 1, &len);
    if (pem == NULL) return SLANG_ERROR;
    BIO *bio = BIO_new_mem_buf(pem, (int)len);
    EVP_PKEY *pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (pkey == NULL) return ssl_error(S, "public_key");
    push_key(S, pkey, 0);
    return 1;
}

/* generate_key("rsa", [bits]) | ("ec", [curve]) | ("ed25519") */
static int l_generate_key(slang_State *S) {
    const char *type = slang_checklstring(S, 1, NULL);
    if (type == NULL) return SLANG_ERROR;
    EVP_PKEY *pkey = NULL;
    if (strcasecmp(type, "rsa") == 0) {
        int64_t bits = slang_optint(S, 2, 2048);
        if (bits < 1024 || bits > 16384) return slang_argerror(S, 2, "RSA key bits from 1024 to 16384 expected");
        pkey = EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)bits);
    } else if (strcasecmp(type, "ec") == 0) {
        const char *curve = slang_optstring(S, 2, "P-256");
        pkey = EVP_PKEY_Q_keygen(NULL, NULL, "EC", curve);
    } else if (strcasecmp(type, "ed25519") == 0) {
        pkey = EVP_PKEY_Q_keygen(NULL, NULL, "ED25519");
    } else {
        return slang_argerror(S, 1, "\"rsa\", \"ec\" or \"ed25519\" expected");
    }
    if (pkey == NULL) return ssl_error(S, "generate_key");
    push_key(S, pkey, 1);
    return 1;
}

static const char *key_type_name(EVP_PKEY *pkey) {
    switch (EVP_PKEY_get_base_id(pkey)) {
    case EVP_PKEY_RSA: return "rsa";
    case EVP_PKEY_RSA_PSS: return "rsa-pss";
    case EVP_PKEY_EC: return "ec";
    case EVP_PKEY_ED25519: return "ed25519";
    case EVP_PKEY_ED448: return "ed448";
    default: return "other";
    }
}

static int key_type(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    slang_pushstring(S, key_type_name(k->pkey));
    return 1;
}

static int key_bits(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    slang_pushint(S, EVP_PKEY_get_bits(k->pkey));
    return 1;
}

static int key_is_private(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    slang_pushbool(S, k->is_private);
    return 1;
}

static int push_bio(slang_State *S, BIO *bio) {
    char *data = NULL;
    long n = BIO_get_mem_data(bio, &data);
    slang_pushlstring(S, data, (size_t)n);
    BIO_free(bio);
    return 1;
}

static int key_public_pem(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    BIO *bio = BIO_new(BIO_s_mem());
    if (!PEM_write_bio_PUBKEY(bio, k->pkey)) {
        BIO_free(bio);
        return ssl_error(S, "public_pem");
    }
    return push_bio(S, bio);
}

/* private_pem(): PKCS#8, unencrypted */
static int key_private_pem(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    if (!k->is_private) return slang_error(S, "crypto: private_pem: this is a public key");
    BIO *bio = BIO_new(BIO_s_mem());
    if (!PEM_write_bio_PrivateKey(bio, k->pkey, NULL, NULL, 0, NULL, NULL)) {
        BIO_free(bio);
        return ssl_error(S, "private_pem");
    }
    return push_bio(S, bio);
}

/* public_key() -> the public half as a key of its own */
static int key_public_key(slang_State *S) {
    key *k = check_key(S, 1);
    if (k == NULL) return SLANG_ERROR;
    BIO *bio = BIO_new(BIO_s_mem());
    EVP_PKEY *pub = NULL;
    if (PEM_write_bio_PUBKEY(bio, k->pkey)) pub = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (pub == NULL) return ssl_error(S, "public_key");
    push_key(S, pub, 0);
    return 1;
}

/* the options table at idx: padding "pss", encoding "raw" */
static void sign_options(slang_State *S, int idx, int *pss, int *raw) {
    *pss = 0;
    *raw = 0;
    if (!slang_istable(S, idx)) return;
    slang_getfield(S, idx, "padding");
    if (slang_isstring(S, -1)) *pss = strcmp(slang_tolstring(S, -1, NULL), "pss") == 0;
    slang_pop(S, 1);
    slang_getfield(S, idx, "encoding");
    if (slang_isstring(S, -1)) *raw = strcmp(slang_tolstring(S, -1, NULL), "raw") == 0;
    slang_pop(S, 1);
}

/* a digest-sign/verify context for k, or NULL after raising */
static EVP_MD_CTX *sign_ctx(slang_State *S, key *k, int digest_idx, int pss, int sign) {
    int edwards = EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_ED25519 || EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_ED448;
    EVP_MD *md = NULL;
    if (!edwards) {
        if (slang_isnull(S, digest_idx) || slang_isnone(S, digest_idx)) {
            slang_argerror(S, digest_idx, "a digest like \"sha256\" expected");
            return NULL;
        }
        md = fetch_md(S, digest_idx);
        if (md == NULL) return NULL;
    }
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_PKEY_CTX *pctx = NULL;
    const char *mdname = md ? EVP_MD_get0_name(md) : NULL;
    int ok = sign ? EVP_DigestSignInit_ex(ctx, &pctx, mdname, NULL, NULL, k->pkey, NULL)
                  : EVP_DigestVerifyInit_ex(ctx, &pctx, mdname, NULL, NULL, k->pkey, NULL);
    EVP_MD_free(md);
    if (ok && pss) {
        ok = EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) > 0 &&
             EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) > 0;
    }
    if (!ok) {
        EVP_MD_CTX_free(ctx);
        ssl_error(S, sign ? "sign" : "verify");
        return NULL;
    }
    return ctx;
}

/* the size of r and s in a raw ECDSA signature for k */
static int ec_half(key *k) {
    return (EVP_PKEY_get_bits(k->pkey) + 7) / 8;
}

/* sign(digest, data, [options]) -> signature */
static int key_sign(slang_State *S) {
    key *k = check_key(S, 1);
    size_t len = 0;
    const char *data = slang_checklstring(S, 3, &len);
    if (k == NULL || data == NULL) return SLANG_ERROR;
    if (!k->is_private) return slang_error(S, "crypto: sign needs a private key");
    int pss, raw;
    sign_options(S, 4, &pss, &raw);
    EVP_MD_CTX *ctx = sign_ctx(S, k, 2, pss, 1);
    if (ctx == NULL) return SLANG_ERROR;
    size_t siglen = 0;
    unsigned char *sig = NULL;
    int ok = EVP_DigestSign(ctx, NULL, &siglen, (const unsigned char *)data, len) == 1;
    if (ok) {
        sig = malloc(siglen);
        ok = EVP_DigestSign(ctx, sig, &siglen, (const unsigned char *)data, len) == 1;
    }
    EVP_MD_CTX_free(ctx);
    if (!ok) {
        free(sig);
        return ssl_error(S, "sign");
    }
    if (raw && EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_EC) {
        const unsigned char *p = sig;
        ECDSA_SIG *es = d2i_ECDSA_SIG(NULL, &p, (long)siglen);
        free(sig);
        if (es == NULL) return ssl_error(S, "sign");
        int half = ec_half(k);
        unsigned char *out = malloc((size_t)half * 2);
        const BIGNUM *r = NULL, *s = NULL;
        ECDSA_SIG_get0(es, &r, &s);
        BN_bn2binpad(r, out, half);
        BN_bn2binpad(s, out + half, half);
        ECDSA_SIG_free(es);
        slang_pushlstring(S, (const char *)out, (size_t)half * 2);
        free(out);
        return 1;
    }
    slang_pushlstring(S, (const char *)sig, siglen);
    free(sig);
    return 1;
}

/* verify(digest, data, signature, [options]) -> bool */
static int key_verify(slang_State *S) {
    key *k = check_key(S, 1);
    size_t len = 0, siglen = 0;
    const char *data = slang_checklstring(S, 3, &len);
    const char *sig = slang_checklstring(S, 4, &siglen);
    if (k == NULL || slang_failed(S)) return SLANG_ERROR;
    int pss, raw;
    sign_options(S, 5, &pss, &raw);
    unsigned char *der = NULL;
    if (raw && EVP_PKEY_get_base_id(k->pkey) == EVP_PKEY_EC) {
        int half = ec_half(k);
        if (siglen != (size_t)half * 2) {
            slang_pushbool(S, 0);
            return 1;
        }
        ECDSA_SIG *es = ECDSA_SIG_new();
        BIGNUM *r = BN_bin2bn((const unsigned char *)sig, half, NULL);
        BIGNUM *s = BN_bin2bn((const unsigned char *)sig + half, half, NULL);
        ECDSA_SIG_set0(es, r, s);
        int n = i2d_ECDSA_SIG(es, &der);
        ECDSA_SIG_free(es);
        if (n <= 0) return ssl_error(S, "verify");
        sig = (const char *)der;
        siglen = (size_t)n;
    }
    EVP_MD_CTX *ctx = sign_ctx(S, k, 2, pss, 0);
    if (ctx == NULL) {
        OPENSSL_free(der);
        return SLANG_ERROR;
    }
    int ok = EVP_DigestVerify(ctx, (const unsigned char *)sig, siglen, (const unsigned char *)data, len) == 1;
    EVP_MD_CTX_free(ctx);
    OPENSSL_free(der);
    ERR_clear_error();
    slang_pushbool(S, ok);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, OpenSSL_version(OPENSSL_VERSION));
    return 1;
}

/* ---- module ---- */

static const slang_Reg hasher_methods[] = {
    {"update", hasher_update},
    {"digest", hasher_digest},
    {NULL, NULL},
};

static const slang_Reg key_methods[] = {
    {"sign", key_sign},
    {"verify", key_verify},
    {"public_pem", key_public_pem},
    {"private_pem", key_private_pem},
    {"public_key", key_public_key},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"hash", l_hash},
    {"hmac", l_hmac},
    {"random_bytes", l_random_bytes},
    {"equal", l_equal},
    {"hasher", l_hasher},
    {"pbkdf2", l_pbkdf2},
    {"scrypt", l_scrypt},
    {"pbkdf2_async", l_pbkdf2_async},
    {"scrypt_async", l_scrypt_async},
    {"encrypt", l_encrypt},
    {"decrypt", l_decrypt},
    {"private_key", l_private_key},
    {"public_key", l_public_key},
    {"generate_key", l_generate_key},
    {"version", l_version},
    {NULL, NULL},
};

static void make_meta(slang_State *S, const char *type_name, const slang_Reg *methods) {
    slang_newtable(S);
    slang_newmodule(S, methods);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, type_name);
    slang_setfield(S, -2, "__type");
    slang_settypemeta(S, type_name);
}

/* a key's properties (key.type, key.bits, key.private), then its methods
 * (the table in the upvalue) */
static int key_index(slang_State *S) {
    const char *name = slang_isstring(S, 2) ? slang_tostring(S, 2) : "";
    if (strcmp(name, "type") == 0) return key_type(S);
    if (strcmp(name, "bits") == 0) return key_bits(S);
    if (strcmp(name, "private") == 0) return key_is_private(S);
    slang_pushvalue(S, 2);
    slang_rawget(S, slang_upvalueindex(1));
    return 1;
}

SLANG_EXTENSION(crypto) {
    slang_newtable(S);
    slang_newmodule(S, key_methods);
    slang_pushcclosure(S, key_index, "__index", 1);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, key_tname);
    slang_setfield(S, -2, "__type");
    slang_settypemeta(S, key_tname);
    make_meta(S, hasher_tname, hasher_methods);
    slang_newmodule(S, funcs);
    return 1;
}
