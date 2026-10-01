ARG BUILDER_IMAGE=hanxi/skynet-builder@sha256:31b04c011d8d5c28840c51adececb0a5f5ceada0f50aeb46faa205e1ce552ea9
FROM ${BUILDER_IMAGE} AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src/skynet
COPY vendor/skynet/ ./
RUN make linux -j4 TLS_MODULE=ltls TLS_LIB=/usr/lib/x86_64-linux-gnu TLS_INC=/usr/include && \
    mkdir -p /out/3rd/lua && \
    cp skynet /out/ && \
    cp -r cservice luaclib lualib service examples /out/ && \
    cp 3rd/lua/lua /out/3rd/lua/ && \
    printf '\nenablessl = true\n' >> /out/examples/config
COPY vendor/lua-cjson/ /src/lua-cjson/
RUN make -C /src/lua-cjson LUA_VERSION=5.4 LUA_INCLUDE_DIR=/src/skynet/3rd/lua CJSON_CFLAGS="-fpic -pthread -DMULTIPLE_THREADS" CJSON_LDFLAGS="-shared -pthread -lm" && \
    cp /src/lua-cjson/cjson.so /out/luaclib/ && \
    cp -r /src/lua-cjson/lua/cjson /out/lualib/
COPY tests/client-socket.c tests/client-socket.c
RUN mkdir -p /out/tests/client && \
    gcc -O2 -fPIC -shared -I3rd/lua tests/client-socket.c -o /out/tests/client/socket.so -lpthread

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 ca-certificates && rm -rf /var/lib/apt/lists/*
LABEL org.opencontainers.image.source="https://github.com/cloudwu/skynet" \
      org.opencontainers.image.version="1.8.0"
WORKDIR /skynet
COPY --from=build --chown=1000:1000 /out/ ./
COPY --chown=1000:1000 tests/ ./tests/
USER 1000:1000
EXPOSE 8888
CMD ["./skynet", "examples/config"]
