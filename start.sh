#! /bin/sh

sudo docker stack rm platform
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack config --compose-file - 
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack deploy --compose-file - platform
sudo docker service logs platform_traefik -f
