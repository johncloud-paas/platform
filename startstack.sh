#!/bin/bash

SERVICE_DIR=`readlink -f $1`

( 
  cd $SERVICE_DIR &&
  sudo docker compose pull &&
  sudo docker compose down &&
  (if test -f setup_before_up.sh; then
    sudo bash ./setup_before_up.sh $SERVICE_DIR
  fi) &&
  sudo docker compose up -d --force-recreate --remove-orphans &&
  (if test -f setup_after_up.sh; then
    sudo bash ./setup_after_up.sh $SERVICE_DIR
  fi) &&
  sudo docker compose logs -f $2
)
