#!/bin/bash

export USER=$(id -un)
export HOME=$(getent passwd "$USER" | cut -d : -f 6)
export PATH="/opt/puppetlabs/bin:${PATH}"

if [ -z "$PT_token_file" -o "$PT_token_file" = "null" ]; then
  export TOKEN_FILE="${HOME}/.puppetlabs/token"
else
  export TOKEN_FILE="$PT_token_file"
fi

if [ "$PT_topology" = "mono" ] ; then
  AGENT_CONFIG=""
else
  AGENT_CONFIG="--skip-agent-config"
fi

set -e

if [ "$PT_legacy" = "false" ]; then
  puppet infrastructure provision replica "$PT_master_replica" \
    --yes --token-file "$TOKEN_FILE" \
    $AGENT_CONFIG \
    --topology "$PT_topology" \
    --enable

elif [ "$PT_legacy" = "true" ]; then
  puppet infrastructure provision replica "$PT_master_replica" \
    --token-file "$TOKEN_FILE"

  puppet infrastructure enable replica "$PT_master_replica" \
    --yes --token-file "$TOKEN_FILE" \
    $AGENT_CONFIG \
    --topology "$PT_topology"

else
  exit 1
fi
