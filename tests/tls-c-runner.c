/* Exercise the actual Lua binding, plus read-only OpenSSL test observations. */
#include <lualib.h>
#include "ltls.c"

static int tls_info(lua_State *L) {
    struct tls_context *tls = _check_context(L, 1);
    lua_newtable(L);
    lua_pushinteger(L, SSL_get_verify_mode(tls->ssl));
    lua_setfield(L, -2, "verify_mode");
    lua_pushstring(L, SSL_get_servername(tls->ssl, TLSEXT_NAMETYPE_host_name));
    lua_setfield(L, -2, "sni");
    lua_pushinteger(L, BIO_ctrl_pending(tls->out_bio));
    lua_setfield(L, -2, "pending");
    return 1;
}

static int tls_version(lua_State *L) {
    struct ssl_ctx *ctx = _check_sslctx(L, 1);
    int version = luaL_checkinteger(L, 2);
    luaL_argcheck(L, SSL_CTX_set_min_proto_version(ctx->ctx, version), 2, "invalid version");
    luaL_argcheck(L, SSL_CTX_set_max_proto_version(ctx->ctx, version), 2, "invalid version");
    return 0;
}

int main(int argc, char **argv) {
    lua_State *L = luaL_newstate();
    if (L == NULL || argc != 3) return 2;
    luaL_openlibs(L);
    ltls_init_constructor(L);
    luaL_requiref(L, "tls", luaopen_ltls_c, 1);
    lua_pop(L, 1);
    lua_pushcfunction(L, tls_info);
    lua_setglobal(L, "tls_info");
    lua_pushcfunction(L, tls_version);
    lua_setglobal(L, "tls_version");
    lua_pushstring(L, argv[2]);
    lua_setglobal(L, "certdir");
    int failed = luaL_dofile(L, argv[1]);
    if (failed) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    return failed ? 1 : 0;
}
