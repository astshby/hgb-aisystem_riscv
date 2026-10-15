#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/loader
gcc -std=c99 -Wall -Wextra -Werror -shared -fPIC -Isoftware/loader \
    software/loader/protocol.c tb/loader/host_backend.c -o build/loader/protocol.so
python3 scripts/loader/test_protocol.py build/loader/protocol.so "$@"
