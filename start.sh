#! /bin/bash

git pull
./stop.sh
( set -a; source .env; set +a; envsubst < docker-compose.yml ) > /tmp/johncloud-docker-compose.yml
sudo docker stack deploy -c /tmp/johncloud-docker-compose.yml johncloud --detach=false
sudo docker service logs -f johncloud_traefik
