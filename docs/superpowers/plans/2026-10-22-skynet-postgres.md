# Skynet PostgreSQL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package the existing PostgreSQL/vector libraries as a tested Skynet component.
**Architecture:** Preserve pgmoon APIs and codecs. Replace socket and crypto adapters;
reuse an attributed independent snapshot of the existing verified memory-BIO TLS implementation.
**Tech Stack:** Lua 5.5, Skynet, OpenSSL 3, PostgreSQL, pgvector, Docker and MinGW/Wine.
**Spec:** ../specs/2026-10-22-skynet-postgres-design.md

## Global Constraints
- Do not modify the source mao repository or existing untracked user files.
- TLS verifies chain and target DNS/IP; no insecure verification mode or implicit downgrade.
- Millisecond operation deadlines close failed connections; no automatic retry of SQL.
- Windows secure RNG must not depend on /dev/urandom.
- Preserve source hashes and upstream MIT licenses; record unknown local revision provenance honestly.

## Review Focus
Authentication and TLS downgrade, timeout fd/session cleanup, query protocol errors,
concurrent connection use, parameter serialization and Windows packaging.

## Task 1: Port and repair transport and crypto
- [x] Copy source libraries and provenance; write failing tests for secure RNG, crypto,
  verified TLS defaults, invalid timeout, concurrent use and timeout cleanup.
- [x] Run tests and confirm expected failures against the original adapters.
- [x] Implement native crypto, socket TLS/deadlines and pgmoon lifecycle guards.
- [x] Run Lua unit tests and real DB integration, including wrong CA/hostname and refused SSL.
Expected: tests pass with real SCRAM/TLS and no leaked sockets.

## Task 2: Build and cross-platform integration
- [x] Install component in Dockerfile, Windows compile.sh and build-native.sh.
- [x] Add test runner with ephemeral PostgreSQL/pgvector and certificate fixtures.
- [x] Build Linux/Windows packages; run Linux and Windows/Wine database suites.
Expected: the packaged module works without external Lua dependencies.

## Task 3: Documentation and final regression
- [x] Document install, connect/query/transactions/vector, timeout/errors, TLS and platform limits.
- [x] Run existing HTTP proxy, TLS/CA and LLM regressions.
- [x] Run independent review, fix actionable defects and rerun targeted/full relevant suites.
- [x] Sync CodeGraph and preserve complete verification results.
Expected: docs match tested APIs; old functionality remains green.


## Verification record

Initial implementation verified on codex/skynet-postgres, base e81de10.
Master/AOI integration is recorded by subsequent commits; no production deployment.
All three runtime modes passed 32 real PostgreSQL integration groups. Windows native
DNS discovery and RNG known-vector tests passed under Wine 10; physical Windows
validation remains outstanding. Fresh Linux native build and component rebuild passed.
Existing HTTP proxy 49/49, TLS 25 + default-directory control, LLM TLS 9, WSS 10 groups,
CA 12 negative chains, LLM mock and TCP Demo passed.
Independent review found notification ownership and same-coroutine callback reentry;
both reproduced with failing regressions, fixed and re-reviewed. Windows CA bundle and
real Windows DNS discovery gaps also addressed. Shared resolver initialization-order
limit is documented; no vendor modifications required. Wine registry persistence was a
test-harness issue: initialize with wineboot -u and await wineserver shutdown.
Full logs are in .local/postgres-results (ignored). Source file hashes remain unchanged.
