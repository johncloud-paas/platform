#! /bin/sh

sudo docker compose down
sudo docker compose pull
sudo docker compose up -d --remove-orphans
