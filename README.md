# How to deploy

First, create a copy of sample.env named .env, and fill the information.

    cp traefik/traefik-forward-auth.sample.ini traefik-dynamic-config.yml # And fill the traefik-dynamic-config.yml file

    sudo docker swarm init
    sudo docker network create --driver=overlay --subnet xx.xx.xx.xx/xx --attachable traefik-proxy
    sudo docker secret create traefik-forward-auth.ini traefik-forward-auth.ini
    sudo docker config create loki-config.yaml loki/config.yml
    sudo docker config create promtail-config.yaml promtail/config.yml
    sudo docker config create prometheus-config.yaml prometheus/prometheus.yml
    sudo docker config create traefik-dynamic-config.yml traefik/traefik_dynamic_default.yml
    ./start.sh

    # enroll traefik bouncer
    sudo docker exec $(sudo docker ps -q -f name=crowdsec) cscli console enroll -e context xxxxx

    # install the firewall bouncer (nftables here)
    sudo apt install crowdsec-firewall-bouncer-nftables

    # create a new bouncer api key and make note of it
    sudo docker exec $(sudo docker ps -q -f name=crowdsec) cscli bouncer add firewall-bouncer

    # adjust firewall bouncer config
    sudo nano /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
    # 1. add the bouncer api key to the firewall-bouncer config
    # > api_key: <YOUR-API-KEY>
    # 2. configure the api url to the mapped port of the crowdsec container
    # > api_url: http://127.0.0.1:9876/

    # restart the service
    sudo service crowdsec-firewall-bouncer restart

    # confirm new bouncer 'firewall-bouncer' is active
    sudo docker exec $(sudo docker ps -q -f name=crowdsec) cscli bouncer list