# @summary Backup puppet primary configuration
#
# @param targets This should be the primary puppetserver for the puppet cluster
# @param backup_type Currently, the recovery and custom backup types are supported
# @param backup A hash of custom backup options, see the peadm::recovery_opts_default() function for the default values
# @param output_directory The directory to place the backup in
# @example 
#   bolt plan run peadm::backup -t primary1.example.com
#
plan peadm::backup (
  # This plan should be run on the primary server
  Peadm::SingleTargetSpec     $targets,

  # backup type determines the backup options
  Enum['recovery', 'custom']  $backup_type = 'recovery',

  # Which data to backup
  Peadm::Recovery_opts        $backup = {},

  # Where to put the backup folder
  String                      $output_directory = '/tmp',
) {
  peadm::assert_supported_bolt_version()

  $cluster = run_task('peadm::get_peadm_config', $targets).first.value
  $error = getvar('cluster.error')
  if $error {
    fail_plan($error)
  }
  $arch = peadm::assert_supported_architecture(
    getvar('cluster.params.primary_host'),
    getvar('cluster.params.replica_host'),
    getvar('cluster.params.primary_postgresql_host'),
    getvar('cluster.params.replica_postgresql_host'),
    getvar('cluster.params.compiler_hosts'),
  )

  $pe_version = peadm::validated_pe_version_for_backup_restore(getvar('cluster.pe_version'))

  $recovery_opts = $backup_type? {
    'recovery'  => peadm::recovery_opts_default($pe_version),
    'migration' => peadm::migration_opts_default($pe_version),
    'custom'    => peadm::recovery_opts_all($pe_version) + $backup,
  }

  $timestamp = Timestamp.new().strftime('%Y-%m-%dT%H%M%SZ')
  $backup_directory = "${output_directory}/pe-backup-${timestamp}"

  $primary_target = getvar('cluster.params.primary_host')
  $puppetdb_postgresql_target = getvar('cluster.params.primary_postgresql_host') ? {
    undef   => getvar('cluster.params.primary_host'),
    default => getvar('cluster.params.primary_postgresql_host'),
  }

  $backup_databases = {
    'orchestrator' => $primary_target,
    'activity'     => $primary_target,
    'rbac'         => $primary_target,
    'puppetdb'     => $puppetdb_postgresql_target,
    # (host-action-collector db will be filtered for pe version by recovery_opts)
    'hac'          => $primary_target,
    # (patching db will be filtered for pe version by recovery_opts)
    'patching'     => $primary_target,
  }.filter |$key,$_| {
    $recovery_opts[$key] == true
  }

  # Create backup folders
  apply($targets) {
    file { $backup_directory :
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0711',
    }

    # create a backup subdir for peadm configration
    file { "${backup_directory}/peadm":
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0711',
    }

    # backup the cluster config
    file { "${backup_directory}/peadm/peadm_config.json":
      content => stdlib::to_json_pretty($cluster),
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
    }

    # backup the recovery options
    file { "${backup_directory}/peadm/recovery_opts.json":
      content => stdlib::to_json_pretty($recovery_opts),
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
    }

    # Create a subdir for each backup type selected
    $recovery_opts.filter |$_,$val| { $val == true }.each |$dir,$_| {
      file { "${backup_directory}/${dir}":
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0711',
      }
    }

    if $backup_type == 'recovery' {
      # create a backup subdir for recovery configuration
      file { "${backup_directory}/recovery":
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0711',
      }
    }
  }

  if getvar('recovery_opts.classifier') {
    out::message('# Backing up classification')
    run_task('peadm::backup_classification', $targets,
      directory => "${backup_directory}/classifier",
    )
  }

  if $backup_type == 'recovery' {
    out::message('# Backing up ca, certs, code and config for recovery')
# lint:ignore:strict_indent
    run_command(@("CMD"), $targets)
      /opt/puppetlabs/bin/puppet-backup create --dir=${shellquote($backup_directory)}/recovery --scope=certs,code,config
      | CMD
# lint:endignore
  } else {
    if getvar('recovery_opts.ca') {
      out::message('# Backing up ca and ssl certificates')
  # lint:ignore:strict_indent
      run_command(@("CMD"), $targets)
        /opt/puppetlabs/bin/puppet-backup create --dir=${shellquote($backup_directory)}/ca --scope=certs
        | CMD
    }

    if getvar('recovery_opts.code') {
      out::message('# Backing up code')
      # run_command("chown pe-postgres ${shellquote($backup_directory)}/code", $targets)
      run_command(@("CMD"), $targets)
        /opt/puppetlabs/bin/puppet-backup create --dir=${shellquote($backup_directory)}/code --scope=code
        | CMD
    }

    if getvar('recovery_opts.config') {
      out::message('# Backing up config')
      run_command("chown pe-postgres ${shellquote($backup_directory)}/config", $targets)
      run_command(@("CMD"), $targets)
        /opt/puppetlabs/bin/puppet-backup create --dir=${shellquote($backup_directory)}/config --scope=config
        | CMD
    }
  }
  # Check if /etc/puppetlabs/console-services/conf.d/secrets/keys.json exists and if so back it up
  if getvar('recovery_opts.rbac') {
    out::message('# Backing up ldap secret key if it exists')
# lint:ignore:140chars
    run_command(@("CMD"/L), $targets)
      test -f /etc/puppetlabs/console-services/conf.d/secrets/keys.json \
        && cp -rp /etc/puppetlabs/console-services/conf.d/secrets ${shellquote($backup_directory)}/rbac/ \
        || echo secret ldap key doesnt exist
      | CMD
# lint:endignore
  }
# lint:ignore:140chars
  # IF backing up orchestrator back up the secrets too /etc/puppetlabs/orchestration-services/conf.d/secrets/
  if getvar('recovery_opts.orchestrator') {
    out::message('# Backing up orchestrator secret keys')
    run_command(@("CMD"), $targets)
      cp -rp /etc/puppetlabs/orchestration-services/conf.d/secrets ${shellquote($backup_directory)}/orchestrator/
      | CMD
  }
# lint:endignore
  $backup_databases.each |$name,$database_target| {
    out::message("# Backing up database pe-${shellquote($name)}")
    run_command(@("CMD"/L), $targets)
      /opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4 \
        -f ${shellquote($backup_directory)}/${shellquote($name)}/pe-${shellquote($name)}.dump.d \
        "sslmode=verify-ca \
         host=${shellquote($database_target.peadm::certname())} \
         user=pe-${shellquote($name)} \
         sslcert=/etc/puppetlabs/puppetdb/ssl/${shellquote($primary_target.peadm::certname())}.cert.pem \
         sslkey=/etc/puppetlabs/puppetdb/ssl/${shellquote($primary_target.peadm::certname())}.private_key.pem \
         sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem \
         dbname=pe-${shellquote($name)}"
      | CMD
  }

  run_command(@("CMD"/L), $targets)
    umask 0077 \
      && cd ${shellquote(dirname($backup_directory))} \
      && tar -czf ${shellquote($backup_directory)}.tar.gz ${shellquote(basename($backup_directory))} \
      && rm -rf ${shellquote($backup_directory)}
    | CMD
# lint:endignore
  return({ 'path' => "${backup_directory}.tar.gz" })
}
