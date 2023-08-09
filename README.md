Base setup tutorial: https://github.com/traefik/traefik/issues/7825

Google OAuth setup: https://www.libe.net/en-traefik-auth

First create the network:

    sudo docker network create -d bridge --subnet=192.168.203.0/24 traefik-proxy 
