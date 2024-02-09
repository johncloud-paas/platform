Base setup tutorial: https://github.com/traefik/traefik/issues/7825

Google OAuth setup: https://www.libe.net/en-traefik-auth

First create the network:

    sudo docker network create -d bridge --subnet=192.168.203.0/24 traefik-proxy 
    sudo docker network create -d bridge --subnet=192.168.205.0/24 platform-network

Define the root data folder in a .env file, 

    git clone https://github.com/ydethe/johncloud_paas.git
    cd johncloud_paas
    echo "JOHNCLOUD_ROOT=/path/to/root/of/paas/data" > .env

Then define all the `.env` files, for each service, using `sample.env` as template

For backup management, see https://velero.io/docs/v1.12
For online docs editing, this is interesting (though already in nextcloud) : https://www.onlyoffice.com/
