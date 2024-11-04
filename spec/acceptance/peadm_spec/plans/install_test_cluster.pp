plan peadm_spec::install_test_cluster (
  String[1]                 $architecture,
  String                    $download_mode          = 'direct',
  Optional[Boolean]         $code_manager_auto_configure = undef,
  Optional[String[1]]       $version                = undef,
  Optional[String[1]]       $pe_installer_source    = undef,
  Boolean                   $permit_unsafe_versions = false,
  Enum['enable', 'disable'] $fips                   = 'disable',
  String                    $console_password
) {
  $t = get_targets('*')
  wait_until_available($t)

  parallelize($t) |$target| {
    $fqdn = run_command('hostname -f', $target)
    $target.set_var('certname', $fqdn.first['stdout'].chomp)
  }

  if $fips == 'enable' {
    run_command('/bin/fips-mode-setup --enable', $t)
    run_plan('reboot', $t)
    $fips_status = run_command('/bin/fips-mode-setup --check', $t)
    $fips_status.each |$status| {
      out::message("${status.target.name}: ${status.value['stdout']}")
    }
  }

  # CI jobs triggered from forks don't have access to secrets, so use randomized input instead
  if $console_password == '' {
    $cp = run_command(
      'LC_ALL=C tr -dc \'A-Za-z0-9!"#$%&\'\\\'\'()*+,-./:;<=>?@[\]^_`{|}~\' </dev/urandom | head -c 30; echo', localhost
    ).first['stdout'].chomp
  } else {
    $cp = $console_password
  }

  $common_params = {
    console_password       => $cp,
    download_mode          => $download_mode,
    code_manager_auto_configure => $code_manager_auto_configure,
    version                => $version,
    permit_unsafe_versions => $permit_unsafe_versions,
  }

  $arch_params = case $architecture {
    'standard': {{
        primary_host => $t.filter |$n| { $n.vars['role'] == 'primary' },
    } }
    'standard-with-dr': {{
        primary_host   => $t.filter |$n| { $n.vars['role'] == 'primary' },
        replica_host   => $t.filter |$n| { $n.vars['role'] == 'replica' },
    } }
    'large': {{
        primary_host   => $t.filter |$n| { $n.vars['role'] == 'primary' },
        compiler_hosts => $t.filter |$n| { $n.vars['role'] == 'compiler' },
    } }
    'large-with-dr': {{
        primary_host   => $t.filter |$n| { $n.vars['role'] == 'primary' },
        replica_host   => $t.filter |$n| { $n.vars['role'] == 'replica' },
        compiler_hosts => $t.filter |$n| { $n.vars['role'] == 'compiler' },
    } }
    'extra-large': {{
        primary_host            => $t.filter |$n| { $n.vars['role'] == 'primary' },
        primary_postgresql_host => $t.filter |$n| { $n.vars['role'] == 'primary-pdb-postgresql' },
        compiler_hosts          => $t.filter |$n| { $n.vars['role'] == 'compiler' },
    } }
    'extra-large-with-dr': {{
        primary_host             => $t.filter |$n| { $n.vars['role'] == 'primary' },
        primary_postgresql_host  => $t.filter |$n| { $n.vars['role'] == 'primary-pdb-postgresql' },
        replica_host             => $t.filter |$n| { $n.vars['role'] == 'replica' },
        replica_postgresql_host  => $t.filter |$n| { $n.vars['role'] == 'replica-pdb-postgresql' },
        compiler_hosts           => $t.filter |$n| { $n.vars['role'] == 'compiler' },
    } }
    default: { fail('Invalid architecture!') }
  }

  if $pe_installer_source {
    $targets             = $arch_params.values.flatten
    $platform            = run_task('peadm::precheck', $arch_params['primary_host']).first['platform']
    $pe_tarball_name     = "puppet-enterprise-${version}-${platform}.tar.gz"
    $upload_tarball_path = "/tmp/${pe_tarball_name}"

    if $download_mode == 'bolthost' {
      run_plan('peadm::util::retrieve_and_upload', $targets,
        source      => $pe_installer_source,
        local_path  => "/tmp/${pe_tarball_name}",
        upload_path => $upload_tarball_path,
      )
    } else {
      run_task('peadm::download', $targets,
        source => $pe_installer_source,
        path   => $upload_tarball_path,
      )
    }
  }

  $install_result = run_plan('peadm::install', $arch_params + $common_params)

  return($install_result)
}
