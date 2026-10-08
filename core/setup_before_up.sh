# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

(
    envsubst < pangolin/config.template.yml > pangolin/config.yml &&
    envsubst < traefik/dynamic_config.template.yml > traefik/dynamic_config.yml &&
    envsubst < traefik/dashboard.template.yml > traefik/dashboard.yml &&
    envsubst < traefik/static_config.template.yml > traefik/static_config.yml &&
    mkdir -p $JOHNCLOUD_ROOT/traefik/GeoLite2 $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d/rules $JOHNCLOUD_ROOT/middleware-manager/config/middleware-manager &&
    cp ./traefik/dynamic_config.yml $JOHNCLOUD_ROOT/traefik/conf.d/rules &&
    cp ./traefik/dashboard.yml $JOHNCLOUD_ROOT/traefik/conf.d/rules &&
    cp ./traefik/static_config.yml $JOHNCLOUD_ROOT/traefik/conf.d/
)
