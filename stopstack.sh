#!/bin/bash

SERVICE_DIR=`readlink -f $1`

(
  cd $SERVICE_DIR &&
  (if test -f setup_before_down.sh; then
    bash ./setup_before_down.sh $SERVICE_DIR
  fi) &&
  docker compose down &&
  (if test -f setup_after_down.sh; then
    bash ./setup_after_down.sh $SERVICE_DIR
  fi)
)
