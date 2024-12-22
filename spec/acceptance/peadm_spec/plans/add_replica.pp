plan peadm_spec::add_replica(
) {
  $t = get_targets('*')
  wait_until_available($t)

  parallelize($t) |$target| {
    $fqdn = run_command('hostname -f', $target)
    $target.set_var('certname', $fqdn.first['stdout'].chomp)
  }

  $primary_host = $t.filter |$n| { $n.vars['role'] == 'primary' }
  $replica_host = $t.filter |$n| { $n.vars['role'] == 'spare-replica' }

  if $replica_host == [] {
    fail_plan('"replica" role missing from inventory, cannot continue')
  }

  run_plan('peadm::add_replica',
    primary_host            => $primary_host,
    replica_host            => $replica_host,
  )
}
