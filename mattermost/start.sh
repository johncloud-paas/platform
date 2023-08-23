#! /bin/bash

set -o allexport
source .env set
+o allexport

sudo chown -R 2000:2000 ${JOHNCLOUD_ROOT}/mattermost
sudo docker compose -f docker-compose.yml -f docker-compose.without-nginx.yml down
sudo docker compose -f docker-compose.yml -f docker-compose.without-nginx.yml up -d
