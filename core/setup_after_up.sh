# setup_after_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    chmod 644 $JOHNCLOUD_ROOT/traefik/conf.d/* &&
    chmod 755 -R $JOHNCLOUD_ROOT/traefik/plugins &&
    chown 0:0 -R $JOHNCLOUD_ROOT/dockhand/* &&
    chown 1001:1001 -R $JOHNCLOUD_ROOT/traefik/dashboard &&
    chown 1001:1001 -R  $JOHNCLOUD_ROOT/traefik/agent/positions
)
