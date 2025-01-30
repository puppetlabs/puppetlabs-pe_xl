# @summary Upgrade a PEAdm-managed cluster
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
# @param pe_installer_source
#   The URL to download the Puppet Enterprise installer media from. If not
#   specified, PEAdm will attempt to download PE installation media from its
#   standard public source. When specified, PEAdm will download directly from the
#   URL given.
# @param final_agent_state
#   Configures the state the puppet agent should be in on infrastructure nodes
#   after PE is upgraded successfully.
# @param r10k_known_hosts
#   Puppet Enterprise 2023.3+ requires host key verification for the
#   r10k_remote host when using ssh. you must provide \$r10k_known_hosts
#   information in the form of an array of hashes with 'name', 'type' and 'key'
#   information for hostname, key-type and public key.
# @param stagingdir
#   Directory on the Bolt host where the installer tarball will be cached if
#   download_mode is 'bolthost' (default)
# @param uploaddir
#   Directory the installer tarball will be uploaded to or expected to be in
#   for offline usage.
# @param begin_at_step The step where the plan should start. If not set, it will start at the beginning
#
plan peadm::upgrade (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts      = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host = undef,

  # Common Configuration
  Optional[Peadm::Pe_version]  $version                          = undef,
  Optional[Stdlib::HTTPSUrl]   $pe_installer_source              = undef,
  Optional[String]             $compiler_pool_address            = undef,
  Optional[String]             $internal_compiler_a_pool_address = undef,
  Optional[String]             $internal_compiler_b_pool_address = undef,
  Optional[Peadm::Known_hosts] $r10k_known_hosts                 = undef,

  # Other
  Optional[String]           $token_file             = undef,
  String                     $stagingdir             = '/tmp',
  String                     $uploaddir              = '/tmp',
  Enum['running', 'stopped'] $final_agent_state      = 'running',
  Peadm::Download_mode       $download_mode          = 'bolthost',
  Boolean                    $permit_unsafe_versions = false,

  Optional[Peadm::UpgradeSteps] $begin_at_step = undef,
) {
  out::message('# Validating inputs')

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
  )

  # Convert inputs into targets.
  $primary_target            = peadm::get_targets($primary_host, 1)
  $replica_target            = peadm::get_targets($replica_host, 1)
  $primary_postgresql_target = peadm::get_targets($primary_postgresql_host, 1)
  $replica_postgresql_target = peadm::get_targets($replica_postgresql_host, 1)
  $compiler_targets          = peadm::get_targets($compiler_hosts)

  $all_targets = peadm::flatten_compact([
      $primary_target,
      $primary_postgresql_target,
      $replica_target,
      $replica_postgresql_target,
      $compiler_targets,
  ])

  $pe_installer_targets = peadm::flatten_compact([
      $primary_target,
      $primary_postgresql_target,
      $replica_postgresql_target,
  ])

  # Validate the RBAC token used to upgrade compilers if compilers are present
  if $compiler_targets and $compiler_targets.size > 0 {
    run_task('peadm::validate_rbac_token', $primary_target, token_file => $token_file)
  }

  out::message('# Gathering information')

  # lint:ignore:strict_indent
  $primary_target.peadm::fail_on_transport('pcp', @(HEREDOC/n))
    \nThe "pcp" transport is not available for use with the Primary
    as peadm::upgrade will cause a restart of the
    PE Orchestration service.

    Use the "local" transport if running this plan directly from
    the Primary node, or the "ssh" transport if running this
    plan from an external Bolt host.

    For information on configuring transports, see:

        https://www.puppet.com/docs/bolt/latest/bolt_transports_reference.html
    |-HEREDOC
    # lint:endignore

  $platform = run_task('peadm::precheck', $primary_target).first['platform']

  if $pe_installer_source {
    $pe_tarball_name   = $pe_installer_source.split('/')[-1]
    $pe_tarball_source = $pe_installer_source
    $_version          = $pe_tarball_name.split('-')[2]
  } else {
    $_version          = $version
    $pe_tarball_name   = "puppet-enterprise-${_version}-${platform}.tar.gz"
    $pe_tarball_source = "https://s3.amazonaws.com/pe-builds/released/${_version}/${pe_tarball_name}"
  }

  $upload_tarball_path = "${uploaddir}/${pe_tarball_name}"

  peadm::assert_supported_bolt_version()

  peadm::assert_supported_pe_version($_version, $permit_unsafe_versions)

  # Gather certificate extension information from all systems
  $cert_extensions = run_task('peadm::cert_data', $all_targets).reduce({}) |$memo,$result| {
    $memo + { $result.target.peadm::certname => $result['extensions'] }
  }

  $convert_targets = $cert_extensions.filter |$name,$exts| {
    ($name in $compiler_targets.map |$t| { $t.name }) and ($exts['pp_auth_role'] == undef)
  }.keys

  # Determine PE version currently installed on primary
  $current_pe_version = run_task('peadm::read_file', $primary_target,
    path => '/opt/puppetlabs/server/pe_build',
  ).first['content']

  # Ensure needed trusted facts are available
  if $cert_extensions.any |$_,$cert| {
    [peadm::oid('peadm_role'), 'pp_auth_role'].all |$ext| { $cert[$ext] == undef } or
    $cert[peadm::oid('peadm_availability_group')] == undef
  } {
# lint:ignore:strict_indent
    fail_plan(@(HEREDOC/L))
      Required trusted facts are not present; upgrade cannot be completed. If \
      this infrastructure was provisioned with an old version of peadm, you may \
      need to run the peadm::convert plan\
      | HEREDOC
# lint:endignore
  }

  # Determine which compilers are associated with which DR group
  $compiler_m1_targets = $compiler_targets.filter |$target| {
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('peadm_availability_group'))
    == $cert_extensions.dig($primary_target[0].peadm::certname, peadm::oid('peadm_availability_group')))
  }

  $compiler_m1_nonlegacy_targets = $compiler_targets.filter |$target| {
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('peadm_availability_group'))
    == $cert_extensions.dig($primary_target[0].peadm::certname, peadm::oid('peadm_availability_group'))) and
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('pp_auth_role'))
    == 'pe_compiler')
  }

  $compiler_m2_targets = $compiler_targets.filter |$target| {
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('peadm_availability_group'))
    == $cert_extensions.dig($replica_target[0].peadm::certname, peadm::oid('peadm_availability_group')))
  }

  $compiler_m2_nonlegacy_targets = $compiler_targets.filter |$target| {
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('peadm_availability_group'))
    == $cert_extensions.dig($replica_target[0].peadm::certname, peadm::oid('peadm_availability_group'))) and
    ($cert_extensions.dig($target.peadm::certname, peadm::oid('pp_auth_role'))
    == 'pe_compiler')
  }

  peadm::plan_step('preparation') || {
    if $download_mode == 'bolthost' {
      # Download the PE tarball on the nodes that need it
      run_plan('peadm::util::retrieve_and_upload', $pe_installer_targets,
        source      => $pe_tarball_source,
        local_path  => "${stagingdir}/${pe_tarball_name}",
        upload_path => $upload_tarball_path,
      )
    } else {
      # Download PE tarballs directly to nodes that need it
      run_task('peadm::download', $pe_installer_targets,
        source => $pe_tarball_source,
        path   => $upload_tarball_path,
      )
    }

    # Shut down Puppet on all infra targets. Avoid using the built-in service
    # task for idempotency reasons. When the orchestrator has been upgraded but
    # not all pxp-agents have, the built-in service task does not work over pcp.
    run_command('systemctl stop puppet', $all_targets)

    # Create a variable for configuring PuppetDB access for all the certnames
    # that are known to need it.
    $profile_database_puppetdb_hosts = {
      'puppet_enterprise::profile::database::puppetdb_hosts' => (
        $compiler_targets + $primary_target + $replica_target
      ).map |$t| { $t.peadm::certname() },
    }

    # Ensure the pe.conf files on the PostgreSQL node(s) are correct. This file
    # is only ever consulted during install and upgrade of these nodes, but if
    # it contains the wrong values, upgrade will fail.
    peadm::flatten_compact([
        $primary_postgresql_target,
        $replica_postgresql_target,
    ]).each |$target| {
      $current_pe_conf = run_task('peadm::read_file', $target,
        path => '/etc/puppetlabs/enterprise/conf.d/pe.conf',
      ).first['content']

      $pe_conf = stdlib::to_json_pretty($current_pe_conf ? {
          undef   => {},
          default => stdlib::parsehocon($current_pe_conf),
        } + {
          'console_admin_password'                => 'not used',
          'puppet_enterprise::puppet_master_host' => $primary_target.peadm::certname(),
          'puppet_enterprise::database_host'      => $target.peadm::certname(),
      } + $profile_database_puppetdb_hosts)

      write_file($pe_conf, '/etc/puppetlabs/enterprise/conf.d/pe.conf', $target)
    }

    if $r10k_known_hosts != undef {
      $current_pe_conf = peadm::get_pe_conf($primary_target[0])

      # Append the r10k_known_hosts entry
      $updated_pe_conf = $current_pe_conf + {
        'puppet_enterprise::profile::master::r10k_known_hosts' => $r10k_known_hosts,
      }

      peadm::update_pe_conf($primary_target[0], $updated_pe_conf)
    }
  }

  peadm::plan_step('upgrade-primary') || {
    # Shut down PuppetDB on CMs that use the PM's PDB PG. Use run_command instead
    # of run_task(service, ...) so that upgrading from 2018.1 works over PCP.
    run_command('systemctl stop pe-puppetdb', $compiler_m1_nonlegacy_targets)

    run_task('peadm::pe_install', $primary_postgresql_target,
      tarball               => $upload_tarball_path,
      puppet_service_ensure => 'stopped',
    )

    run_task('peadm::pe_install', $primary_target,
      tarball               => $upload_tarball_path,
      puppet_service_ensure => 'stopped',
    )

    # If in use, wait until orchestrator service is healthy to proceed
    if $all_targets.any |$target| { $target.protocol == 'pcp' } {
      peadm::wait_until_service_ready('orchestrator-service', $primary_target)
      wait_until_available($all_targets, wait_time => 120)
    }

    # Installer-driven upgrade will de-configure auth access for compilers.
    # Re-run Puppet immediately to fully re-enable
    run_task('peadm::puppet_runonce', peadm::flatten_compact([
          $primary_target,
          $primary_postgresql_target,
    ]))

    # Running again to ensure that the primary is fully upgraded
    run_task('peadm::puppet_runonce', $primary_target)
  }

  peadm::plan_step('upgrade-node-groups') || {
    # The primary could restart orchestration services again, in which case we
    # would have to wait for nodes to reconnect
    if $all_targets.any |$target| { $target.protocol == 'pcp' } {
      peadm::wait_until_service_ready('orchestrator-service', $primary_target)
      wait_until_available($all_targets, wait_time => 120)
    }

    # If necessary, add missing cert extensions to compilers
    run_plan('peadm::modify_certificate', $convert_targets,
      primary_host   => $primary_target,
      add_extensions => {
        'pp_auth_role' => 'pe_compiler',
      },
    )

    # Log the peadm configuration before node manager setup
    run_task('peadm::get_peadm_config', $primary_target)

    # Update classification. This needs to be done now because if we don't, and
    # the PE Compiler node groups are wrong, then the compilers won't be able to
    # successfully classify and update

    # First, determine the correct hosts for the A and B availability groups
    $server_a_host = $cert_extensions.dig($primary_target.peadm::certname(), peadm::oid('peadm_availability_group')) ? {
      'A'     => $primary_target.peadm::certname(),
      default => $replica_target.peadm::certname(),
    }

    $server_b_host = $server_a_host ? {
      $primary_target.peadm::certname() => $replica_target.peadm::certname(),
      default                           => $primary_target.peadm::certname(),
    }

    $postgresql_a_host = $cert_extensions.dig($primary_postgresql_target.peadm::certname(), peadm::oid('peadm_availability_group')) ? {
      'A'     => $primary_postgresql_target.peadm::certname(),
      default => $replica_postgresql_target.peadm::certname(),
    }

    $postgresql_b_host = $postgresql_a_host ? {
      $primary_postgresql_target.peadm::certname() => $replica_postgresql_target.peadm::certname(),
      default                                      => $primary_postgresql_target.peadm::certname(),
    }

    $rules = run_task('peadm::get_group_rules', $primary_target).first.value['_output']
    $rules_formatted = stdlib::to_json_pretty(parsejson($rules))
    out::message("WARNING: The following existing rules on the PE Infrastructure Agent group will be overwritten with default values:\n ${rules_formatted}")

    apply($primary_target) {
      class { 'peadm::setup::node_manager_yaml':
        primary_host => $primary_target.peadm::certname(),
      }

      class { 'peadm::setup::node_manager':
        primary_host                     => $primary_target.peadm::certname(),
        server_a_host                    => $server_a_host,
        server_b_host                    => $server_b_host,
        postgresql_a_host                => $postgresql_a_host,
        postgresql_b_host                => $postgresql_b_host,
        compiler_pool_address            => $compiler_pool_address,
        internal_compiler_a_pool_address => $internal_compiler_a_pool_address,
        internal_compiler_b_pool_address => $internal_compiler_b_pool_address,
        require                          => Class['peadm::setup::node_manager_yaml'],
      }
    }
  }

  peadm::plan_step('upgrade-primary-compilers') || {
    # Upgrade the compiler group A targets
    run_task('peadm::puppet_infra_upgrade', $primary_target,
      type       => 'compiler',
      targets    => $compiler_m1_targets.map |$t| { $t.peadm::certname() },
      token_file => $token_file,
    )
  }

  peadm::plan_step('upgrade-replica') || {
    # Shut down PuppetDB on CMs that use the replica's PDB PG. Use run_command
    # instead of run_task(service, ...) so that upgrading from 2018.1 works
    # over PCP.
    run_command('systemctl stop pe-puppetdb', $compiler_m2_nonlegacy_targets)

    run_task('peadm::pe_install', $replica_postgresql_target,
      tarball               => $upload_tarball_path,
      puppet_service_ensure => 'stopped',
    )

    # Installer-driven upgrade will de-configure auth access for compilers.
    # Re-run Puppet immediately to fully re-enable.
    #
    # Because the steps following involve performing orchestrated actions and
    # `puppet infra upgrade` cannot handle orchestration services restarting,
    # also run Puppet immediately on the primary.
    run_task('peadm::puppet_runonce', peadm::flatten_compact([
          $primary_target,
          $replica_postgresql_target,
    ]))

    # The `puppetdb delete-reports` CLI app has a bug in 2019.8.0 where it
    # doesn't deal well with the PuppetDB database being on a separate node.
    # So, move it aside before running the upgrade.
    $pdbapps = '/opt/puppetlabs/server/apps/puppetdb/cli/apps'
    $workaround_delete_reports = $arch['disaster-recovery'] and $_version =~ SemVerRange('>= 2019.8')
    if $workaround_delete_reports {
# lint:ignore:strict_indent
      run_command(@("COMMAND"/$), $replica_target)
        if [ -e ${pdbapps}/delete-reports -a ! -h ${pdbapps}/delete-reports ]
        then
          mv ${pdbapps}/delete-reports ${pdbapps}/delete-reports.original
          ln -s \$(which true) ${pdbapps}/delete-reports
        fi
        | COMMAND
    }

    # Upgrade the primary replica.
    run_task('peadm::puppet_infra_upgrade', $primary_target,
      type       => 'replica',
      targets    => $replica_target.map |$t| { $t.peadm::certname() },
      token_file => $token_file,
    )

    # Return the delete-reports CLI app to its original state
    if $workaround_delete_reports {
      run_command(@("COMMAND"/$), $replica_target)
        if [ -e ${pdbapps}/delete-reports.original ]
        then
          mv ${pdbapps}/delete-reports.original ${pdbapps}/delete-reports
        fi
        | COMMAND
# lint:endignore
    }
  }

  peadm::plan_step('upgrade-replica-compilers') || {
    # Upgrade the compiler group B targets
    run_task('peadm::puppet_infra_upgrade', $primary_target,
      type       => 'compiler',
      targets    => $compiler_m2_targets.map |$t| { $t.peadm::certname() },
      token_file => $token_file,
    )
  }

  peadm::plan_step('finalize') || {
    $service_state = $final_agent_state ? {
      'running' => 'start',
      'stopped' => 'stop'
    }
    # Configure Puppet agent service status on all infrastructure targets
    run_task('service', $all_targets,
      action => $service_state,
      name   => 'puppet',
    )
  }

  peadm::check_version_and_known_hosts($current_pe_version, $_version, $r10k_known_hosts)

  return("Upgrade of Puppet Enterprise ${arch['architecture']} completed.")
}
