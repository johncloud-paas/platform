#! /bin/sh

git pull
sudo docker compose down
sudo docker compose pull
( cd tcp_ping && pdm build )
sudo docker compose up -d --remove-orphans
sudo docker compose logs -f
