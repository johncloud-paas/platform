#! /bin/sh

git pull
sudo docker compose down
sudo rm -rf /home/yann/johncloud_data/bunkerweb/*
sudo mkdir -p /home/yann/johncloud_data/bunkerweb/bw-storage
sudo chown -R root:101 /home/yann/johncloud_data/bunkerweb/bw-storage
sudo chmod -R 770 /home/yann/johncloud_data/bunkerweb/bw-storage
# sudo cp ./syslog-ng.conf /home/yann/johncloud_data/bunkerweb/syslog-ng.conf
sudo docker compose pull
sudo docker compose up -d --remove-orphans --force-recreate
sudo docker compose logs -f 
