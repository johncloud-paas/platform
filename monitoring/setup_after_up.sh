# setup_after_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

chown 1000:1000 -R $JOHNCLOUD_ROOT/prometheus/*
