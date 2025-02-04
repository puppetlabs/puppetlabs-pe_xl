plan peadm::check_config(
  TargetSpec $targets
) {
  get_targets($targets).each |$target| {
    $peadm_config = run_task('peadm::get_peadm_config', $target).first.value
    out::message("${target} - peadm_config:${$peadm_config}.")
    $postgresql_a_host = $peadm_config['role-letter']['postgresql']['A']
    $postgresql_b_host = $peadm_config['role-letter']['postgresql']['B']
    $pe_status = run_task('service', $target, 'action' => 'status', 'name' => 'puppet.service')
    $pdb_status = run_task('service', $target, 'action' => 'status', 'name' => 'pe-puppetdb.service')
    $agent_status = run_task('package', $target,
      action => 'status',
    name   => 'puppet-agent').first['status']
    out::message("${target} - postgresql_a_host:${$postgresql_a_host}.")
    out::message("${target} - postgresql_b_host:${$postgresql_b_host}.")
    out::message("${target} - pe_status:${$pe_status}.")
    out::message("${target} - pdb_status:${$pdb_status}.")
    out::message("${target} - agent_status:${$agent_status}.")
  }
}
