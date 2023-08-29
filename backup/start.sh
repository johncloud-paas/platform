#! /bin/bash

set -o allexport
source .env
set +o allexport

sudo docker compose down
sudo docker compose up -d --remove-orphans

