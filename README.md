First create the network:

    sudo docker swarm init
    sudo docker network create -d overlay --subnet=192.168.203.0/24 traefik-proxy 
    
https://tienbm90.medium.com/how-to-change-docker-root-data-directory-89a39be1a70b
