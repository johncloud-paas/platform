# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    mkdir -p $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d &&
    cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d
)
