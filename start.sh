#! /bin/sh

sudo docker stack rm traefik
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack config --compose-file - 
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack deploy --compose-file - traefik
sudo docker service logs traefik_traefik -f
