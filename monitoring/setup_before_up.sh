# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    mkdir -p $JOHNCLOUD_ROOT/alloy/geoip $JOHNCLOUD_ROOT/alloy/data $JOHNCLOUD_ROOT/prometheus/db &&
    cp ./alloy/* $JOHNCLOUD_ROOT/alloy &&
    cp ./prometheus/* $JOHNCLOUD_ROOT/prometheus
)
