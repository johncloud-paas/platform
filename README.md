Using Hardened docker images. First authenticate :

    docker login dhi.io

https://hub.docker.com/r/wallarm/gotestwaf#quick-start-with-docker

Google OAuth setup: https://www.libe.net/en-traefik-auth

First create the networks:

    sudo docker network create -d bridge --subnet=192.168.203.0/24 traefik-proxy 
    sudo docker network create -d bridge --subnet=173.16.238.0/24 hippias-docker-proxy
    sudo docker network create -d bridge --subnet=11.16.238.0/24 hippias-tailscale
    sudo docker network create -d bridge --subnet=12.16.238.0/24 hippias-databases

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

Edit the `/etc/systemd/resolved.conf` and uncomment DNSStubListener and change it to no, so it looks like this:
    
    DNSStubListener=no
    
For proxies:
https://www.reddit.com/r/selfhosted/comments/17wub9j/comment/lxvvmvy

Crowdsec configuration
https://blog.lrvt.de/configuring-crowdsec-with-traefik/

Docker daemon version

https://community.traefik.io/t/traefik-stops-working-it-uses-old-api-version-1-24/29019/10#p-61219-h-2-set-minimum-docker-api-version-3

Initial setup for authentik :

    $HOST/if/flow/initial-setup/
