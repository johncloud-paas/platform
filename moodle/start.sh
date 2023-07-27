#! /bin/sh

sudo docker compose down
sudo rm -rf mariadb_data  moodle_data  moodledata_data
sudo docker compose up -d --remove-orphans
