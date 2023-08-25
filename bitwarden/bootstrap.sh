#! /bin/bash

sudo rm -rf /home/yann/johncloud_data/bitwarden
sudo docker compose down
sudo docker system prune --all --force
sudo docker compose up -d

