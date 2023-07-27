#! /bin/sh

mkdir -p letsencrypt
sudo docker compose down
sudo docker compose up -d --remove-orphans
