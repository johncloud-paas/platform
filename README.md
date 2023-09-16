First create the network:

    sudo docker swarm init
    sudo docker network create -d overlay --subnet=192.168.203.0/24 traefik-proxy 
    