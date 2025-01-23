# @summary Restore puppet primary configuration
#
# @param targets This should be the primary puppetserver for the puppet cluster
# @param restore_type Choose from `recovery`, `recovery-db` and `custom`
# @param restore A hash of custom backup options, see the peadm::recovery_opts_default() function for the default values
# @param input_file The file containing the backup to restore from
# @example 
#   bolt plan run peadm::restore -t primary1.example.com input_file=/tmp/peadm-backup.tar.gz
#
plan peadm::restore (
  # This plan should be run on the primary server
  Peadm::SingleTargetSpec $targets,

  # restore type determines the restore options
  Enum['recovery', 'recovery-db', 'custom'] $restore_type = 'recovery',

  # Which data to restore
  Peadm::Recovery_opts $restore = {},

  # Path to the recovery tarball
  Pattern[/.*\.tar\.gz$/] $input_file,
) {
  peadm::assert_supported_bolt_version()

  $recovery_directory = "${dirname($input_file)}/${basename($input_file, '.tar.gz')}"
# lint:ignore:strict_indent
  run_command(@("CMD"/L), $targets)
    umask 0077 \
      && cd ${shellquote(dirname($recovery_directory))} \
      && tar -xzf ${shellquote($input_file)}
    | CMD
# lint:endignore

  # try to load the cluster configuration by running peadm::get_peadm_config, but allow for errors to happen
  $_cluster = run_task('peadm::get_peadm_config', $targets, { '_catch_errors' => true }).first.value

  if $_cluster == undef or getvar('_cluster.params') == undef or getvar('_cluster.pe_version') == undef {
    # failed to get cluster config, load from backup
    out::message('Failed to get cluster configuration, loading from backup...')
    $result = download_file("${recovery_directory}/peadm/peadm_config.json", 'peadm_config.json', $targets).first.value
    $cluster = loadjson(getvar('result.path'))
    out::message('Cluster configuration loaded from backup')
  } else {
    $cluster = $_cluster
  }

  out::message("cluster: ${cluster}")

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

  $recovery_opts = $restore_type? {
    'recovery'     => peadm::recovery_opts_default($pe_version),
    'recovery-db'  => { 'puppetdb' => true, },
    'migration'    => peadm::migration_opts_default($pe_version),
    'custom'       => peadm::recovery_opts_all($pe_version) + $restore,
  }

  $primary_target   = peadm::get_targets(getvar('cluster.params.primary_host'), 1)
  $replica_target   = peadm::get_targets(getvar('cluster.params.replica_host'), 1)
  $compiler_targets = peadm::get_targets(getvar('cluster.params.compiler_hosts'))

  # Determine the array of targets to which the PuppetDB PostgreSQL database
  # should be restored to. This could be as simple as just the primary server,
  # or it could be two separate PostgreSQL servers.
  $puppetdb_postgresql_targets = peadm::flatten_compact([
      getvar('cluster.params.primary_postgresql_host') ? {
        undef   => $primary_target,
        default => peadm::get_targets(getvar('cluster.params.primary_postgresql_host'), 1),
      },
      getvar('cluster.params.replica_postgresql_host') ? {
        undef   => $replica_target,
        default => peadm::get_targets(getvar('cluster.params.replica_postgresql_host'), 1),
      },
  ])

  $puppetdb_targets = peadm::flatten_compact([
      $primary_target,
      $replica_target,
      $compiler_targets,
  ])

  # Map of recovery option name to array of database hosts to restore the
  # relevant .dump content to.
  $restore_databases = {
    'orchestrator' => [$primary_target],
    'activity'     => [$primary_target],
    'rbac'         => [$primary_target],
    'puppetdb'     => $puppetdb_postgresql_targets,
    # (host-action-collector db will be filtered for pe version by recovery_opts)
    'hac'          => $primary_target,
    # (patching db will be filtered for pe version by recovery_opts)
    'patching'     => $primary_target,
  }.filter |$key,$_| {
    $recovery_opts[$key] == true
  }

  if getvar('recovery_opts.classifier') {
    if $restore_type == 'migration' {
      out::message('# Migrating classification')
      run_task('peadm::backup_classification', $primary_target,
        directory => $recovery_directory
      )

      run_task('peadm::transform_classification_groups', $primary_target,
        source_directory  => "${recovery_directory}/classifier",
        working_directory => $recovery_directory
      )

      run_task('peadm::restore_classification', $primary_target,
        classification_file => "${recovery_directory}/transformed_classification.json",
      )
    } else {
      run_task('peadm::restore_classification', $primary_target,
        classification_file => "${recovery_directory}/classifier/classification_backup.json",
      )
    }
  }

  if $restore_type == 'recovery' {
    out::message('# Restoring ca, certs, code and config for recovery')
  # lint:ignore:strict_indent
      run_command(@("CMD"/L), $primary_target)
        /opt/puppetlabs/bin/puppet-backup restore \
          --scope=certs,code,config \
          --tempdir=${shellquote($recovery_directory)} \
          --force \
          ${shellquote($recovery_directory)}/recovery/pe_backup-*tgz
        | CMD
  # lint:endignore
  } elsif $restore_type == 'recovery-db' {
    out::message('# Restoring primary database for recovery')
  } else {
    if getvar('recovery_opts.ca') {
      out::message('# Restoring ca and ssl certificates')
  # lint:ignore:strict_indent
      run_command(@("CMD"/L), $primary_target)
        /opt/puppetlabs/bin/puppet-backup restore \
          --scope=certs \
          --tempdir=${shellquote($recovery_directory)} \
          --force \
          ${shellquote($recovery_directory)}/ca/pe_backup-*tgz
        | CMD
    }

    if getvar('recovery_opts.code') {
      out::message('# Restoring code')
      run_command(@("CMD"/L), $primary_target)
        /opt/puppetlabs/bin/puppet-backup restore \
          --scope=code \
          --tempdir=${shellquote($recovery_directory)} \
          --force \
          ${shellquote($recovery_directory)}/code/pe_backup-*tgz
        | CMD
    }

    if getvar('recovery_opts.config') {
      out::message('# Restoring config')
      run_command(@("CMD"/L), $primary_target)
        /opt/puppetlabs/bin/puppet-backup restore \
          --scope=config \
          --tempdir=${shellquote($recovery_directory)} \
          --force \
          ${shellquote($recovery_directory)}/config/pe_backup-*tgz
        | CMD
    }
  }
  # Use PuppetDB's /pdb/admin/v1/archive API to SAVE data currently in PuppetDB.
  # Otherwise we'll completely lose it if/when we restore.
  # TODO: consider adding a heuristic to skip when innappropriate due to size
  #       or other factors.
  if getvar('recovery_opts.puppetdb') and $restore_type == 'migration' {
    out::message('# Exporting puppetdb')
    run_command(@("CMD"/L), $primary_target)
      /opt/puppetlabs/bin/puppet-db export \
        --cert=$(/opt/puppetlabs/bin/puppet config print hostcert) \
        --key=$(/opt/puppetlabs/bin/puppet config print hostprivkey) \
        ${shellquote($recovery_directory)}/puppetdb-archive.bin
      | CMD
  }

  ## shutdown services
  run_command(@("CMD"/L), $primary_target)
    systemctl stop pe-console-services pe-nginx pxp-agent pe-puppetserver \
                   pe-orchestration-services puppet pe-puppetdb
    | CMD

  # Restore secrets/keys.json if it exists
  out::message('# Restoring ldap secret key if it exists')
  run_command(@("CMD"/L), $primary_target)
    test -f ${shellquote($recovery_directory)}/rbac/keys.json \
      && cp -rp ${shellquote($recovery_directory)}/keys.json /etc/puppetlabs/console-services/conf.d/secrets/ \
      || echo secret ldap key doesnt exist
    | CMD
# lint:ignore:140chars
  # IF restoring orchestrator restore the secrets to /etc/puppetlabs/orchestration-services/conf.d/secrets/
  if getvar('recovery_opts.orchestrator') {
    out::message('# Restoring orchestrator secret keys')
    run_command(@("CMD"/L), $primary_target)
      cp -rp ${shellquote($recovery_directory)}/orchestrator/secrets/* /etc/puppetlabs/orchestration-services/conf.d/secrets/
      | CMD
  }
# lint:endignore

  #$database_to_restore.each |Integer $index, Boolean $value | {
  $restore_databases.each |$name,$database_targets| {
    out::message("# Restoring database pe-${name}")
    $dbname = "pe-${shellquote($name)}"

    # Drop pglogical extensions and schema if present
    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           --tuples-only \
           -d '${dbname}' \
           -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'"
      | CMD

    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           -d '${dbname}' \
           -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"
      | CMD

    # To allow db user to restore the database grant temporary privileges
    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           -d '${dbname}' \
           -c 'ALTER USER \"${dbname}\" WITH SUPERUSER;'"
      | CMD

    # Restore database. If there are multiple database restore targets, perform
    # the restore(s) in parallel.
    parallelize($database_targets) |$database_target| {
      run_command(@("CMD"/L), $primary_target)
        /opt/puppetlabs/server/bin/pg_restore \
          -j 4 \
          -d "sslmode=verify-ca \
              host=${shellquote($database_target.peadm::certname())} \
              sslcert=/etc/puppetlabs/puppetdb/ssl/${shellquote($primary_target.peadm::certname())}.cert.pem \
              sslkey=/etc/puppetlabs/puppetdb/ssl/${shellquote($primary_target.peadm::certname())}.private_key.pem \
              sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem \
              dbname=${dbname} \
              user=${dbname}" \
          -Fd ${recovery_directory}/${name}/${dbname}.dump.d
        | CMD
    }

    # Remove db user privileges post restore
    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           -d '${dbname}' \
           -c 'ALTER USER \"${dbname}\" WITH NOSUPERUSER;'"
      | CMD

    # Drop pglogical extension and schema (again) if present after db restore
    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           --tuples-only \
           -d '${dbname}' \
           -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'"
      | CMD

    run_command(@("CMD"/L), $database_targets)
      su - pe-postgres -s /bin/bash -c \
        "/opt/puppetlabs/server/bin/psql \
           -d '${dbname}' \
           -c 'DROP EXTENSION IF EXISTS pglogical CASCADE;'"
      | CMD
  }

  # Use `puppet infra` to ensure correct file permissions, restart services,
  # etc. Make sure not to try and get config data from the classifier, which
  # isn't yet up and running.
  run_command(@("CMD"/L), $primary_target)
    /opt/puppetlabs/bin/puppet-infrastructure configure --no-recover
    | CMD

  # If we have replicas reinitalise them
  run_command(@("CMD"/L), $replica_target)
    /opt/puppetlabs/bin/puppet-infra reinitialize replica -y
    | CMD

  # Use PuppetDB's /pdb/admin/v1/archive API to MERGE previously saved data
  # into the restored database.
  # TODO: consider adding a heuristic to skip when innappropriate due to size
  #       or other factors.
  if getvar('recovery_opts.puppetdb') and $restore_type == 'migration' {
    run_command(@("CMD"/L), $primary_target)
      /opt/puppetlabs/bin/puppet-db import \
      --cert=$(/opt/puppetlabs/bin/puppet config print hostcert) \
      --key=$(/opt/puppetlabs/bin/puppet config print hostprivkey) \
      ${shellquote($recovery_directory)}/puppetdb-archive.bin
      | CMD
# lint:endignore
  }

# Run Puppet to pick up last remaining config tweaks
  run_task('peadm::puppet_runonce', $primary_target)

  if $restore_type == 'recovery-db' {
    run_task('peadm::puppet_runonce', $puppetdb_postgresql_targets)
  }

  apply($primary_target) {
    file { $recovery_directory :
      ensure => 'absent',
      force  => true,
    }
  }

  return('success')
}
