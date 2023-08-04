#! /bin/sh

sudo docker compose down
# sudo rm -rf db wordpress
sudo docker compose up -d --remove-orphans
