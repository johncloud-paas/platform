# How to deploy

First, create a copy of sample.env named .env, and fill the information.

    sudo docker swarm init
    sudo docker network create --driver=overlay --subnet xx.xx.xx.xx/xx --attachable traefik-proxy
    sudo docker secret create traefik-forward-auth.ini traefik-forward-auth.ini
    ./start.sh

