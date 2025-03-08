#! /bin/sh

git pull
sudo docker compose down
sudo docker compose pull
sudo docker compose up -d --remove-orphans --force-recreate
sudo docker compose logs -f
