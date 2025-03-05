#! /bin/sh

git pull
sudo docker compose down
sudo mkdir -p bw-storage
sudo chown -R ydethe:101 bw-storage
sudo chmod 770 -R bw-storage
sudo docker compose pull
sudo docker compose up -d --remove-orphans
sudo docker compose logs -f
