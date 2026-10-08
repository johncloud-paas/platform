# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    mkdir -p $JOHNCLOUD_ROOT/victoriametrics/data $JOHNCLOUD_ROOT/victorialogs/data $JOHNCLOUD_ROOT/victoriatraces/data $JOHNCLOUD_ROOT/fluent-bit &&
    cp ./victoriametrics/* $JOHNCLOUD_ROOT/victoriametrics &&
    cp ./fluent-bit/* $JOHNCLOUD_ROOT/fluent-bit
)
