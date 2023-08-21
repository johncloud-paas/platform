#! /bin/sh


sudo docker run \
--sig-proxy=false \
--name nextcloud-aio-mastercontainer \
--restart unless-stopped \
--publish 8081:8080 \
--env APACHE_PORT=11000 \
--env APACHE_IP_BINDING=127.0.0.1 \
--env NEXTCLOUD_DATADIR="/home/yann/.ncdata" \
--volume nextcloud_aio_mastercontainer:./docker-aio-config \
--volume /var/run/docker.sock:/var/run/docker.sock:ro \
nextcloud/all-in-one:latest

