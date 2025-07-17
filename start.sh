#! /bin/bash

git pull
docker compose pull
docker compose down
docker compose up -d --remove-orphans --force-recreate
docker compose logs -f

