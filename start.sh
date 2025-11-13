#! /bin/bash

set -a; source .env; set +a

git pull
sudo docker compose pull
sudo docker compose down
sudo mkdir -p $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/loki $JOHNCLOUD_ROOT/promtail $JOHNCLOUD_ROOT/prometheus
sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d
sudo cp ./loki/config.yml $JOHNCLOUD_ROOT/loki
sudo cp ./promtail/config.yml:$JOHNCLOUD_ROOT/promtail
sudo cp ./prometheus/*:$JOHNCLOUD_ROOT/prometheus
sudo docker compose up -d --remove-orphans --force-recreate
# sudo docker compose logs -f traefik
