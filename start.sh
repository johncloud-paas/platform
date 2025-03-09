#! /bin/bash


if ! test -f .env; then
  echo "No .env file found"
  exit 1
fi

set -a && source .env && set +a

if [[ -z "${JOHNCLOUD_ROOT}" ]]; then
  echo "No JOHNCLOUD_ROOT variable in .env file"
  exit 1
fi

git pull
sudo docker compose down
sudo rm -rf $JOHNCLOUD_ROOT/bunkerweb/*
sudo mkdir -p $JOHNCLOUD_ROOT/bunkerweb/bw-storage
sudo chown -R root:101 $JOHNCLOUD_ROOT/bunkerweb/bw-storage
sudo chmod -R 770 $JOHNCLOUD_ROOT/bunkerweb/bw-storage
# sudo cp ./syslog-ng.conf $JOHNCLOUD_ROOT/bunkerweb/syslog-ng.conf
sudo docker compose pull
sudo docker compose up -d --remove-orphans --force-recreate
sudo docker compose logs -f 
