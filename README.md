# How to deploy

First, create a copy of sample.env named .env, and fill the information.

    sudo docker swarm init
    sudo docker network create --driver=overlay --attachable traefik-proxy
    ./start.sh
