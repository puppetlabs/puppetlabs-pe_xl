# @api private
plan peadm::convert_compiler_to_legacy (
  Peadm::SingleTargetSpec $primary_host,
  TargetSpec              $legacy_hosts,
  Optional[Boolean]       $remove_pdb = true,
) {
  $primary_target            = peadm::get_targets($primary_host, 1)
  $convert_legacy_compiler_targets   = peadm::get_targets($legacy_hosts)

  $cluster = run_task('peadm::get_peadm_config', $primary_host).first.value
  $error = getvar('cluster.error')
  if $error {
    fail_plan($error)
  }

  apply($primary_target) {
    class { 'peadm::setup::node_manager_yaml':
      primary_host => $primary_target.peadm::certname() ? {
        undef   => $primary_target,
        default => $primary_target.peadm::certname(),
      },
    }

    class { 'peadm::setup::legacy_compiler_group':
      primary_host                     => $primary_target.peadm::certname() ? {
        undef   => $primary_target,
        default => $primary_target.peadm::certname(),
      },
      internal_compiler_a_pool_address => getvar('cluster.params.internal_compiler_a_pool_address'),
      internal_compiler_b_pool_address => getvar('cluster.params.internal_compiler_b_pool_address'),
      require                          => Class['peadm::setup::node_manager_yaml'],
    }
  }

  $replica_host = getvar('cluster.params.replica_host')
  $primary_postgresql_host = getvar('cluster.params.primary_postgresql_host')
  $replica_postgresql_host = getvar('cluster.params.replica_postgresql_host')
  $compiler_hosts = getvar('cluster.params.compiler_hosts')
  $legacy_compilers = getvar('cluster.params.legacy_hosts')

  $replica_target = peadm::get_targets($replica_host, 1)
  $primary_postgresql_target = peadm::get_targets($primary_postgresql_host, 1)
  $replica_postgresql_target = peadm::get_targets($replica_postgresql_host, 1)
  $compiler_targets = peadm::get_targets($compiler_hosts) - $convert_legacy_compiler_targets
  $legacy_targets = peadm::get_targets($legacy_compilers) + $convert_legacy_compiler_targets

  $all_targets = peadm::flatten_compact([
      $primary_target,
      $replica_target,
      $primary_postgresql_target,
      $replica_postgresql_target,
      $compiler_targets,
      $legacy_targets,
  ])

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
    $legacy_compilers,
  )

  if $arch['disaster-recovery'] {
    # Gather certificate extension information from all systems
    $cert_extensions = run_task('peadm::cert_data', $legacy_targets).reduce({}) |$memo,$result| {
      $memo + { $result.target.peadm::certname => $result['extensions'] }
    }
    $legacy_compiler_a_targets = $convert_legacy_compiler_targets.filter |$index,$target| {
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
    $legacy_compiler_b_targets = $convert_legacy_compiler_targets.filter |$index,$target| {
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
  } else {
    $legacy_compiler_a_targets = $convert_legacy_compiler_targets
    $legacy_compiler_b_targets = []
  }

  wait([
      background('modify-compilers-certs') || {
        run_plan('peadm::modify_certificate', $compiler_targets,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('pp_auth_role')    => 'legacy_compiler',
          },
        )
      },
      background('modify-compilers-a-certs') || {
        run_plan('peadm::modify_certificate', $legacy_compiler_a_targets,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('pp_auth_role')             => 'legacy_compiler',
            peadm::oid('peadm_availability_group') => 'A',
          },
        )
      },
      background('modify-compilers-b-certs') || {
        run_plan('peadm::modify_certificate', $legacy_compiler_b_targets,
          primary_host   => $primary_target,
          add_extensions => {
            peadm::oid('pp_auth_role')             => 'legacy_compiler',
            peadm::oid('peadm_availability_group') => 'B',
          },
        )
      },
  ])

  if $remove_pdb {
    run_command('puppet resource service puppet ensure=stopped', $convert_legacy_compiler_targets)
    run_command('puppet resource service pe-puppetdb ensure=stopped enable=false', $convert_legacy_compiler_targets)
  }

  run_task('peadm::puppet_runonce', $convert_legacy_compiler_targets)
  run_task('peadm::puppet_runonce', $compiler_targets)
  run_task('peadm::puppet_runonce', $primary_target)
  run_task('peadm::puppet_runonce', $all_targets)

  if $remove_pdb {
    run_command('puppet resource package pe-puppetdb ensure=purged', $convert_legacy_compiler_targets)
    run_command('puppet resource user pe-puppetdb ensure=absent', $convert_legacy_compiler_targets)

    run_command('rm -rf /etc/puppetlabs/puppetdb', $convert_legacy_compiler_targets)
    run_command('rm -rf /var/log/puppetlabs/puppetdb', $convert_legacy_compiler_targets)
    run_command('rm -rf /opt/puppetlabs/server/data/puppetdb', $convert_legacy_compiler_targets)
  }

  run_command('systemctl start pe-puppetserver.service', $convert_legacy_compiler_targets)
  run_command('puppet resource service puppet ensure=running', $convert_legacy_compiler_targets)

  return("Converted host ${convert_legacy_compiler_targets} to legacy compiler.")
}
