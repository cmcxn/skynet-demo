ARG BUILDER_IMAGE=hanxi/skynet-builder@sha256:31b04c011d8d5c28840c51adececb0a5f5ceada0f50aeb46faa205e1ce552ea9
FROM ${BUILDER_IMAGE} AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libssl-dev patch openssl ca-certificates g++ pkg-config && rm -rf /var/lib/apt/lists/*
COPY scripts/openssl-build-config.sh /usr/local/lib/openssl-build-config.sh
WORKDIR /src/skynet
COPY vendor/skynet/ ./
COPY patches/skynet-verified-client-tls.patch /tmp/skynet-verified-client-tls.patch
RUN patch --batch -p1 < /tmp/skynet-verified-client-tls.patch
RUN find . -type f \( -name '*.o' -o -name '*.a' -o -name '*.so' -o -name '*.dll' -o -name '*.exe' \) -delete && \
    . /usr/local/lib/openssl-build-config.sh && \
    make linux -j4 TLS_MODULE=ltls TLS_LIB="$TLS_LIB" TLS_INC="$TLS_INC" && \
    mkdir -p /out/3rd/lua && \
    cp skynet /out/ && \
    cp -r cservice luaclib lualib service examples /out/ && \
    cp 3rd/lua/lua /out/3rd/lua/ && \
    printf '\nenablessl = true\n' >> /out/examples/config
COPY components/skynet-llm/patches/skynet-socket-flow-control.patch /tmp/skynet-socket-flow-control.patch
RUN patch -p1 < /tmp/skynet-socket-flow-control.patch && \
    . /usr/local/lib/openssl-build-config.sh && \
    make linux -j4 TLS_MODULE=ltls TLS_LIB="$TLS_LIB" TLS_INC="$TLS_INC" && \
    cp skynet /out/ && cp -r luaclib/. /out/luaclib/ && cp -r lualib/. /out/lualib/
COPY vendor/lua-cjson/ /src/lua-cjson/
RUN make -C /src/lua-cjson LUA_VERSION=5.5 LUA_INCLUDE_DIR=/src/skynet/3rd/lua CJSON_CFLAGS="-fpic -pthread -DMULTIPLE_THREADS" CJSON_LDFLAGS="-shared -pthread -lm" && \
    cp /src/lua-cjson/cjson.so /out/luaclib/ && \
    cp -r /src/lua-cjson/lua/cjson /out/lualib/
COPY components/skynet-llm/ /src/skynet-llm/
RUN make -C /src/skynet-llm LUA_INC=/src/skynet/3rd/lua OUT_DIR=/out/luaclib && \
    cp -r /src/skynet-llm/lualib/. /out/lualib/ && \
    cp -r /src/skynet-llm/service/. /out/service/ && \
    mkdir -p /out/licenses/skynet-llm && \
    cp /src/skynet-llm/LICENSE /out/licenses/skynet-llm/ && \
    cp -r /src/skynet-llm/patches /out/licenses/skynet-llm/ && \
    mkdir -p /out/licenses/skynet && cp /src/skynet/LICENSE /out/licenses/skynet/ && \
    cp /tmp/skynet-verified-client-tls.patch /out/licenses/skynet/
# Preserve notices for bundled native dependencies in distributed images.
RUN mkdir -p /out/licenses/lua-cjson /out/licenses/jemalloc /out/licenses/lua && \
    cp /src/lua-cjson/LICENSE /out/licenses/lua-cjson/ && \
    cp /src/skynet/3rd/jemalloc/COPYING /out/licenses/jemalloc/ && \
    cp /src/skynet/3rd/lua/lua.h /out/licenses/lua/
# Only the AOI sources and license are needed from the Pluto repository.
COPY vendor/pluto/lualib-src/lua-aoi/ /src/pluto/lualib-src/lua-aoi/
COPY vendor/pluto/LICENSE /src/pluto/LICENSE
COPY components/skynet-aoi/ /src/skynet-aoi/
RUN make -C /src/skynet-aoi LUA_INC=/src/skynet/3rd/lua PLUTO_DIR=/src/pluto OUT_DIR=/out/luaclib && \
    cp -r /src/skynet-aoi/lualib/. /out/lualib/ && \
    mkdir -p /out/tests/aoi /out/licenses/pluto-aoi && \
    cp /src/skynet-aoi/tests/*.lua /out/tests/aoi/ && \
    cp /src/pluto/LICENSE /src/skynet-aoi/README.md /out/licenses/pluto-aoi/
COPY components/skynet-postgres/ /src/skynet-postgres/
RUN make -C /src/skynet-postgres LUA_INC=/src/skynet/3rd/lua OUT_DIR=/out/luaclib && \
    cp -r /src/skynet-postgres/lualib/. /out/lualib/ && \
    mkdir -p /out/licenses/skynet-postgres && \
    cp -r /src/skynet-postgres/licenses /out/licenses/skynet-postgres/ && \
    cp /src/skynet-postgres/LICENSE /src/skynet-postgres/SOURCES.md /src/skynet-postgres/SOURCE-SHA256.json /src/skynet-postgres/README.md /out/licenses/skynet-postgres/
# Pure Lua PostgREST client and private Skynet HTTP compatibility loader.
COPY vendor/postgrest-lua/postgrest/ /src/postgrest-lua/postgrest/
COPY vendor/postgrest-lua/LICENSE /src/postgrest-lua/LICENSE
COPY components/skynet-postgrest/ /src/skynet-postgrest/
RUN mkdir -p /out/lualib/postgrest /out/tests/postgrest /out/licenses/postgrest-lua && \
    cp /src/postgrest-lua/postgrest/database.lua /src/postgrest-lua/postgrest/query_builder.lua /src/postgrest-lua/postgrest/filter_builder.lua /src/postgrest-lua/postgrest/utils.lua /src/postgrest-lua/postgrest/constants.lua /out/lualib/postgrest/ && \
    cp /src/skynet-postgrest/lualib/*.lua /out/lualib/ && \
    cp /src/skynet-postgrest/tests/integration.lua /out/tests/postgrest/ && \
    cp /src/skynet-postgrest/tests/config-docker /out/tests/postgrest/config && \
    cp /src/postgrest-lua/LICENSE /src/skynet-postgrest/README.md /out/licenses/postgrest-lua/
COPY tests/client-socket.c tests/client-socket.c
RUN mkdir -p /out/tests/client && \
    gcc -O2 -fPIC -shared -I3rd/lua tests/client-socket.c -o /out/tests/client/socket.so -lpthread

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 ca-certificates openssl libstdc++6 && rm -rf /var/lib/apt/lists/*
COPY scripts/check-ca-trust.sh /tmp/ca-check/scripts/check-ca-trust.sh
COPY tests/fixtures/emudhra/ /tmp/ca-check/tests/fixtures/emudhra/
RUN sh /tmp/ca-check/scripts/check-ca-trust.sh && \
    mkdir -p /usr/local/share/skynet && \
    dpkg-query -W ca-certificates libssl3t64 > /usr/local/share/skynet/tls-packages.txt && \
    rm -rf /tmp/ca-check
LABEL org.opencontainers.image.source="https://github.com/cloudwu/skynet" \
      org.opencontainers.image.version="master-64391f7" \
      org.opencontainers.image.revision="64391f732e76507ea6615f312cb71be1fd7bfbdd"
WORKDIR /skynet
COPY --from=build --chown=1000:1000 /out/ ./
COPY --chown=1000:1000 tests/ ./tests/
USER 1000:1000
EXPOSE 8888
CMD ["./skynet", "examples/config"]
