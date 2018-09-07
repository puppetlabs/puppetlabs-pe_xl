#!/bin/bash

# This stanza configures PuppetDB to quickly fail on start. This is desirable
# in situations where PuppetDB WILL fail, such as when PostgreSQL is not yet
# configured, and we don't want to let PuppetDB wait five minutes before
# giving up on it.
if [ "$PT_shortcircuit_puppetdb" = "true" ]; then
	mkdir /etc/systemd/system/pe-puppetdb.service.d
	cat > /etc/systemd/system/pe-puppetdb.service.d/10-shortcircuit.conf <<-EOF
		[Service]
		TimeoutStartSec=1
		TimeoutStopSec=1
	EOF
	systemctl daemon-reload
fi

cd $(dirname "$PT_tarball")
mkdir puppet-enterprise && tar -xzf "$PT_tarball" -C puppet-enterprise --strip-components 1
./puppet-enterprise/puppet-enterprise-installer -c "$PT_peconf"

if [ "$PT_shortcircuit_puppetdb" = "true" ]; then
	rm /etc/systemd/system/pe-puppetdb.service.d/10-shortcircuit.conf
	systemctl daemon-reload
fi
