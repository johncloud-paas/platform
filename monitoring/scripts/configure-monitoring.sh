#!/usr/bin/env bash
set -Eeuo pipefail

(
    mkdir -p /victoriametrics/data /victorialogs/data /victoriatraces/data /fluent-bit &&
    cp /victoriametrics_src/* /victoriametrics &&
    cp /fluent-bit_src/* /fluent-bit
)
