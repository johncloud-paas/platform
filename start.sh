#! /bin/bash

git pull
env $(grep -v '^#' .env | xargs) envsubst < docker-compose.tpl > docker-compose.yml
sudo docker stack deploy -c docker-compose.yml stackdemo --detach=false 
sudo docker service logs -f stackdemo_traefik
