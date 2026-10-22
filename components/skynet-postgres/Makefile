CC ?= cc
LUA_INC ?= ../../vendor/skynet/3rd/lua
OUT_DIR ?= luaclib
CFLAGS ?= -O2 -g
CPPFLAGS += -I$(LUA_INC)
OPENSSL_CFLAGS ?= $(shell pkg-config --cflags openssl 2>/dev/null)
OPENSSL_LIBS ?= -lssl -lcrypto

.PHONY: all clean
all: $(OUT_DIR)/skynet_postgres_native.so

$(OUT_DIR)/skynet_postgres_native.so: lualib-src/skynet_postgres_native.c
	mkdir -p $(OUT_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(OPENSSL_CFLAGS) -std=c11 -Wall -Wextra -Werror -fPIC -shared -o $@ $< $(OPENSSL_LIBS)

clean:
	rm -f $(OUT_DIR)/skynet_postgres_native.so
