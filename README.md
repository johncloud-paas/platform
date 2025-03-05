First create the network:

    sudo docker network create -d bridge --subnet=10.20.30.0/24 bw-universe

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

To unban an IP address:

    sudo docker compose exec bunkerweb bwcli unban 1.2.3.4
