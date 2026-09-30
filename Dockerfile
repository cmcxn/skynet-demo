ARG BUILDER_IMAGE=hanxi/skynet-builder@sha256:31b04c011d8d5c28840c51adececb0a5f5ceada0f50aeb46faa205e1ce552ea9
FROM ${BUILDER_IMAGE} AS build
USER root
WORKDIR /src/skynet
COPY vendor/skynet/ ./
RUN make linux -j4 && \
    mkdir -p /out/3rd/lua && \
    cp skynet /out/ && \
    cp -r cservice luaclib lualib service examples /out/ && \
    cp 3rd/lua/lua /out/3rd/lua/
COPY tests/client-socket.c tests/client-socket.c
RUN mkdir -p /out/tests/client && \
    gcc -O2 -fPIC -shared -I3rd/lua tests/client-socket.c -o /out/tests/client/socket.so -lpthread

FROM debian:trixie-slim
LABEL org.opencontainers.image.source="https://github.com/cloudwu/skynet" \
      org.opencontainers.image.version="1.8.0"
WORKDIR /skynet
COPY --from=build --chown=1000:1000 /out/ ./
COPY --chown=1000:1000 tests/ ./tests/
USER 1000:1000
EXPOSE 8888
CMD ["./skynet", "examples/config"]
