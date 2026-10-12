# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

# Build the routed-domain blocks from the comma-separated ROUTED_DOMAINS env var.
# domain1 is reserved for $HOST, so numbering starts at domain2.
ROUTED_DOMAINS_BLOCKS=""
i=2
IFS=',' read -ra _routed <<< "$ROUTED_DOMAINS"
for d in "${_routed[@]}"; do
    d="$(echo "$d" | xargs)"   # trim surrounding whitespace
    [ -z "$d" ] && continue
    ROUTED_DOMAINS_BLOCKS+="  domain${i}:"$'\n'
    ROUTED_DOMAINS_BLOCKS+="    base_domain: \"${d}\""$'\n'
    ROUTED_DOMAINS_BLOCKS+="    cert_resolver: \"letsencrypt\""$'\n'
    i=$((i + 1))
done
export ROUTED_DOMAINS_BLOCKS

(
    envsubst < pangolin/config.template.yml > pangolin/config.yml &&
    envsubst < traefik/dynamic_config.template.yml > traefik/dynamic_config.yml &&
    envsubst < traefik/dashboard.template.yml > traefik/dashboard.yml &&
    envsubst < traefik/static_config.template.yml > traefik/static_config.yml &&
    mkdir -p $JOHNCLOUD_ROOT/traefik/GeoLite2 $JOHNCLOUD_ROOT/traefik/agent/positions $JOHNCLOUD_ROOT/traefik/dashboard $JOHNCLOUD_ROOT/traefik/plugins $JOHNCLOUD_ROOT/traefik/conf.d/rules &&
    cp ./traefik/dynamic_config.yml $JOHNCLOUD_ROOT/traefik/conf.d/rules &&
    cp ./traefik/dashboard.yml $JOHNCLOUD_ROOT/traefik/conf.d/rules &&
    cp ./traefik/static_config.yml $JOHNCLOUD_ROOT/traefik/conf.d/
)
