# setup_after_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    chown 0:0 -R $JOHNCLOUD_ROOT/homepage/config/*
)
