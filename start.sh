#! /bin/bash

git pull
./stop.sh
env $(grep -v '^#' .env | xargs) envsubst < docker-compose.template.yml > docker-compose.yml
sudo docker stack deploy -c docker-compose.yml johncloud --detach=false 
sudo docker service logs -f johncloud_oauth
