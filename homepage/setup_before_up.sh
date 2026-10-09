# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    mkdir -p $JOHNCLOUD_ROOT/homepage/config &&
    cp ./config/* $JOHNCLOUD_ROOT/homepage/config
)
