#!/bin/bash

SERVICE_DIR=`readlink -f $1`

(
  cd $SERVICE_DIR &&
  docker compose ps
)
