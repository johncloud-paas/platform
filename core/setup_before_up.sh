# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    envsubst < pangolin/config.yml.template > pangolin/config.yml &&
    envsubst < traefik/dynamic_config.yml.template > traefik/dynamic_config.yml &&
    mkdir -p $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d &&
    cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d
)
