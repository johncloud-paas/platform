# How to deploy

First, create a copy of sample.env named .env, and fill the information.

    sudo docker swarm init
    sudo docker network create --driver=overlay --subnet xx.xx.xx.xx/xx --attachable traefik-proxy
    sudo docker secret create traefik-forward-auth.ini traefik-forward-auth.ini
    ./start.sh

    sudo docker config create loki-config.yaml loki/config.yml
    sudo docker config create promtail-config.yaml promtail/config.yml
    sudo docker config create prometheus-config.yaml prometheus/prometheus.yml
    sudo docker config create traefik-dynamic-config.yml traefik/traefik_dynamic_default.yml    
