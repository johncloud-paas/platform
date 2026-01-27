#! /bin/bash

set -a; source .env; set +a

(
    git pull &&
    sudo docker compose pull &&
    sudo docker compose down &&
    envsubst < pangolin/config.yml.template > pangolin/config.yml &&
    sudo mkdir -p $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/alloy/geoip $JOHNCLOUD_ROOT/alloy/data $JOHNCLOUD_ROOT/prometheus/db &&
    sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d &&
    sudo cp ./alloy/* $JOHNCLOUD_ROOT/alloy &&
    sudo cp ./prometheus/* $JOHNCLOUD_ROOT/prometheus &&
    sudo docker compose up -d --remove-orphans &&
    sudo chmod 644 $JOHNCLOUD_ROOT/traefik/conf.d/* &&
    sudo chmod 755 -R $JOHNCLOUD_ROOT/traefik/plugins &&
    sudo chown 1000:1000 -R $JOHNCLOUD_ROOT/prometheus/* &&
    sudo chown 0:0 -R $JOHNCLOUD_ROOT/dockhand/* &&
    sudo chown 1001:1001 -R $JOHNCLOUD_ROOT/traefik/dashboard &&
    sudo chown 1001:1001 -R  $JOHNCLOUD_ROOT/traefik/agent/positions &&
    sudo docker compose logs -f $1
)
