# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

SURICATA_DATA="$JOHNCLOUD_ROOT/suricata"

(
    # envsubst '$PUBLIC_IP_ADDRESS $JOHNCLOUD_ROOT' < fail2ban/jail.d/suricata.template.conf > fail2ban/jail.d/suricata.conf &&    
    mkdir -p $JOHNCLOUD_ROOT/vector
)
