CXX ?= c++
LUA_INC ?= ../../vendor/skynet/3rd/lua
PLUTO_DIR ?= ../../vendor/pluto
OUT_DIR ?= luaclib
CXXFLAGS ?= -O2 -g
CPPFLAGS += -I$(LUA_INC)
# Override for cross-compilation; macOS needs dynamic lookup of the host Lua ABI.
ifeq ($(shell uname -s),Darwin)
SHARED ?= -dynamiclib -undefined dynamic_lookup
else
SHARED ?= -shared
endif
AOI_SRC := $(PLUTO_DIR)/lualib-src/lua-aoi

.PHONY: all clean
all: $(OUT_DIR)/aoi.so

$(OUT_DIR)/aoi.so: $(AOI_SRC)/lua_aoi.cpp $(AOI_SRC)/aoi.hpp $(AOI_SRC)/rect.hpp $(LUA_INC)/lua.h
	mkdir -p $(OUT_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -Wall -Wextra -fPIC $(SHARED) $(LDFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(OUT_DIR)/aoi.so
