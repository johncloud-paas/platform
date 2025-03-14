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
sudo docker compose pull
sudo docker compose down
if [[ "${ERASE_BW_FOLDERS}" = "yes" ]]; then
  echo "Erasing $JOHNCLOUD_ROOT/bunkerweb/*"
  sudo rm -rf $JOHNCLOUD_ROOT/bunkerweb/*
fi

# sudo mkdir -p $JOHNCLOUD_ROOT/bunkerweb/bw-storage
# sudo chown -R root:101 $JOHNCLOUD_ROOT/bunkerweb/bw-storage
# sudo chmod -R 770 $JOHNCLOUD_ROOT/bunkerweb/bw-storage

sudo mkdir -p $JOHNCLOUD_ROOT/bunkerweb/letsencrypt
sudo chown -R root:101 $JOHNCLOUD_ROOT/bunkerweb/letsencrypt
sudo chmod -R 770 $JOHNCLOUD_ROOT/bunkerweb/letsencrypt

sudo cp ./syslog-ng.conf $JOHNCLOUD_ROOT/bunkerweb/syslog-ng.conf
sudo docker compose up -d --remove-orphans --force-recreate
sudo docker compose logs -f 
