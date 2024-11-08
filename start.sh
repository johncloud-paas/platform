#! /bin/sh

# git pull
sudo docker compose down
sudo docker compose pull
sudo rm -rf /var/platform/posteio/*
# sudo mkdir -p /var/platform/posteio/ssl/letsencrypt
# sudo cp /var/platform/traefik/certs/mail.johntest.ovh/certificate.pem /var/platform/posteio/ssl/letsencrypt/ca.crt
# sudo cp /var/platform/traefik/certs/mail.johntest.ovh/privatekey.pem /var/platform/posteio/ssl/letsencrypt/server.key
# sudo chown mail:mail -R /var/platform/posteio
# sudo rm -rf /var/platform/traefik/certs/mail.johntest.ovh
# sudo rm -rf /var/platform/traefik/certs/posteio.johntest.ovh
sudo docker compose up -d --remove-orphans
sudo docker compose logs -f
