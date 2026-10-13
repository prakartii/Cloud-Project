#!/bin/bash
# Dependency-free load generator: N parallel workers hammering the CPU-heavy endpoint.
# Usage: ./loadtest/curl-load.sh http://<alb-dns-name> [workers=40] [seconds=600]
set -euo pipefail
BASE="${1:?usage: $0 <base-url> [workers] [seconds]}"
WORKERS="${2:-40}"
SECONDS_TO_RUN="${3:-600}"
END=$((SECONDS + SECONDS_TO_RUN))
echo "Sending load to $BASE with $WORKERS workers for ${SECONDS_TO_RUN}s (Ctrl+C to stop)"
worker() { while [ $SECONDS -lt $END ]; do curl -s -o /dev/null "$BASE/api/stress?ms=300"; done; }
for _ in $(seq "$WORKERS"); do worker & done
wait
