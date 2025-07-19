#! /bin/bash

git pull
sudo docker service rm johncloud_portainer johncloud_traefik johncloud_oauth
env $(grep -v '^#' .env | xargs) envsubst < docker-compose.template.yml > docker-compose.yml
sudo docker stack deploy -c docker-compose.yml johncloud --detach=false 
sudo docker service logs -f johncloud_traefik
