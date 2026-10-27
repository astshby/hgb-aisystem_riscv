#!/usr/bin/env bash
# Module: rt_thread_run
# Description: One standalone RT-Thread entry for the complete four-domain DDR system.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/rt-thread/run_system.py --xlen "${1:-32}"
