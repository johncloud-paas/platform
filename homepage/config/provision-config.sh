# setup_before_up.sh
#! /bin/bash

(
    mkdir -p /app/config &&
    cp /scripts/*.yaml /app/config
)
