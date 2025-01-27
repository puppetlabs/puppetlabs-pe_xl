#!/bin/bash

# Try and ensure locale is correctly configured
[ -z "${LANG}" ] && export LANG=$(localectl status | sed -n 's/.* LANG=\(.*\)/\1/p')

# declare task parameters for linting
declare PT_token_file
declare PT_legacy
declare PT_replica

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
  echo "(legacy=false) query active nodes before provision replica"
  puppet query '["from","resources",["extract",["certname"],["and",["=","type","Class"],["=","title","Puppet_enterprise::Profile::Master"]]]]'

  puppet infrastructure provision replica "$PT_replica" \
    --color false \
    --yes --token-file "$TOKEN_FILE" \
    $AGENT_CONFIG \
    --topology "$PT_topology" \
    --enable

elif [ "$PT_legacy" = "true" ]; then
  echo "(legacy=true) query active nodes before provision replica"
  puppet query '["from","resources",["extract",["certname"],["and",["=","type","Class"],["=","title","Puppet_enterprise::Profile::Master"]]]]'

  puppet infrastructure provision replica "$PT_replica" \
    --color false \
    --token-file "$TOKEN_FILE"

  echo "(legacy=true) query active nodes before enable replica"
  puppet query '["from","resources",["extract",["certname"],["and",["=","type","Class"],["=","title","Puppet_enterprise::Profile::Master"]]]]'
  puppet infrastructure enable replica "$PT_replica" \
    --color false \
    --yes --token-file "$TOKEN_FILE" \
    $AGENT_CONFIG \
    --topology "$PT_topology"

else
  exit 1
fi
