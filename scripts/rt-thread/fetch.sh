#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# 内核源码已随 Git 保存，此兼容入口现在只校验固定版本和全部源文件 SHA。
python3 scripts/rt-thread/verify.py "${RTTHREAD_ROOT:-third_party/rt-thread}"
