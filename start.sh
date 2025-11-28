#! /bin/bash

set -a; source .env; set +a

git pull
sudo docker compose pull
sudo docker compose down
sudo mkdir -p $JOHNCLOUD_ROOT/traefik/conf.d $JOHNCLOUD_ROOT/loki $JOHNCLOUD_ROOT/promtail $JOHNCLOUD_ROOT/prometheus
sudo rm -rf $JOHNCLOUD_ROOT/prometheus/db
sudo rm -rf $JOHNCLOUD_ROOT/loki/config.yml
sudo cp ./traefik/* $JOHNCLOUD_ROOT/traefik/conf.d
sudo cp ./loki/* $JOHNCLOUD_ROOT/loki
sudo cp ./promtail/* $JOHNCLOUD_ROOT/promtail
sudo cp ./prometheus/* $JOHNCLOUD_ROOT/prometheus
sudo docker compose up -d --remove-orphans --force-recreate
# sudo docker compose logs -f traefik
