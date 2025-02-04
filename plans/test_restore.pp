plan peadm::test_restore (
  # This plan should be run on the primary server
  Peadm::SingleTargetSpec $target,

  # Path to the recovery tarball
  Pattern[/.*\.tar\.gz$/] $input_file,

  # boolean flag to indicate clean target before restore
  Boolean $clean_target = false,
) {
  peadm::assert_supported_bolt_version()

  # prior to running this plan the user will have something like this:
  # perform a backup on the source PE server:
  # bolt plan run peadm::backup backup_type=migration -t festive-gantlet.delivery.puppetlabs.net --no-host-key-check 
  #
  # download the backup file locally:
  # bolt file download /tmp/pe-backup-2025-01-30T091722Z.tar.gz /tmp --targets festive-gantlet.delivery.puppetlabs.net --no-host-key-check 
  #
  # upload the backup file to the target PE server:
  # bolt file upload /tmp/festive-gantlet.delivery.puppetlabs.net/pe-backup-2025-01-30T091722Z.tar.gz /tmp --targets inspiring-reign.delivery.puppetlabs.net --no-host-key-check 
  #
  # install PE on the target server (using the "code_manager_auto_configure": true parameter)
  # bolt plan run peadm::install primary_host=inspiring-reign.delivery.puppetlabs.net replica_host=inspiring-reign.delivery.puppetlabs.net code_manager_auto_configure=true --no-host-key-check
  #
  # run this plan to restore the backup on the target PE server:
  # bolt plan run peadm::test_restore clean_target=false input_file=/tmp/festive-gantlet.delivery.puppetlabs.net/pe-backup-2025-01-30T135004Z.tar.gz target=inspiring-reign.delivery.puppetlabs.net --no-host-key-check 
  #

  $params = loadjson('params.json')
  $primary_host = $params['primary_host']
  out::message("params: ${params}")
  out::message("primary_host:${primary_host}.")

  # check param to see if we need to do an uninstall/install on the target
  if $clean_target {
    out::message('Cleaning target before restore')
    run_plan('peadm::uninstall', $target)
    run_plan('peadm::install', $params)
    #run_plan('peadm::install', $target, { 'params' => '@params.json' })
  } else {
    out::message('Skipping clean target before restore')
  }

  # delete the file on the target first in case it is there
  $file_name = basename($input_file)
  $dir_name = $file_name[0,-8]
  out::message("Deleting /tmp/${file_name} and /tmp/${dir_name} on ${target}")
  run_command("rm -rf /tmp/${file_name}", $target)
  run_command("rm -rf /tmp/${dir_name}", $target)

  # copy the file over from the bolt controller to the target
  out::message("Copying ${input_file} to /tmp/${file_name} on ${target}")
  upload_file($input_file, "/tmp/${file_name}", $target)

  # kick off the restore plan on the target
  out::message("Running peadm::restore on ${target}")
  run_plan('peadm::restore', $target, { 'input_file' => "/tmp/${file_name}", 'restore_type' => 'migration' })

  # # add replica back
  # run_plan('peadm::add_replica',
  #   primary_host            => $primary_host,
  #   replica_host            => $replica_host,
  #   replica_postgresql_host => undef,
  # )
}
