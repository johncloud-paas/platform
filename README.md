sudo docker swarm init
sudo docker network create --driver=overlay traefik_proxy
sudo docker stack deploy -c docker-compose.yml stackdemo --detach=false
