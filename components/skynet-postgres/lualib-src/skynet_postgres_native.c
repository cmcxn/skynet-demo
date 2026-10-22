/*
 * Memory BIO technique derived from Skynet v1.8.0 lualib-src/ltls.c.
 * Copyright (c) 2012-2025 codingnow.com
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * Component changes: OpenSSL 3 only, peer/name verification, private contexts,
 * explicit operation states, bounded reads, and no process-global cleanup.
 */
#include <limits.h>
#include <string.h>
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <stdlib.h>
#else
#include <arpa/inet.h>
#endif
#include <lua.h>
#include <lauxlib.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <openssl/hmac.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#if OPENSSL_VERSION_NUMBER < 0x30000000L
#error skynet_postgres_native requires OpenSSL 3 or newer
#endif

#define CTX_MT "skynet_postgres_native.context.v1"
#define SESSION_MT "skynet_postgres_native.session.v1"
struct context { SSL_CTX *ctx; };
struct session { SSL *ssl; BIO *input; BIO *output; };

static int failure(lua_State *L, const char *operation) {
    unsigned long code = ERR_get_error();
    char message[256];
    if (code) ERR_error_string_n(code, message, sizeof(message));
    else strcpy(message, "TLS operation failed");
    ERR_clear_error();
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, message);
    return 2;
}
static struct session *session_check(lua_State *L) {
    struct session *s = luaL_checkudata(L, 1, SESSION_MT);
    luaL_argcheck(L, s->ssl != NULL, 1, "TLS session is closed");
    return s;
}
static int context_close(lua_State *L) {
    struct context *c = luaL_checkudata(L, 1, CTX_MT);
    SSL_CTX_free(c->ctx);
    c->ctx = NULL;
    return 0;
}
static int session_close(lua_State *L) {
    struct session *s = luaL_checkudata(L, 1, SESSION_MT);
    SSL_free(s->ssl);
    s->ssl = NULL; s->input = NULL; s->output = NULL;
    return 0;
}
static const char *option_string(lua_State *L, const char *name) {
    lua_getfield(L, 1, name);
    const char *value = lua_isnil(L, -1) ? NULL : luaL_checkstring(L, -1);
    lua_pop(L, 1);
    return value;
}
static int new_context(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    const char *file = option_string(L, "ca_file");
    const char *path = option_string(L, "ca_path");
    lua_getfield(L, 1, "use_default_ca");
    int defaults = lua_isnil(L, -1) || lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (!defaults && !file && !path) {
        lua_pushnil(L); lua_pushliteral(L, "custom CA required when use_default_ca=false"); return 2;
    }
    ERR_clear_error();
    struct context *c = lua_newuserdatauv(L, sizeof(*c), 0);
    c->ctx = NULL;
    luaL_setmetatable(L, CTX_MT);
    c->ctx = SSL_CTX_new(TLS_client_method());
    if (!c->ctx) return failure(L, "SSL_CTX_new");
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_PEER, NULL);
    if (!SSL_CTX_set_min_proto_version(c->ctx, TLS1_2_VERSION)) return failure(L, "minimum TLS version");
    SSL_CTX_set_options(c->ctx, SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_mode(c->ctx, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (defaults && !SSL_CTX_set_default_verify_paths(c->ctx)) return failure(L, "default CA paths");
    if ((file || path) && !SSL_CTX_load_verify_locations(c->ctx, file, path)) return failure(L, "custom CA paths");
    return 1;
}
static int new_session(lua_State *L) {
    struct context *c = luaL_checkudata(L, 1, CTX_MT);
    luaL_argcheck(L, c->ctx != NULL, 1, "TLS context is closed");
    size_t length;
    const char *host = luaL_checklstring(L, 2, &length);
    luaL_argcheck(L, length > 0 && length == strlen(host), 2, "invalid TLS hostname");
    ERR_clear_error();
    struct session *s = lua_newuserdatauv(L, sizeof(*s), 1);
    s->ssl = NULL; s->input = NULL; s->output = NULL;
    luaL_setmetatable(L, SESSION_MT);
    lua_pushvalue(L, 1); lua_setiuservalue(L, -2, 1);
    s->ssl = SSL_new(c->ctx);
    if (!s->ssl) return failure(L, "SSL_new");
    BIO *in = BIO_new(BIO_s_mem()), *out = BIO_new(BIO_s_mem());
    if (!in || !out) { BIO_free(in); BIO_free(out); return failure(L, "BIO_new"); }
    BIO_set_mem_eof_return(in, -1);
    BIO_set_mem_eof_return(out, -1);
    SSL_set_bio(s->ssl, in, out);
    s->input = in; s->output = out;
    SSL_set_connect_state(s->ssl);
    X509_VERIFY_PARAM *param = SSL_get0_param(s->ssl);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    unsigned char ip[16];
    if (inet_pton(AF_INET, host, ip) == 1 || inet_pton(AF_INET6, host, ip) == 1) {
        if (!X509_VERIFY_PARAM_set1_ip_asc(param, host)) return failure(L, "IP SAN verification");
    } else {
        if (!SSL_set1_host(s->ssl, host) || !SSL_set_tlsext_host_name(s->ssl, host)) return failure(L, "hostname verification");
    }
    return 1;
}
static int session_feed(lua_State *L) {
    struct session *s = session_check(L);
    size_t length;
    const char *data = luaL_checklstring(L, 2, &length);
    while (length > 0) {
        int amount = length > INT_MAX ? INT_MAX : (int)length;
        int n = BIO_write(s->input, data, amount);
        if (n <= 0) return failure(L, "BIO_write");
        data += n; length -= (size_t)n;
    }
    lua_pushboolean(L, 1); return 1;
}
static int session_eof(lua_State *L) {
    struct session *s = session_check(L);
    BIO_set_mem_eof_return(s->input, 0);
    return 0;
}
static int session_drain(lua_State *L) {
    struct session *s = session_check(L);
    char bytes[16384];
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    while (BIO_ctrl_pending(s->output) > 0) {
        int n = BIO_read(s->output, bytes, sizeof(bytes));
        if (n <= 0) return failure(L, "BIO_read");
        luaL_addlstring(&b, bytes, (size_t)n);
    }
    luaL_pushresult(&b); return 1;
}
static const char *operation_state(int error) {
    switch (error) {
    case SSL_ERROR_WANT_READ: return "want_read";
    case SSL_ERROR_WANT_WRITE: return "want_write";
    case SSL_ERROR_ZERO_RETURN: return "close_notify";
    default: return NULL;
    }
}
static int session_handshake(lua_State *L) {
    struct session *s = session_check(L);
    ERR_clear_error();
    int ret = SSL_do_handshake(s->ssl);
    int error = ret == 1 ? SSL_ERROR_NONE : SSL_get_error(s->ssl, ret);
    if (ret == 1) {
        if (SSL_get_verify_result(s->ssl) != X509_V_OK) return failure(L, "peer verification");
        lua_pushliteral(L, "ok"); return 1;
    }
    const char *state = operation_state(error);
    if (!state) return failure(L, "TLS handshake");
    lua_pushstring(L, state); return 1;
}
static int session_read(lua_State *L) {
    struct session *s = session_check(L);
    char bytes[16384];
    size_t n = 0;
    ERR_clear_error();
    int ret = SSL_read_ex(s->ssl, bytes, sizeof(bytes), &n);
    int error = ret == 1 ? SSL_ERROR_NONE : SSL_get_error(s->ssl, ret);
    const char *state = ret == 1 ? "ok" : operation_state(error);
    if (!state) return failure(L, "TLS read");
    lua_pushlstring(L, bytes, n); lua_pushstring(L, state); return 2;
}
static int session_write(lua_State *L) {
    struct session *s = session_check(L);
    size_t length, n = 0;
    const char *bytes = luaL_checklstring(L, 2, &length);
    ERR_clear_error();
    int ret = SSL_write_ex(s->ssl, bytes, length, &n);
    int error = ret == 1 ? SSL_ERROR_NONE : SSL_get_error(s->ssl, ret);
    const char *state = ret == 1 ? "ok" : operation_state(error);
    if (!state) return failure(L, "TLS write");
    lua_pushinteger(L, (lua_Integer)n); lua_pushstring(L, state); return 2;
}
static int system_dns_server(lua_State *L) {
#ifdef _WIN32
    ULONG length = 0;
    if (GetNetworkParams(NULL, &length) != ERROR_BUFFER_OVERFLOW || length == 0) {
        lua_pushnil(L); lua_pushliteral(L, "Windows DNS discovery failed; set SKYNET_POSTGRES_DNS_SERVER"); return 2;
    }
    FIXED_INFO *info = malloc(length);
    if (!info) return luaL_error(L, "out of memory discovering DNS");
    DWORD status = GetNetworkParams(info, &length);
    if (status == ERROR_SUCCESS) {
        for (IP_ADDR_STRING *entry = &info->DnsServerList; entry; entry = entry->Next) {
            unsigned char ip[4];
            if (inet_pton(AF_INET, entry->IpAddress.String, ip) == 1 && strcmp(entry->IpAddress.String, "0.0.0.0") != 0) {
                lua_pushstring(L, entry->IpAddress.String); free(info); return 1;
            }
        }
    }
    free(info);
    lua_pushnil(L); lua_pushliteral(L, "No Windows IPv4 DNS server; set SKYNET_POSTGRES_DNS_SERVER"); return 2;
#else
    lua_pushnil(L); lua_pushliteral(L, "system DNS discovery is only needed on Windows"); return 2;
#endif
}

static int random_bytes(lua_State *L) {
    lua_Integer n = luaL_checkinteger(L, 1);
    luaL_argcheck(L, n > 0 && n <= 1048576, 1, "random byte count must be 1..1048576");
    luaL_Buffer b; unsigned char *p = (unsigned char *)luaL_buffinitsize(L, &b, (size_t)n);
    if (RAND_bytes(p, (int)n) != 1) return failure(L, "secure random");
    luaL_pushresultsize(&b, (size_t)n); return 1;
}
static int digest(lua_State *L, const EVP_MD *md, int hex) {
    size_t len; const char *s = luaL_checklstring(L, 1, &len);
    unsigned char out[EVP_MAX_MD_SIZE]; unsigned int n;
    if (!EVP_Digest(s, len, out, &n, md, NULL)) return failure(L, "digest");
    if (hex) {
        char text[2 * EVP_MAX_MD_SIZE]; const char *digits = "0123456789abcdef";
        for (unsigned int i = 0; i < n; ++i) { text[2*i] = digits[out[i] >> 4]; text[2*i+1] = digits[out[i] & 15]; }
        lua_pushlstring(L, text, 2*n);
    } else lua_pushlstring(L, (const char *)out, n);
    return 1;
}
static int sha256(lua_State *L) { return digest(L, EVP_sha256(), 0); }
static int md5(lua_State *L) { return digest(L, EVP_md5(), 1); }
static int hmac_sha256(lua_State *L) {
    size_t klen, len; const char *key = luaL_checklstring(L, 1, &klen);
    const char *s = luaL_checklstring(L, 2, &len);
    luaL_argcheck(L, klen <= INT_MAX, 1, "key too long");
    unsigned char out[EVP_MAX_MD_SIZE]; unsigned int n;
    if (!HMAC(EVP_sha256(), key, (int)klen, (const unsigned char *)s, len, out, &n)) return failure(L, "HMAC");
    lua_pushlstring(L, (const char *)out, n); return 1;
}
static int pbkdf2(lua_State *L) {
    size_t plen, slen; const char *p = luaL_checklstring(L, 1, &plen), *s = luaL_checklstring(L, 2, &slen);
    lua_Integer iterations = luaL_checkinteger(L, 3), n = luaL_checkinteger(L, 4);
    luaL_argcheck(L, plen <= INT_MAX && slen <= INT_MAX, 1, "input too long");
    luaL_argcheck(L, iterations > 0 && iterations <= 1000000, 3, "iterations must be 1..1000000");
    luaL_argcheck(L, n > 0 && n <= 1024, 4, "key length must be 1..1024");
    luaL_Buffer b; unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, (size_t)n);
    if (!PKCS5_PBKDF2_HMAC(p, (int)plen, (const unsigned char *)s, (int)slen, (int)iterations, EVP_sha256(), (int)n, out)) return failure(L, "PBKDF2");
    luaL_pushresultsize(&b, (size_t)n); return 1;
}

static void metatable(lua_State *L, const char *name, const luaL_Reg *methods, lua_CFunction close) {
    luaL_newmetatable(L, name);
    lua_pushcfunction(L, close); lua_setfield(L, -2, "__gc");
    lua_newtable(L); luaL_setfuncs(L, methods, 0); lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
}
int luaopen_skynet_postgres_native(lua_State *L) {
    luaL_checkversion(L);
    /* OpenSSL 3 initializes safely itself; never use OPENSSL_cleanup here. */
    static const luaL_Reg ctx[] = {{"close", context_close}, {NULL, NULL}};
    static const luaL_Reg sessions[] = {
        {"feed", session_feed}, {"eof", session_eof}, {"drain", session_drain},
        {"handshake", session_handshake}, {"read", session_read}, {"write", session_write},
        {"close", session_close}, {NULL, NULL}
    };
    static const luaL_Reg lib[] = {{"context", new_context}, {"session", new_session},
        {"system_dns_server", system_dns_server}, {"random_bytes", random_bytes}, {"sha256", sha256}, {"md5", md5},
        {"hmac_sha256", hmac_sha256}, {"pbkdf2", pbkdf2}, {NULL, NULL}};
    metatable(L, CTX_MT, ctx, context_close); metatable(L, SESSION_MT, sessions, session_close);
    luaL_newlib(L, lib); return 1;
}
