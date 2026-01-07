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
    sudo docker network rm $RAEFIK_NETWORK $PROXY_NETWORK $TAILSCALE_NETWORK &&
    sudo docker network create -d bridge --subnet=$UNIVERSE_NET.0/24 $TRAEFIK_NETWORK &&
    sudo docker network create -d bridge --subnet=$PROXY_NET.0/24 $PROXY_NETWORK &&
    sudo docker network create -d bridge --subnet=$TAILSCALE_NET.0/24 $TAILSCALE_NETWORK &&
    sudo mkdir -p $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/alloy/geoip $JOHNCLOUD_ROOT/alloy/data &&
    sudo rm -rf $JOHNCLOUD_ROOT/alloy/data &&
    sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d &&
    sudo cp ./alloy/* $JOHNCLOUD_ROOT/alloy &&
    sudo mv ./GeoLite2-City.mmdb $JOHNCLOUD_ROOT/alloy/geoip &&
    sudo docker compose up -d --remove-orphans &&
    sudo chmod 644 $JOHNCLOUD_ROOT/traefik/conf.d/* &&
    sudo chmod 755 $JOHNCLOUD_ROOT/traefik/plugins &&
    sudo docker compose logs -f $1
)
