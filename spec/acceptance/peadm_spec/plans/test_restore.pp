plan peadm_spec::test_restore() {
  $t = get_targets('*')
  wait_until_available($t)

  parallelize($t) |$target| {
    $fqdn = run_command('hostname -f', $target)
    $certname = $fqdn.first['stdout'].chomp
    $target.set_var('certname', $certname)
  }

  $targets_with_name = $t.map |$target| {
    Target.new({
        'uri' => $target.uri,
        'name' => $target.vars['certname'],
        'config' => $target.config,
        'vars' => $target.vars,
    })
  }

  $primary_host = $targets_with_name.filter |$n| { $n.vars['role'] == 'primary' }[0]

  # get the latest backup file, if more than one exists
  $result = run_command('ls -t /tmp/pe-backup*gz | head -1', $primary_host).first.value
  $input_file = strip(getvar('result.stdout'))

  run_plan('peadm::restore', $primary_host, { 'restore_type' => 'recovery', 'input_file' => $input_file })

  # run infra status on the primary
  out::message("Running peadm::status on primary host ${primary_host}")
  $status = run_plan('peadm::status', $primary_host, { 'format' => 'json' })

  out::message($status)

  if empty($status['failed']) {
    out::message('Cluster is healthy, continuing')
  } else {
    fail_plan('Cluster is not healthy, aborting')
  }
}
