# @summary Add or replace a replica host.
#   Supported use cases:
#   1: Adding a replica to an existing primary.
#   2: The existing replica is broken, we have a fresh new VM we want to provision the replica to.
# @param primary_host - The hostname and certname of the primary Puppet server
# @param replica_host - The hostname and certname of the replica VM
# @param token_file - (optional) the token file in a different location than the default.
plan peadm::add_replica(
  # Standard or Large
  Peadm::SingleTargetSpec           $primary_host,
  Peadm::SingleTargetSpec           $replica_host,

  # Common Configuration
  Optional[String] $token_file = undef,
) {
  $primary_target             = peadm::get_targets($primary_host, 1)
  $replica_target             = peadm::get_targets($replica_host, 1)

  $code_manager_enabled = run_task('peadm::code_manager_enabled', $primary_target).first.value['code_manager_enabled']

  if $code_manager_enabled == false {
    fail('Code Manager must be enabled to add a replica. Please refer to the docs for more information on enabling Code Manager.')
  }

  # Get current peadm config to ensure we forget active replicas
  $peadm_config = run_task('peadm::get_peadm_config', $primary_target).first.value

  $replica_postgresql_target = $peadm_config['params']['replica_postgresql_host']

  run_command('systemctl stop puppet.service', peadm::flatten_compact([
        $primary_target,
        $replica_postgresql_target,
  ]))

  # Make list of all possible replicas, configured and provided
  $replicas = peadm::flatten_compact([
      $replica_host,
      $peadm_config['params']['replica_host'],
  ]).unique

  $certdata = run_task('peadm::cert_data', $primary_target).first.value
  $primary_avail_group_letter = $certdata['extensions'][peadm::oid('peadm_availability_group')]
  $replica_avail_group_letter = $primary_avail_group_letter ? { 'A' => 'B', 'B' => 'A' }

  # replica certname + any non-certname alt-names from the primary. Make sure
  # to Handle the case where there are no alt-names in the primary's certdata.
  $dns_alt_names = [$replica_target.peadm::certname()] + (pick($certdata['dns-alt-names'], []) - $certdata['certname'])

  # This has the effect of revoking the node's certificate, if it exists
  $replicas.each |$replica| {
    run_command("/opt/puppetlabs/bin/puppet infrastructure forget ${replica}", $primary_target, _catch_errors => true)
  }

  run_plan('peadm::subplans::component_install', $replica_target,
    primary_host       => $primary_target,
    avail_group_letter => $replica_avail_group_letter,
    role               => 'puppet/server',
    dns_alt_names      => $dns_alt_names
  )

  # Wrap these things that operate on replica_postgresql_target in an if statement
  # to avoid failures retrieving PSQL version because you can't operate functions
  # on a return value of nil.
  if $replica_postgresql_target {
    # On the PE-PostgreSQL server in the <replacement-avail-group-letter> group
    $psql_version = run_task('peadm::get_psql_version', $replica_postgresql_target).first.value['version']

    # Stop puppet and add the following two lines to
    # /opt/puppetlabs/server/data/postgresql/11/data/pg_ident.conf
    #  pe-puppetdb-pe-puppetdb-map <replacement-replica-fqdn> pe-puppetdb
    #  pe-puppetdb-pe-puppetdb-migrator-map <replacement-replica-fqdn> pe-puppetdb-migrator
    apply($replica_postgresql_target) {
      file_line { 'pe-puppetdb-pe-puppetdb-map':
        path => "/opt/puppetlabs/server/data/postgresql/${psql_version}/data/pg_ident.conf",
        line => "pe-puppetdb-pe-puppetdb-map ${replica_target.peadm::certname()} pe-puppetdb",
      }
      file_line { 'pe-puppetdb-pe-puppetdb-migrator-map':
        path => "/opt/puppetlabs/server/data/postgresql/${psql_version}/data/pg_ident.conf",
        line => "pe-puppetdb-pe-puppetdb-migrator-map ${replica_target.peadm::certname()} pe-puppetdb-migrator",
      }
      file_line { 'pe-puppetdb-pe-puppetdb-read-map':
        path => "/opt/puppetlabs/server/data/postgresql/${psql_version}/data/pg_ident.conf",
        line => "pe-puppetdb-pe-puppetdb-read-map ${replica_target.peadm::certname()} pe-puppetdb-read",
      }
    }

    run_command('systemctl reload pe-postgresql.service', $replica_postgresql_target)
  }

  run_plan('peadm::util::update_classification', $primary_target,
    server_a_host                    => $replica_avail_group_letter ? { 'A' => $replica_target.peadm::certname(), default => undef },
    server_b_host                    => $replica_avail_group_letter ? { 'B' => $replica_target.peadm::certname(), default => undef },
    internal_compiler_a_pool_address => $replica_avail_group_letter ? { 'A' => $replica_target.peadm::certname(), default => undef },
    internal_compiler_b_pool_address => $replica_avail_group_letter ? { 'B' => $replica_target.peadm::certname(), default => undef },
    peadm_config                     => $peadm_config
  )

  # Source list of files on Primary and synchronize to new Replica
  $content_sources = [
    '/opt/puppetlabs/server/data/console-services/certs/ad_ca_chain.pem',
    '/etc/puppetlabs/orchestration-services/conf.d/secrets/keys.json',
    '/etc/puppetlabs/orchestration-services/conf.d/secrets/orchestrator-encryption-keys.json',
    '/etc/puppetlabs/console-services/conf.d/secrets/keys.json',
    '/etc/puppetlabs/puppet/hiera.yaml',
  ]
  parallelize($content_sources) |$path| {
    run_plan('peadm::util::copy_file', $replica_target,
      source_host   => $primary_target,
      path          => $path
    )
  }

  # Provision the new system as a replica
  run_task('peadm::provision_replica', $primary_target,
    replica    => $replica_target.peadm::certname(),
    token_file => $token_file,

    # Race condition, where the provision command checks PuppetDB status and
    # probably gets "starting", but fails out because that's not "running".
    # Can remove flag when that issue is fixed.
    legacy     => false,
    # _catch_errors => true, # testing
  )

  # start puppet service
  run_command('systemctl start puppet.service', peadm::flatten_compact([
        $primary_target,
        $replica_postgresql_target,
        $replica_target,
  ]))

  return("Added replica ${replica_target}")
}
