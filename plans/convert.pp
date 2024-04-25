# @summary Convert an existing PE cluster to a PEAdm-managed cluster
#
# This plan sets required certificate extensions on PE nodes, and configures
# the required PE node groups to make an existing cluster compatible with
# management using PEAdm.
plan peadm::convert (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host         = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host = undef,

  # Common Configuration
  String                            $compiler_pool_address            = $primary_host,
  Optional[String]                  $internal_compiler_a_pool_address = undef,
  Optional[String]                  $internal_compiler_b_pool_address = undef,
  Array[String]                     $dns_alt_names                    = [],

  Optional[Enum[
      'modify-primary-certs',
      'modify-infra-certs',
      'convert-node-groups',
  'finalize']] $begin_at_step = undef,
) {
  peadm::assert_supported_bolt_version()

  # TODO: read and validate convertable PE version

  # Convert inputs into targets.
  $primary_target                   = peadm::get_targets($primary_host, 1)
  $replica_target                   = peadm::get_targets($replica_host, 1)
  $replica_postgresql_target        = peadm::get_targets($replica_postgresql_host, 1)
  $compiler_targets                 = peadm::get_targets($compiler_hosts)
  $primary_postgresql_target        = peadm::get_targets($primary_postgresql_host, 1)

  $all_targets = peadm::flatten_compact([
      $primary_target,
      $replica_target,
      $replica_postgresql_target,
      $compiler_targets,
      $primary_postgresql_target,
  ])

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
  )

  out::message('# Gathering information')
  peadm::check_availability($all_targets)

  # Get trusted fact information for all compilers. Use peadm::certname() as
  # the hash key because the apply block below will break trying to parse the
  # $compiler_extensions variable if it has Target-type hash keys.
  $cert_extensions = run_task('peadm::cert_data', $all_targets).reduce({}) |$memo,$result| {
    $memo + { $result.target.peadm::certname() => $result['extensions'] }
  }

  # Know what version of PE the current targets are
  $pe_version = run_task('peadm::read_file', $primary_target,
    path => '/opt/puppetlabs/server/pe_version',
  )[0][content].chomp

  # Figure out if this PE cluster has been configured with peadm or pe_xl
  # before
  $previously_configured_by_peadm = $all_targets.any |$target| {
    $exts = $cert_extensions[$target.peadm::certname()]
    $exts[peadm::oid('peadm_role')] or String($exts[peadm::oid('pp_role')]) =~ /pe_xl|peadm/
  }

  if (!$previously_configured_by_peadm and ($pe_version =~ SemVerRange('< 2019.7.0'))) {
# lint:ignore:strict_indent
    fail_plan(@("EOL"/L))
      PE cluster cannot be converted! PE cluster must be a deployment \
      created by pe_xl, by an older version of peadm, or be PE version \
      2019.7.0 or newer. Detected PE version ${pe_version}, and did not detect \
      signs that the deployment was previously created by peadm/pe_xl.
      | EOL
# lint:endignore
  }

  # Clusters A and B are used to divide PuppetDB availability for compilers. If
  # the compilers given already have peadm_availability_group facts designating
  # them A or B, use that. Otherwise, divide them by modulus of 2.
  if $arch['disaster-recovery'] {
    $compiler_a_targets = $compiler_targets.filter |$index,$target| {
      $exts = $cert_extensions[$target.peadm::certname()]
      if ($exts[peadm::oid('peadm_availability_group')] in ['A', 'B']) {
        $exts[peadm::oid('peadm_availability_group')] == 'A'
      }
      elsif ($exts[peadm::oid('pp_cluster')] in ['A', 'B']) {
        $exts[peadm::oid('pp_cluster')] == 'A'
      }
      else {
        $index % 2 == 0
      }
    }
    $compiler_b_targets = $compiler_targets.filter |$index,$target| {
      $exts = $cert_extensions[$target.peadm::certname()]
      if ($exts[peadm::oid('peadm_availability_group')] in ['A', 'B']) {
        $exts[peadm::oid('peadm_availability_group')] == 'B'
      }
      elsif ($exts[peadm::oid('pp_cluster')] in ['A', 'B']) {
        $exts[peadm::oid('pp_cluster')] == 'B'
      }
      else {
        $index % 2 != 0
      }
    }
  }
  else {
    $compiler_a_targets = $compiler_targets
    $compiler_b_targets = []
  }

  # Modify csr_attributes.yaml and insert the peadm-specific OIDs to identify
  # each server's role and availability group

  peadm::plan_step('modify-primary-cert') || {
    # If PE version is older than 2019.7
    if (versioncmp($pe_version, '2019.7.0') < 0) {
      apply($primary_target) {
        include peadm::setup::convert_pre20197
      }
    }

    run_plan('peadm::modify_certificate', $primary_target,
      primary_host   => $primary_target,
      add_extensions => {
        peadm::oid('peadm_role')               => 'puppet/server',
        peadm::oid('peadm_availability_group') => 'A',
      },
    )
  }

  peadm::plan_step('modify-infra-certs') || {
    # If the orchestrator is in use, get certs fully straightened up before
    # proceeding
    if $all_targets.any |$target| { $target.protocol == 'pcp' } {
      run_task('peadm::puppet_runonce', $primary_target)
      peadm::wait_until_service_ready('orchestrator-service', $primary_target)
      wait_until_available($all_targets, wait_time => 120)
    }

    # Kick off all the cert modification jobs in parallel
    $background_cert_jobs = [
      background('modify-replica-cert') || {
        run_plan('peadm::modify_certificate', $replica_target,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('peadm_role')               => 'puppet/server',
            peadm::oid('peadm_availability_group') => 'B',
          },
        )
      },
      background('modify-primary-postgresql-cert') || {
        run_plan('peadm::modify_certificate', $primary_postgresql_target,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('peadm_role')               => 'puppet/puppetdb-database',
            peadm::oid('peadm_availability_group') => 'A',
          },
        )
      },
      background('modify-replica-postgresql-cert') || {
        run_plan('peadm::modify_certificate', $replica_postgresql_target,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('peadm_role')               => 'puppet/puppetdb-database',
            peadm::oid('peadm_availability_group') => 'B',
          },
        )
      },
      background('modify-compilers-a-certs') || {
        run_plan('peadm::modify_certificate', $compiler_a_targets,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('pp_auth_role')             => 'pe_compiler',
            peadm::oid('peadm_availability_group') => 'A',
          },
        )
      },
      background('modify-compilers-b-certs') || {
        run_plan('peadm::modify_certificate', $compiler_b_targets,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('pp_auth_role')             => 'pe_compiler',
            peadm::oid('peadm_availability_group') => 'B',
          },
        )
      },
    ]

    # Wait for all the cert modification jobs to complete
    wait($background_cert_jobs)
  }

  peadm::plan_step('convert-node-groups') || {
    # Create the necessary node groups in the console, unless the PE version is
    # too old to support it pre-upgrade. In that circumstance, we trust that
    # the existing groups are correct enough to function until the upgrade is
    # performed.
    if (versioncmp($pe_version, '2019.7.0') >= 0) {
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

        include peadm::setup::convert_node_manager
      }
    }
    else {
# lint:ignore:strict_indent
      out::message(@("EOL"/L))
        NOTICE: Node groups not created/updated as part of convert because PE \
        version is too old to support them. Node groups will be updated when \
        the peadm::upgrade plan is run.
        | EOL
# lint:endignore
    }
  }

  peadm::plan_step('finalize') || {
    # Run Puppet on all targets to ensure catalogs and exported resources fully
    # up-to-date. Run on primary first in case puppet server restarts, 'cause
    # that would cause the runs to fail on all the rest.
    run_task('peadm::puppet_runonce', $primary_target)
    run_task('peadm::puppet_runonce', $all_targets - $primary_target)

    # Restart cluster compiler services that are likely not restarted by our
    # final Puppet run to increase chance everything is functional upon plan
    # completion
    run_command('systemctl restart pe-puppetserver.service pe-puppetdb.service',
    $all_targets - $primary_target - $primary_postgresql_target - $replica_postgresql_target)
  }

  return("Conversion to peadm Puppet Enterprise ${arch['architecture']} completed.")
}
