#!/bin/sh
# Initialize the project's dependencies, not Pluto's unrelated Skynet fork.
set -eu
cd "$(dirname "$0")/.."
git submodule update --init vendor/skynet vendor/lua-cjson vendor/pluto vendor/postgrest-lua
git -C vendor/skynet submodule update --init --recursive
