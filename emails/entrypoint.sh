#!/bin/sh

export BASENAME=$(echo $FQDN | rev | cut -d. -f -2 | rev) && envsubst < "/app/conf/postfix/main.cf" > "/etc/postfix/main.cf"

# Run the original command
exec "$@"
