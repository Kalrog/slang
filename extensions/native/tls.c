/*
 * tls: a native extension exposing OpenSSL 3's TLS (libssl) as an engine
 * on memory buffers. It does no I/O: slang/tls moves the bytes between the
 * engine and a libuv TCP handle.
 *
 *   local tls = require("tls")
 *   local ctx = tls.context({server, cert, key, ca, verify, alpn,
 *                            min_version})
 *   local s = ctx:session([hostname])   a client for hostname, or a server
 *   s:feed(bytes)          bytes that arrived from the network
 *   s:handshake() -> true when done, false while it waits for the peer
 *   s:read()  -> the plaintext decrypted so far ("" for none), or null once
 *                the peer closed the session (close_notify)
 *   s:write(plaintext)     encrypts (after the handshake)
 *   s:take()  -> the bytes to send to the network ("" for none); call it
 *                after every other method, which may all produce some
 *   s:close()              queues a close_notify for take()
 *   s:info()  -> {version, cipher, alpn, peer, server_name}
 *   tls.self_signed(names, [days]) -> {cert, key}: a certificate for local
 *                development (an EC P-256 key; names are host names or IP
 *                addresses, the first is the subject)
 *   tls.version() -> OpenSSL's version text
 *
 * Context options: server (a server context; false by default), cert and
 * key (PEM text: the certificate chain, leaf first, and its private key;
 * needed by a server), ca (PEM text of the certificates to trust instead
 * of the system's), verify (check the peer's certificate: true by default
 * for a client, which needs it to be valid for hostname; a server with
 * verify asks for a client certificate), alpn (a list of protocol names,
 * by preference), min_version ("1.2", the default, or "1.3"). The system's
 * trust store is OpenSSL's default (SSL_CERT_FILE and SSL_CERT_DIR override
 * it), or else the first bundle found at the usual paths. Errors read
 * "tls: ...".
 */
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "slang.h"

typedef struct context {
    SSL_CTX *ctx;
    int server;
} context;

typedef struct session {
    SSL *ssl;
    BIO *in;  /* from the network, read by OpenSSL */
    BIO *out; /* to the network, written by OpenSSL */
    int done; /* the handshake completed */
} session;

static const char *context_tname = "tls.context";
static const char *session_tname = "tls.session";

/* raises "tls: <what>: <openssl's reason>" and clears the error queue */
static int tls_error(slang_State *S, const char *what) {
    unsigned long e = ERR_get_error();
    char buf[256] = "unknown error";
    if (e != 0) ERR_error_string_n(e, buf, sizeof buf);
    ERR_clear_error();
    return slang_error(S, "tls: %s: %s", what, buf);
}

/* the string field name of the table at idx, or NULL */
static const char *opt_string(slang_State *S, int idx, const char *name, size_t *len) {
    if (!slang_istable(S, idx)) return NULL;
    slang_getfield(S, idx, name);
    const char *s = slang_isstring(S, -1) ? slang_tolstring(S, -1, len) : NULL;
    slang_pop(S, 1); /* the string stays alive in the options table */
    return s;
}

/* the bool field name of the table at idx, or def when it is not a bool */
static int opt_bool(slang_State *S, int idx, const char *name, int def) {
    if (!slang_istable(S, idx)) return def;
    slang_getfield(S, idx, name);
    int v = slang_isbool(S, -1) ? slang_tobool(S, -1) : def;
    slang_pop(S, 1);
    return v;
}

/* ---- contexts ---- */

static void context_finalize(void *data) {
    context *c = data;
    SSL_CTX_free(c->ctx);
    c->ctx = NULL;
}

/* the certificates in pem added to store; 0 when there were none */
static int add_pem_certs(X509_STORE *store, const char *pem, size_t len) {
    BIO *bio = BIO_new_mem_buf(pem, (int)len);
    int n = 0;
    X509 *x;
    while ((x = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL) {
        if (X509_STORE_add_cert(store, x)) n++;
        X509_free(x);
    }
    BIO_free(bio);
    ERR_clear_error(); /* the end of the PEM text reads as an error */
    return n;
}

/* the system's trust store: OpenSSL's default paths, else a known bundle */
static void load_system_roots(SSL_CTX *ctx) {
    SSL_CTX_set_default_verify_paths(ctx);
    ERR_clear_error();
    X509_STORE *store = SSL_CTX_get_cert_store(ctx);
    if (sk_X509_OBJECT_num(X509_STORE_get0_objects(store)) > 0) return;
    static const char *bundles[] = {
        "/etc/ssl/cert.pem",                  /* macOS, Alpine, BSDs */
        "/etc/ssl/certs/ca-certificates.crt", /* Debian, Ubuntu, Arch */
        "/etc/pki/tls/certs/ca-bundle.crt",   /* Fedora, RHEL */
        "/etc/ssl/ca-bundle.pem",             /* openSUSE */
        "/opt/homebrew/etc/ca-certificates/cert.pem",
        "/usr/local/etc/ca-certificates/cert.pem",
        NULL,
    };
    for (int i = 0; bundles[i] != NULL; i++) {
        if (access(bundles[i], R_OK) == 0 && X509_STORE_load_file(store, bundles[i])) break;
        ERR_clear_error();
    }
}

/* the certificate chain in pem (leaf first) and its key, into ctx */
static int use_cert_and_key(slang_State *S, SSL_CTX *ctx, const char *cert, size_t cert_len,
                            const char *key, size_t key_len) {
    BIO *bio = BIO_new_mem_buf(cert, (int)cert_len);
    X509 *leaf = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    if (leaf == NULL) {
        BIO_free(bio);
        return tls_error(S, "cert");
    }
    int ok = SSL_CTX_use_certificate(ctx, leaf);
    X509_free(leaf);
    X509 *x;
    while (ok && (x = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL) {
        if (!SSL_CTX_add0_chain_cert(ctx, x)) {
            X509_free(x);
            ok = 0;
        }
    }
    BIO_free(bio);
    if (!ok) return tls_error(S, "cert");
    ERR_clear_error();
    bio = BIO_new_mem_buf(key, (int)key_len);
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, (void *)"");
    BIO_free(bio);
    if (pkey == NULL) return tls_error(S, "key");
    ok = SSL_CTX_use_PrivateKey(ctx, pkey);
    EVP_PKEY_free(pkey);
    if (!ok) return tls_error(S, "key");
    if (!SSL_CTX_check_private_key(ctx)) return tls_error(S, "the key does not match the certificate");
    return 0;
}

/* the ALPN list of the table at idx as the wire format (length-prefixed
 * names); returns its length, 0 for none, -1 after raising */
static int alpn_wire(slang_State *S, int idx, unsigned char *out, int cap) {
    if (!slang_istable(S, idx)) return 0;
    slang_getfield(S, idx, "alpn");
    if (!slang_istable(S, -1)) {
        slang_pop(S, 1);
        return 0;
    }
    int n = 0;
    int64_t count = slang_rawlen(S, -1);
    for (int64_t i = 0; i < count; i++) {
        slang_rawgeti(S, -1, i);
        size_t len = 0;
        const char *name = slang_isstring(S, -1) ? slang_tolstring(S, -1, &len) : NULL;
        if (name == NULL || len == 0 || len > 255 || n + 1 + (int)len > cap) {
            slang_pop(S, 2);
            slang_error(S, "tls: alpn: a list of protocol names expected");
            return -1;
        }
        out[n++] = (unsigned char)len;
        memcpy(out + n, name, len);
        n += (int)len;
        slang_pop(S, 1);
    }
    slang_pop(S, 1);
    return n;
}

/* a server picks the first of its protocols that the client offers */
static int select_alpn(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                       const unsigned char *in, unsigned int inlen, void *arg) {
    (void)ssl;
    const unsigned char *ours = arg;
    unsigned int ours_len = ours[0] | (ours[1] << 8);
    unsigned char *selected = NULL;
    if (SSL_select_next_proto(&selected, outlen, ours + 2, ours_len, in, inlen) != OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_NOACK;
    *out = selected;
    return SSL_TLSEXT_ERR_OK;
}

static int alpn_index = -1;

static void free_alpn(void *parent, void *ptr, CRYPTO_EX_DATA *ad, int idx, long argl, void *argp) {
    (void)parent; (void)ad; (void)idx; (void)argl; (void)argp;
    free(ptr);
}

/* process-wide (OpenSSL's index), made once: isolates open the extension
 * on their own threads */
static CRYPTO_ONCE alpn_once = CRYPTO_ONCE_STATIC_INIT;

static void init_alpn_index(void) {
    alpn_index = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, free_alpn);
}

/* context(options) */
static int l_context(slang_State *S) {
    int server = opt_bool(S, 1, "server", 0);
    SSL_CTX *ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
    if (ctx == NULL) return tls_error(S, "context");
    context *c = slang_newuserdata(S, sizeof(context), context_tname, context_finalize);
    c->ctx = ctx;
    c->server = server;

    const char *min = opt_string(S, 1, "min_version", NULL);
    int version = TLS1_2_VERSION;
    if (min != NULL && strcmp(min, "1.3") == 0) version = TLS1_3_VERSION;
    else if (min != NULL && strcmp(min, "1.2") != 0) return slang_error(S, "tls: min_version: \"1.2\" or \"1.3\" expected");
    SSL_CTX_set_min_proto_version(ctx, version);
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS);

    size_t cert_len = 0, key_len = 0, ca_len = 0;
    const char *cert = opt_string(S, 1, "cert", &cert_len);
    const char *key = opt_string(S, 1, "key", &key_len);
    if ((cert == NULL) != (key == NULL)) return slang_error(S, "tls: cert and key go together");
    if (cert != NULL && use_cert_and_key(S, ctx, cert, cert_len, key, key_len) != 0) return SLANG_ERROR;
    if (server && cert == NULL) return slang_error(S, "tls: a server needs cert and key");

    int verify = opt_bool(S, 1, "verify", !server);
    const char *ca = opt_string(S, 1, "ca", &ca_len);
    if (verify) {
        if (ca != NULL) {
            if (add_pem_certs(SSL_CTX_get_cert_store(ctx), ca, ca_len) == 0)
                return slang_error(S, "tls: ca: no certificates in the PEM text");
        } else {
            load_system_roots(ctx);
        }
        int mode = SSL_VERIFY_PEER;
        if (server) mode |= SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
        SSL_CTX_set_verify(ctx, mode, NULL);
    } else {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    }

    unsigned char wire[512];
    int n = alpn_wire(S, 1, wire, sizeof wire);
    if (n < 0) return SLANG_ERROR;
    if (n > 0) {
        if (server) {
            unsigned char *ours = malloc((size_t)n + 2);
            ours[0] = (unsigned char)(n & 0xff);
            ours[1] = (unsigned char)(n >> 8);
            memcpy(ours + 2, wire, (size_t)n);
            SSL_CTX_set_ex_data(ctx, alpn_index, ours);
            SSL_CTX_set_alpn_select_cb(ctx, select_alpn, ours);
        } else if (SSL_CTX_set_alpn_protos(ctx, wire, (unsigned int)n) != 0) {
            return tls_error(S, "alpn");
        }
    }
    return 1;
}

static context *check_context(slang_State *S, int idx) {
    return slang_checkudata(S, idx, context_tname);
}

/* ---- sessions ---- */

static void session_finalize(void *data) {
    session *s = data;
    SSL_free(s->ssl); /* frees both BIOs */
    s->ssl = NULL;
}

static session *check_session(slang_State *S, int idx) {
    session *s = slang_checkudata(S, idx, session_tname);
    if (s != NULL) ERR_clear_error();
    return s;
}

/* an IP address rather than a host name */
static int is_ip(const char *host) {
    ASN1_OCTET_STRING *ip = a2i_IPADDRESS(host);
    if (ip == NULL) {
        ERR_clear_error();
        return 0;
    }
    ASN1_OCTET_STRING_free(ip);
    return 1;
}

/* ctx:session([hostname]) */
static int context_session(slang_State *S) {
    context *c = check_context(S, 1);
    if (c == NULL) return SLANG_ERROR;
    const char *host = slang_isstring(S, 2) ? slang_tolstring(S, 2, NULL) : NULL;
    SSL *ssl = SSL_new(c->ctx);
    if (ssl == NULL) return tls_error(S, "session");
    session *s = slang_newuserdata(S, sizeof(session), session_tname, session_finalize);
    s->ssl = ssl;
    s->in = BIO_new(BIO_s_mem());
    s->out = BIO_new(BIO_s_mem());
    /* reading an empty input is "try again", not the end */
    BIO_set_mem_eof_return(s->in, -1);
    SSL_set_bio(ssl, s->in, s->out);
    if (c->server) {
        SSL_set_accept_state(ssl);
        return 1;
    }
    SSL_set_connect_state(ssl);
    if (host != NULL && host[0] != '\0') {
        if (is_ip(host)) {
            if (!X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), host)) return tls_error(S, "session");
        } else {
            if (!SSL_set_tlsext_host_name(ssl, host) || !SSL_set1_host(ssl, host)) return tls_error(S, "session");
        }
    } else if (SSL_CTX_get_verify_mode(c->ctx) & SSL_VERIFY_PEER) {
        return slang_error(S, "tls: a client that verifies needs the server's host name");
    }
    return 1;
}

/* the failure of an SSL call that returned r: raises, or returns 0 when it
 * only waits for more input */
static int check_result(slang_State *S, session *s, int r, const char *what) {
    int e = SSL_get_error(s->ssl, r);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return 0;
    long verify = SSL_get_verify_result(s->ssl);
    if (verify != X509_V_OK) {
        ERR_clear_error();
        return slang_error(S, "tls: certificate verify failed: %s", X509_verify_cert_error_string(verify));
    }
    if (e == SSL_ERROR_SYSCALL && ERR_peek_error() == 0) {
        return slang_error(S, "tls: %s: the connection ended unexpectedly", what);
    }
    return tls_error(S, what);
}

/* s:feed(bytes) */
static int session_feed(slang_State *S) {
    session *s = check_session(S, 1);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (s == NULL || data == NULL) return SLANG_ERROR;
    if (len > 0 && BIO_write(s->in, data, (int)len) != (int)len) return tls_error(S, "feed");
    return 0;
}

/* s:handshake() -> true when done */
static int session_handshake(slang_State *S) {
    session *s = check_session(S, 1);
    if (s == NULL) return SLANG_ERROR;
    if (!s->done) {
        int r = SSL_do_handshake(s->ssl);
        if (r == 1) {
            s->done = 1;
        } else if (check_result(S, s, r, "handshake") != 0) {
            return SLANG_ERROR;
        }
    }
    slang_pushbool(S, s->done);
    return 1;
}

/* s:read() -> plaintext, or null at the peer's close_notify */
static int session_read(slang_State *S) {
    session *s = check_session(S, 1);
    if (s == NULL) return SLANG_ERROR;
    size_t cap = 16384, len = 0;
    char *buf = malloc(cap);
    int closed = 0;
    for (;;) {
        if (cap - len < 16384) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        int r = SSL_read(s->ssl, buf + len, (int)(cap - len));
        if (r > 0) {
            len += (size_t)r;
            continue;
        }
        int e = SSL_get_error(s->ssl, r);
        if (e == SSL_ERROR_ZERO_RETURN) {
            closed = 1;
            break;
        }
        if (check_result(S, s, r, "read") != 0) {
            free(buf);
            return SLANG_ERROR;
        }
        break;
    }
    if (closed && len == 0) slang_pushnull(S);
    else slang_pushlstring(S, buf, len);
    free(buf);
    return 1;
}

/* s:write(plaintext) */
static int session_write(slang_State *S) {
    session *s = check_session(S, 1);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (s == NULL || data == NULL) return SLANG_ERROR;
    if (!s->done) return slang_error(S, "tls: write before the handshake completed");
    size_t at = 0;
    while (at < len) {
        size_t n = len - at > 1 << 30 ? 1 << 30 : len - at;
        int r = SSL_write(s->ssl, data + at, (int)n);
        if (r <= 0) {
            if (check_result(S, s, r, "write") != 0) return SLANG_ERROR;
            return slang_error(S, "tls: write: the session cannot send now");
        }
        at += (size_t)r;
    }
    return 0;
}

/* s:take() -> the bytes for the network */
static int session_take(slang_State *S) {
    session *s = check_session(S, 1);
    if (s == NULL) return SLANG_ERROR;
    char *data = NULL;
    long n = BIO_get_mem_data(s->out, &data);
    slang_pushlstring(S, data, (size_t)(n > 0 ? n : 0));
    (void)BIO_reset(s->out);
    return 1;
}

/* s:close(): a close_notify, when the handshake got that far */
static int session_close(slang_State *S) {
    session *s = check_session(S, 1);
    if (s == NULL) return SLANG_ERROR;
    if (s->done) SSL_shutdown(s->ssl);
    ERR_clear_error();
    return 0;
}

static void set_string(slang_State *S, const char *name, const char *value, size_t len) {
    if (value == NULL) return;
    slang_pushlstring(S, value, len);
    slang_setfield(S, -2, name);
}

/* s:info() -> {version, cipher, alpn, peer, server_name} */
static int session_info(slang_State *S) {
    session *s = check_session(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_newtable(S);
    const char *version = SSL_get_version(s->ssl);
    set_string(S, "version", version, strlen(version));
    const char *cipher = SSL_get_cipher_name(s->ssl);
    if (cipher != NULL) set_string(S, "cipher", cipher, strlen(cipher));
    const unsigned char *alpn = NULL;
    unsigned int alpn_len = 0;
    SSL_get0_alpn_selected(s->ssl, &alpn, &alpn_len);
    if (alpn_len > 0) set_string(S, "alpn", (const char *)alpn, alpn_len);
    X509 *peer = SSL_get1_peer_certificate(s->ssl);
    if (peer != NULL) {
        char name[256];
        X509_NAME_oneline(X509_get_subject_name(peer), name, sizeof name);
        set_string(S, "peer", name, strlen(name));
        X509_free(peer);
    }
    const char *sni = SSL_get_servername(s->ssl, TLSEXT_NAMETYPE_host_name);
    if (sni != NULL) set_string(S, "server_name", sni, strlen(sni));
    return 1;
}

/* ---- certificates ---- */

/* self_signed(names, [days]) -> {cert, key} */
static int l_self_signed(slang_State *S) {
    slang_checktable(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    int64_t count = slang_rawlen(S, 1);
    if (count == 0) return slang_argerror(S, 1, "a list of host names expected");
    int64_t days = slang_optint(S, 2, 365);
    /* subjectAltName: DNS:name or IP:address for each */
    size_t cap = 64, len = 0;
    char *san = malloc(cap);
    san[0] = '\0';
    const char *first = NULL;
    for (int64_t i = 0; i < count; i++) {
        slang_rawgeti(S, 1, i);
        const char *name = slang_isstring(S, -1) ? slang_tolstring(S, -1, NULL) : NULL;
        slang_pop(S, 1);
        if (name == NULL) {
            free(san);
            return slang_argerror(S, 1, "a list of host names expected");
        }
        if (first == NULL) first = name;
        size_t need = len + strlen(name) + 8;
        if (need > cap) {
            cap = need * 2;
            san = realloc(san, cap);
        }
        len += (size_t)snprintf(san + len, cap - len, "%s%s:%s", len > 0 ? "," : "", is_ip(name) ? "IP" : "DNS", name);
    }
    EVP_PKEY *pkey = EVP_PKEY_Q_keygen(NULL, NULL, "EC", "P-256");
    X509 *x = X509_new();
    int ok = pkey != NULL && x != NULL;
    if (ok) {
        unsigned char serial[16];
        RAND_bytes(serial, sizeof serial);
        serial[0] &= 0x7f;
        BIGNUM *bn = BN_bin2bn(serial, sizeof serial, NULL);
        BN_to_ASN1_INTEGER(bn, X509_get_serialNumber(x));
        BN_free(bn);
        X509_set_version(x, 2);
        X509_gmtime_adj(X509_getm_notBefore(x), -60 * 60);
        X509_gmtime_adj(X509_getm_notAfter(x), (long)days * 24 * 60 * 60);
        X509_set_pubkey(x, pkey);
        X509_NAME *subject = X509_get_subject_name(x);
        X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_UTF8, (const unsigned char *)first, -1, -1, 0);
        X509_set_issuer_name(x, subject);
        X509V3_CTX v3;
        X509V3_set_ctx_nodb(&v3);
        X509V3_set_ctx(&v3, x, x, NULL, NULL, 0);
        X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &v3, NID_subject_alt_name, san);
        ok = ext != NULL && X509_add_ext(x, ext, -1);
        X509_EXTENSION_free(ext);
        ok = ok && X509_sign(x, pkey, EVP_sha256()) > 0;
    }
    free(san);
    if (!ok) {
        X509_free(x);
        EVP_PKEY_free(pkey);
        return tls_error(S, "self_signed");
    }
    slang_newtable(S);
    BIO *bio = BIO_new(BIO_s_mem());
    PEM_write_bio_X509(bio, x);
    char *data = NULL;
    long n = BIO_get_mem_data(bio, &data);
    slang_pushlstring(S, data, (size_t)n);
    slang_setfield(S, -2, "cert");
    (void)BIO_reset(bio);
    PEM_write_bio_PrivateKey(bio, pkey, NULL, NULL, 0, NULL, NULL);
    n = BIO_get_mem_data(bio, &data);
    slang_pushlstring(S, data, (size_t)n);
    slang_setfield(S, -2, "key");
    BIO_free(bio);
    X509_free(x);
    EVP_PKEY_free(pkey);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, OpenSSL_version(OPENSSL_VERSION));
    return 1;
}

/* ---- module ---- */

static const slang_Reg context_methods[] = {
    {"session", context_session},
    {NULL, NULL},
};

static const slang_Reg session_methods[] = {
    {"feed", session_feed},
    {"handshake", session_handshake},
    {"read", session_read},
    {"write", session_write},
    {"take", session_take},
    {"close", session_close},
    {"info", session_info},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"context", l_context},
    {"self_signed", l_self_signed},
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

SLANG_EXTENSION(tls) {
    CRYPTO_THREAD_run_once(&alpn_once, init_alpn_index);
    make_meta(S, context_tname, context_methods);
    make_meta(S, session_tname, session_methods);
    slang_newmodule(S, funcs);
    return 1;
}
