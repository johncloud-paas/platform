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
    sudo mkdir -p $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/loki/data $JOHNCLOUD_ROOT/alloy/geoip $JOHNCLOUD_ROOT/alloy/data $JOHNCLOUD_ROOT/prometheus/db &&
    sudo rm -rf $JOHNCLOUD_ROOT/prometheus/db &&
    sudo rm -rf $JOHNCLOUD_ROOT/alloy/data &&
    sudo rm -rf $JOHNCLOUD_ROOT/loki/config.yml &&
    sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d &&
    sudo cp ./loki/* $JOHNCLOUD_ROOT/loki &&
    sudo cp ./alloy/* $JOHNCLOUD_ROOT/alloy &&
    sudo mv ./GeoLite2-City.mmdb $JOHNCLOUD_ROOT/alloy/geoip &&
    sudo cp ./prometheus/* $JOHNCLOUD_ROOT/prometheus &&
    sudo docker compose up -d --remove-orphans --force-recreate &&
    sudo chown 65532:65532 -R $JOHNCLOUD_ROOT/traefik &&
    sudo chmod 755 $JOHNCLOUD_ROOT/traefik/plugins &&
    sudo chown 99:99 -R $JOHNCLOUD_ROOT/prometheus &&
    sudo chown 473:473 -R $JOHNCLOUD_ROOT/alloy &&
    sudo chown 10001:10001 -R $JOHNCLOUD_ROOT/loki &&
    sudo docker compose logs -f $1
)
