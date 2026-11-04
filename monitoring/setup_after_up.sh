# setup_after_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

sudo chmod o+r -R ${JOHNCLOUD_ROOT}/suricata/logs
