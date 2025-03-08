First create the network:

    sudo docker network create -d bridge --subnet=10.20.30.0/24 bw-universe

    sudo mkdir -p $JOHNCLOUD_ROOT/bunkerweb/bw-storage
    sudo chown -R root:101 $JOHNCLOUD_ROOT/bunkerweb/bw-storage
    sudo chmod -R 770 $JOHNCLOUD_ROOT/bunkerweb/bw-storage
    sudo cp ./syslog-ng.conf $JOHNCLOUD_ROOT/bunkerweb/syslog-ng.conf

Define the root data folder in a .env file, 

    git clone https://github.com/johncloud-paas/platform.git
    cd platform
    ./start.sh

Then define all the `.env` files, for each service, using `sample.env` as template

To unban an IP address:

    sudo docker compose exec bunkerweb bwcli unban 1.2.3.4
