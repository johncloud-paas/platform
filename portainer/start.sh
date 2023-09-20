#! /bin/sh

sudo docker stack rm portainer
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack config --compose-file - 
env $(cat .env | xargs) envsubst < ./docker-compose.yml | sudo docker stack deploy --compose-file - portainer
sudo docker service logs portainer_app -f
