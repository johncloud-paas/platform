#! /bin/sh

sudo docker compose -f docker-compose.yml -f docker-compose.without-nginx.yml down
sudo docker compose -f docker-compose.yml -f docker-compose.without-nginx.yml up -d
