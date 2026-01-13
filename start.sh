#! /bin/bash

set -a; source .env; set +a

(
    rm -rf GeoLite2-City.mmdb* &&
    wget https://cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz &&
    gunzip -d GeoLite2-City.mmdb.gz
)

(
    git pull &&
    sudo docker compose pull &&
    sudo docker compose down &&
    # sudo docker network rm -f $TRAEFIK_NETWORK $PROXY_NETWORK $TAILSCALE_NETWORK &&
    # sudo docker network create -d bridge --subnet=$TRAEFIK_NET.0/24 $TRAEFIK_NETWORK &&
    # sudo docker network rm -f $PROXY_NETWORK $TAILSCALE_NETWORK &&
    # sudo docker network create -d bridge --subnet=$PROXY_NET.0/24 $PROXY_NETWORK &&
    # sudo docker network create -d bridge --subnet=$TAILSCALE_NET.0/24 $TAILSCALE_NETWORK &&
    sudo mkdir -p $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/alloy/geoip $JOHNCLOUD_ROOT/alloy/data $JOHNCLOUD_ROOT/prometheus/db &&
    sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d &&
    sudo cp ./alloy/* $JOHNCLOUD_ROOT/alloy &&
    sudo cp ./prometheus/* $JOHNCLOUD_ROOT/prometheus &&
    sudo mv ./GeoLite2-City.mmdb $JOHNCLOUD_ROOT/alloy/geoip &&
    sudo docker compose up -d --remove-orphans &&
    sudo chmod 644 $JOHNCLOUD_ROOT/traefik/conf.d/* &&
    sudo chmod 755 -R $JOHNCLOUD_ROOT/traefik/plugins &&
    sudo chown 1000:1000 -R $JOHNCLOUD_ROOT/prometheus/* &&
    sudo chown 0:0 -R $JOHNCLOUD_ROOT/dockhand/* &&
    sudo chown 1001:1001 -R $JOHNCLOUD_ROOT/traefik/dashboard &&
    sudo chown 1001:1001 -R  $JOHNCLOUD_ROOT/traefik/agent/positions &&
    sudo docker compose logs -f $1
)
