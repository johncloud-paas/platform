#! /bin/bash

source .env

sudo docker compose down
sudo docker compose up -d --remove-orphans

