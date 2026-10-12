#!/bin/bash

SERVICE_DIR=`readlink -f $1`

( 
  cd $SERVICE_DIR &&
  docker compose pull &&
  docker compose down &&
  (if test -f setup_before_up.sh; then
    bash ./setup_before_up.sh $SERVICE_DIR
  fi) &&
  docker compose up -d --force-recreate --remove-orphans &&
  (if test -f setup_after_up.sh; then
    bash ./setup_after_up.sh $SERVICE_DIR
  fi) &&
  docker compose logs -f $2
)
