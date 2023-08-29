#! /bin/bash

set -o allexport
source .env
set +o allexport

# sudo docker compose down
envsubst < config/config.php.template > config/config.php
# sudo docker compose up -d --remove-orphans
