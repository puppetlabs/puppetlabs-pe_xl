# @api private
#
# @summary Configure first-time classification and DR setup
#
# @param compiler_pool_address 
#   The service address used by agents to connect to compilers, or the Puppet
#   service. Typically this is a load balancer.
# @param internal_compiler_a_pool_address
#   A load balancer address directing traffic to any of the "A" pool
#   compilers. This is used for DR configuration in large and extra large
#   architectures.
# @param internal_compiler_b_pool_address
#   A load balancer address directing traffic to any of the "B" pool
#   compilers. This is used for DR configuration in large and extra large
#   architectures.
# @param ldap_config
#   This hash contains the options necessary for configuring the LDAP
#   connection on the main server.
# @param final_agent_state
#   Configures the state the puppet agent should be in on infrastructure nodes
#   after PE is configured successfully.
#
plan peadm::subplans::configure (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts = undef,
  Optional[TargetSpec]              $legacy_compilers = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host = undef,

  # Common Configuration
  String                       $compiler_pool_address            = $primary_host.peadm::certname(),
  Optional[String]             $internal_compiler_a_pool_address = undef,
  Optional[String]             $internal_compiler_b_pool_address = undef,
  Optional[String]             $token_file                       = undef,
  Optional[String]             $deploy_environment               = undef,
  Optional[Peadm::Ldap_config] $ldap_config                      = undef,

  # Other
  String           $stagingdir                   = '/tmp',
  Enum['running', 'stopped'] $final_agent_state  = 'running'
) {
  # TODO: get and validate PE version

  # Convert inputs into targets.
  $primary_target                   = peadm::get_targets($primary_host, 1)
  $replica_target                   = peadm::get_targets($replica_host, 1)
  $replica_postgresql_target        = peadm::get_targets($replica_postgresql_host, 1)
  $compiler_targets                 = peadm::get_targets($compiler_hosts)
  $legacy_compiler_targets                   = peadm::get_targets($legacy_compilers)
  $primary_postgresql_target        = peadm::get_targets($primary_postgresql_host, 1)

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
    $legacy_compilers,
  )

  # Source list of files on Primary and synchronize to new Replica
  $common_content_source   = '/etc/puppetlabs/puppet/hiera.yaml'
  $replica_content_sources = [
    '/opt/puppetlabs/server/data/console-services/certs/ad_ca_chain.pem',
    '/etc/puppetlabs/orchestration-services/conf.d/secrets/keys.json',
    '/etc/puppetlabs/orchestration-services/conf.d/secrets/orchestrator-encryption-keys.json',
    '/etc/puppetlabs/console-services/conf.d/secrets/keys.json',
  ]

  run_plan('peadm::util::copy_file', peadm::flatten_compact([
        $replica_target,
        $compiler_targets,
        $legacy_compiler_targets,
    ]),
    source_host   => $primary_target,
    path          => $common_content_source
  )

  parallelize($replica_content_sources) |$path| {
    run_plan('peadm::util::copy_file', $replica_target,
      source_host   => $primary_target,
      path          => $path
    )
  }

  # Set up the console node groups to configure the various hosts in their roles

  apply($primary_target) {
    class { 'peadm::setup::node_manager_yaml':
      primary_host => $primary_target.peadm::certname(),
    }

    class { 'peadm::setup::node_manager':
      primary_host                     => $primary_target.peadm::certname(),
      server_a_host                    => $primary_target.peadm::certname(),
      server_b_host                    => $replica_target.peadm::certname(),
      postgresql_a_host                => $primary_postgresql_target.peadm::certname(),
      postgresql_b_host                => $replica_postgresql_target.peadm::certname(),
      compiler_pool_address            => $compiler_pool_address,
      internal_compiler_a_pool_address => $internal_compiler_a_pool_address,
      internal_compiler_b_pool_address => $internal_compiler_b_pool_address,
      require                          => Class['peadm::setup::node_manager_yaml'],
    }
  }

  if $arch['disaster-recovery'] {
    # Run the PE Replica Provision
    run_task('peadm::provision_replica', $primary_target,
      replica    => $replica_target.peadm::certname(),
      token_file => $token_file,

      # Race condition, where the provision command checks PuppetDB status and
      # probably gets "starting", but fails out because that's not "running".
      # Can remove flag when that issue is fixed.
      legacy     => true,
    )
  }

  if $ldap_config {
    $pe_version = run_task('peadm::read_file', $primary_target,
      path => '/opt/puppetlabs/server/pe_version',
    )[0][content].chomp

    # Run the task to configure ldap
    $ldap_result = run_task('peadm::pe_ldap_config', $primary_target,
      pe_main         => $primary_target.peadm::certname(),
      ldap_config     => $ldap_config,
      pe_version      => $pe_version,
      '_catch_errors' => true,
    )

    # If there was an LDAP failure, note it and continue.
    if $ldap_result[0].error {
      out::message('There was a problem with the LDAP configuration, configuration must be completed manually.')
      out::message($ldap_result.to_data)
    }
  }

  # Run Puppet everywhere to pick up last remaining config tweaks
  run_task('peadm::puppet_runonce', peadm::flatten_compact([
        $primary_target,
        $primary_postgresql_target,
        $compiler_targets,
        $legacy_compiler_targets,
        $replica_target,
        $replica_postgresql_target,
  ]))

  # Deploy an environment if a deploy environment is specified
  if $deploy_environment {
    run_task('peadm::code_manager', $primary_target,
      action => "deploy ${deploy_environment}",
    )
  }

  # Configure Puppet agent service status now that configuration is complete
  $systemctl_state = $final_agent_state ? {
    'running' => 'start',
    'stopped' => 'stop'
  }
  run_command("systemctl ${systemctl_state} puppet", peadm::flatten_compact([
        $primary_target,
        $replica_target,
        $primary_postgresql_target,
        $replica_postgresql_target,
        $compiler_targets,
        $legacy_compiler_targets,
  ]))

  return("Configuration of Puppet Enterprise ${arch['architecture']} succeeded.")
}
