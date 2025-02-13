# @api private
#
# @summary Perform initial installation of Puppet Enterprise Extra Large
#
# @param r10k_remote
#   The clone URL of the controlrepo to use. This just uses the basic config
#   from the documentaion https://puppet.com/docs/pe/2019.0/code_mgr_config.html
#
# @param r10k_private_key_file
#   The private key to use for r10k. If this is a local file it will be copied
#   over to the primary at /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa
#   If the file does not exist the value will simply be supplied to the primary
#
# @param r10k_known_hosts
#   Puppet Enterprise 2023.3+ requires host key verification for the
#   r10k_remote host when using ssh. When setting \$r10k_private_key, you must
#   also provide \$r10k_known_hosts information in the form of an array of
#   hashes with 'name', 'type' and 'key' information for hostname, key-type and
#   public key. Please refer to the Puppet Enterprise 2023.3+ Configure Code
#   Manager documentation for further details.
#
# @param license_key_file
#   The license key to use with Puppet Enterprise.  If this is a local file it
#   will be copied over to the MoM at /etc/puppetlabs/license.key
#   If the file does not exist the value will simply be supplied to the primaries
#
# @param pe_conf_data
#   Config data to plane into pe.conf when generated on all hosts, this can be
#   used for tuning data etc.
#
# @param pe_installer_source
#   The URL to download the Puppet Enterprise installer media from. If not
#   specified, PEAdm will attempt to download PE installation media from its
#   standard public source. When specified, PEAdm will download directly from the
#   URL given.
#
plan peadm::subplans::install (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host             = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts           = undef,
  Optional[TargetSpec]              $legacy_compilers         = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host  = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host  = undef,

  # Common Configuration
  String               $console_password,
  Peadm::Pe_version    $version,
  Optional[Stdlib::HTTPSUrl] $pe_installer_source = undef,
  Array[String]        $dns_alt_names       = [],
  Hash                 $pe_conf_data        = {},

  # Code Manager
  Optional[Boolean]    $code_manager_auto_configure = undef,
  Optional[String]     $r10k_remote              = undef,
  Optional[String]     $r10k_private_key_file    = undef,
  Optional[Peadm::Pem] $r10k_private_key_content = undef,
  Optional[Peadm::Known_hosts] $r10k_known_hosts = undef,

  # License key
  Optional[String]     $license_key_file    = undef,
  Optional[String]     $license_key_content = undef,

  # Other
  String                $stagingdir             = '/tmp',
  String                $uploaddir              = '/tmp',
  Peadm::Download_mode  $download_mode          = 'bolthost',
  Boolean               $permit_unsafe_versions = false,
  String                $token_lifetime         = '1y',
) {
  peadm::assert_supported_pe_version($version, $permit_unsafe_versions)

  # Convert inputs into targets.
  $primary_target            = peadm::get_targets($primary_host, 1)
  $replica_target            = peadm::get_targets($replica_host, 1)
  $primary_postgresql_target = peadm::get_targets($primary_postgresql_host, 1)
  $replica_postgresql_target = peadm::get_targets($replica_postgresql_host, 1)
  $compiler_targets          = peadm::get_targets($compiler_hosts)
  $legacy_compiler_targets            = peadm::get_targets($legacy_compilers)

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
    $legacy_compilers,
  )

  $all_targets = peadm::flatten_compact([
      $primary_target,
      $primary_postgresql_target,
      $replica_target,
      $replica_postgresql_target,
      $compiler_targets,
      $legacy_compiler_targets,
  ])

  $primary_targets = peadm::flatten_compact([
      $primary_target,
      $replica_target,
  ])

  $database_targets = peadm::flatten_compact([
      $primary_postgresql_target,
      $replica_postgresql_target,
  ])

  $pe_installer_targets = peadm::flatten_compact([
      $primary_target,
      $primary_postgresql_target,
      $replica_postgresql_target,
  ])

  $agent_installer_targets = peadm::flatten_compact([
      $compiler_targets,
      $legacy_compiler_targets,
      $replica_target,
  ])

  # Clusters A and B are used to divide PuppetDB availability for compilers
  if $arch['disaster-recovery'] {
    $compiler_a_targets = $compiler_targets.filter |$index,$target| { $index % 2 == 0 }
    $compiler_b_targets = $compiler_targets.filter |$index,$target| { $index % 2 != 0 }
    $legacy_a_targets   = $legacy_compiler_targets.filter |$index,$target| { $index % 2 == 0 }
    $legacy_b_targets   = $legacy_compiler_targets.filter |$index,$target| { $index % 2 != 0 }
  }
  else {
    $compiler_a_targets = $compiler_targets
    $compiler_b_targets = []
    $legacy_a_targets   = $legacy_compiler_targets
    $legacy_b_targets   = []
  }

  $dns_alt_names_csv = $dns_alt_names.reduce |$csv,$x| { "${csv},${x}" }

  # Process user input for r10k private key (file or content) and set
  # appropriate value in $r10k_private_key. The value of this variable should
  # either be undef or else the key content to write.
  $r10k_private_key = peadm::file_or_content('r10k_private_key', $r10k_private_key_file, $r10k_private_key_content)

  # enable code manager if:
  # * it isn't explicitly disabled *and* the user provided r10k repo (key is optional, repo could be a local absolute path or https URL)
  # * a replica is present
  # * one or multiple compiler are present
  $_code_manager_auto_configure = if $r10k_remote and $code_manager_auto_configure {
    true
  } elsif $replica_host {
    true
  } elsif $compiler_hosts or $legacy_compilers {
    true
  } else {
    $code_manager_auto_configure
  }

  # Process user input for license key (same process as for r10k private key above).
  $license_key = peadm::file_or_content('license_key', $license_key_file, $license_key_content)

  $precheck_results = run_task('peadm::precheck', $all_targets)
  $platform = $precheck_results.first['platform'] # Assume the platform of the first result correct

  # Validate that the name given for each system is both a resolvable name AND
  # the configured hostname, and that all systems return the same platform
  $precheck_results.each |$result| {
    $name = $result.target.peadm::certname()
    if ($name != $result['hostname']) {
# lint:ignore:strict_indent
      warning(@("HEREDOC"))
        WARNING: Target name / hostname mismatch: target ${name} reports ${result['hostname']}
        Certificate name will be set to target name. Please ensure target name is correct and resolvable
        |-HEREDOC
# lint:endignore
    }
    if ($result['platform'] != $platform) {
      fail_plan("Platform mismatch: target ${name} reports '${result['platform']}; expected ${platform}'")
    }
  }

  # Generate all the needed pe.conf files

  # This is necessary starting in PE 2019.7, when we need to pre-configure
  # PostgreSQL to permit connections from compilers. After the compilers run
  # puppet and are present in PuppetDB, it is not necessary anymore.
  $puppetdb_database_temp_config = {
    'puppet_enterprise::profile::database::puppetdb_hosts' => (
      $compiler_targets + $legacy_compiler_targets + $primary_target + $replica_target
    ).map |$t| { $t.peadm::certname() },
  }

  $primary_pe_conf = peadm::generate_pe_conf({
      'console_admin_password'                                          => $console_password,
      'puppet_enterprise::puppet_master_host'                           => $primary_target.peadm::certname(),
      'pe_install::puppet_master_dnsaltnames'                           => $dns_alt_names,
      'puppet_enterprise::puppetdb_database_host'                       => $primary_postgresql_target.peadm::certname(),
      'puppet_enterprise::profile::master::code_manager_auto_configure' => $_code_manager_auto_configure,
      'puppet_enterprise::profile::master::r10k_remote'                 => $r10k_remote,
      'puppet_enterprise::profile::master::r10k_private_key'            => $r10k_private_key ? {
        undef   => undef,
        default => '/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa',
      },
      'puppet_enterprise::profile::master::r10k_known_hosts'            => $r10k_known_hosts,
  }.delete_undef_values + $puppetdb_database_temp_config + $pe_conf_data)

  $primary_postgresql_pe_conf = peadm::generate_pe_conf({
      'console_admin_password'                => 'not used',
      'puppet_enterprise::puppet_master_host' => $primary_target.peadm::certname(),
      'puppet_enterprise::database_host'      => $primary_postgresql_target.peadm::certname(),
  } + $puppetdb_database_temp_config + $pe_conf_data)

  $replica_postgresql_pe_conf = peadm::generate_pe_conf({
      'console_admin_password'                => 'not used',
      'puppet_enterprise::puppet_master_host' => $primary_target.peadm::certname(),
      'puppet_enterprise::database_host'      => $replica_postgresql_target.peadm::certname(),
  } + $puppetdb_database_temp_config + $pe_conf_data)

  # Upload the pe.conf files to the hosts that need them, and ensure correctly
  # configured certnames. Right now for these hosts we need to do that by
  # staging a puppet.conf file.
  parallelize(['primary', 'primary_postgresql', 'replica_postgresql']) |$var| {
    $target  = getvar("${var}_target", [])
    $pe_conf = getvar("${var}_pe_conf")

    peadm::file_content_upload($pe_conf, '/tmp/pe.conf', $target)
# lint:ignore:strict_indent
    run_task('peadm::mkdir_p_file', $target,
      path    => '/etc/puppetlabs/puppet/puppet.conf',
      content => @("HEREDOC"),
        [main]
        certname = ${target.peadm::certname()}
        | HEREDOC
# lint:endignore
    )
  }

  if $pe_installer_source {
    $pe_tarball_name = $pe_installer_source.split('/')[-1]
    $pe_tarball_source = $pe_installer_source
  } else {
    $pe_tarball_name   = "puppet-enterprise-${version}-${platform}.tar.gz"
    $pe_tarball_source = "https://s3.amazonaws.com/pe-builds/released/${version}/${pe_tarball_name}"
  }

  $upload_tarball_path = "${uploaddir}/${pe_tarball_name}"

  if $download_mode == 'bolthost' {
    # Download the PE tarball and send it to the nodes that need it
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

  # Create csr_attributes.yaml files for the nodes that need them. Ensure that
  # if a csr_attributes.yaml file is already present, the values we need are
  # merged with the existing values.
  $csr_yaml_jobs = [
    background('primary-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $primary_target,
        extension_requests => {
          peadm::oid('peadm_role')               => 'puppet/server',
          peadm::oid('peadm_availability_group') => 'A',
        }
      )
    },
    background('replica-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $replica_target,
        extension_requests => {
          peadm::oid('peadm_role')               => 'puppet/server',
          peadm::oid('peadm_availability_group') => 'B',
        }
      )
    },
    background('compiler-a-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $compiler_a_targets,
        extension_requests => {
          peadm::oid('pp_auth_role')             => 'pe_compiler',
          peadm::oid('peadm_availability_group') => 'A',
        }
      )
    },
    background('compiler-b-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $compiler_b_targets,
        extension_requests => {
          peadm::oid('pp_auth_role')             => 'pe_compiler',
          peadm::oid('peadm_availability_group') => 'B',
        }
      )
    },
    background('compiler-a-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $legacy_a_targets,
        extension_requests => {
          peadm::oid('pp_auth_role')             => 'pe_compiler_legacy',
          peadm::oid('peadm_availability_group') => 'A',
        }
      )
    },
    background('compiler-b-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $legacy_b_targets,
        extension_requests => {
          peadm::oid('pp_auth_role')             => 'pe_compiler_legacy',
          peadm::oid('peadm_availability_group') => 'B',
        }
      )
    },
    background('primary-postgresql-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $primary_postgresql_target,
        extension_requests => {
          peadm::oid('peadm_role')               => 'puppet/puppetdb-database',
          peadm::oid('peadm_availability_group') => 'A',
        }
      )
    },
    background('replica-postgresql-csr.yaml') || {
      run_plan('peadm::util::insert_csr_extension_requests', $replica_postgresql_target,
        extension_requests => {
          peadm::oid('peadm_role')               => 'puppet/puppetdb-database',
          peadm::oid('peadm_availability_group') => 'B',
        }
      )
    },
  ]

  wait($csr_yaml_jobs)

  # Get the master installation up and running. The installer will "fail"
  # because PuppetDB can't start, if primary_postgresql_target is set. That's
  # expected, and handled by the task's install_extra_large parameter.
  run_task('peadm::pe_install', $primary_target,
    tarball               => $upload_tarball_path,
    peconf                => '/tmp/pe.conf',
    puppet_service_ensure => 'stopped',
    install_extra_large   => ($arch['architecture'] == 'extra-large'),
  )

  parallelize($primary_targets) |$target| {
    if $r10k_private_key {
      run_task('peadm::mkdir_p_file', $target,
        path    => '/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa',
        mode    => '0600',
        content => $r10k_private_key,
      )
    }

    if $license_key {
      run_task('peadm::mkdir_p_file', $target,
        path    => '/etc/puppetlabs/license.key',
        mode    => '0644',
        content => $license_key,
      )
    }
  }

  # Configure autosigning for the puppetdb database hosts 'cause they need it
  $autosign_conf = $database_targets.reduce('') |$memo,$target| { "${target.peadm::certname}\n${memo}" }
  run_task('peadm::mkdir_p_file', $primary_target,
    path    => '/etc/puppetlabs/puppet/autosign.conf',
    owner   => 'pe-puppet',
    group   => 'pe-puppet',
    mode    => '0644',
    content => $autosign_conf,
  )

  # Run the PE installer on the puppetdb database hosts
  run_task('peadm::pe_install', $database_targets,
    tarball               => $upload_tarball_path,
    peconf                => '/tmp/pe.conf',
    puppet_service_ensure => 'stopped',
  )

  # Now that the main PuppetDB database node is ready, finish priming the
  # master. Explicitly stop puppetdb first to avoid any systemd interference.
  run_command('systemctl stop pe-puppetdb', $primary_target)
  run_command('systemctl start pe-puppetdb', $primary_target)
  run_task('peadm::rbac_token', $primary_target,
    password       => $console_password,
    token_lifetime => $token_lifetime,
  )

  # Stub a production environment and commit it to file-sync. At least one
  # commit (content irrelevant) is necessary to be able to configure
  # replication. A production environment must exist when committed to avoid
  # corrupting the PE console. Create the site.pp file specifically to avoid
  # breaking the `puppet infra configure` command.
  run_task('peadm::mkdir_p_file', $primary_target,
    path    => '/etc/puppetlabs/code-staging/environments/production/manifests/site.pp',
    chown_r => '/etc/puppetlabs/code-staging/environments',
    owner   => 'pe-puppet',
    group   => 'pe-puppet',
    mode    => '0644',
    content => "# Empty manifest\n",
  )

  run_task('peadm::code_manager', $primary_target,
    action => 'file-sync commit',
  )

  $bg_db_run = background('database-targets') || {
    run_task('peadm::puppet_runonce', $database_targets)
  }

  parallelize($agent_installer_targets) |$target| {
    $common_install_flags = [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      "main:certname=${target.peadm::certname()}",
    ]

    # Get an agent installed and cert signed
    run_task('peadm::agent_install', $target,
      server        => $primary_target.peadm::certname(),
      install_flags => $common_install_flags,
    )

    # Ensure certificate requests have been submitted, then run Puppet
    run_task('peadm::submit_csr', $target)
    run_task('peadm::sign_csr', $primary_target, { 'certnames' => [$target.peadm::certname] })
    run_task('peadm::puppet_runonce', $target)
  }

  wait([$bg_db_run])

  # The puppetserver might be in the middle of a restart after the Puppet run,
  # so we check the status by calling the api and ensuring the puppetserver is
  # taking requests before proceeding. It takes two runs to fully finish
  # configuration.
  run_task('peadm::puppet_runonce', $primary_target)
  peadm::wait_until_service_ready('pe-master', $primary_target)
  run_task('peadm::puppet_runonce', $primary_target)

  # Cleanup temp bootstrapping config
  parallelize(['primary', 'primary_postgresql', 'replica_postgresql']) |$var| {
    $target  = getvar("${var}_target", [])
    $pe_conf = getvar("${var}_pe_conf", '{}')

    run_task('peadm::mkdir_p_file', $target,
      path    => '/etc/puppetlabs/enterprise/conf.d/pe.conf',
      content => stdlib::to_json_pretty($pe_conf.parsejson() - $puppetdb_database_temp_config),
    )
  }

  return("Installation of Puppet Enterprise ${arch['architecture']} succeeded.")
}
