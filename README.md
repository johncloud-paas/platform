Google OAuth setup: https://www.libe.net/en-traefik-auth

First create the network:

    sudo docker network create -d bridge --subnet=192.168.203.0/24 traefik-proxy 
    sudo docker network create -d bridge --subnet=192.168.205.0/24 platform-network

Define the root data folder in a .env file, 

    git clone https://github.com/johncloud-paas/platform.git
    cd platform
    ./start.sh

Then define all the `.env` files, for each service, using `sample.env` as template

For online docs editing, this is interesting (though already in nextcloud) : https://www.onlyoffice.com/

Install `ufw` and `rsyslog`

Install `alloy` : https://grafana.com/docs/alloy/latest/
Copy `config.alloy` in `/etc/alloy`
Give to the user `alloy` the ownership on `/etc/alloy` and `/var/lib/alloy`, and read/write permissions

Observability is done with Sumo Logic. It is run at host level with otelcol-sumo.service

