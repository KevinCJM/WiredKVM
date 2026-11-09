#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build/ch32v407/tests"
mkdir -p "$BUILD"
FLAGS=(-g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -Wall -Wextra -Werror
    -I"$ROOT/firmware/ch32v407" -I"$ROOT/firmware/main" -I"$ROOT/native")
clang -std=c11 "${FLAGS[@]}" -c "$ROOT/firmware/ch32v407/bridge.c" -o "$BUILD/bridge-asan.o"
clang -std=c11 "${FLAGS[@]}" -c "$ROOT/firmware/main/wire_protocol.c" -o "$BUILD/protocol-asan.o"
clang++ -std=c++17 "${FLAGS[@]}" "$ROOT/tests/ch32v407_core_test.cpp" "$BUILD/bridge-asan.o" "$BUILD/protocol-asan.o" -o "$BUILD/core-test"
"$BUILD/core-test"
