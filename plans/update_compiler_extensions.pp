# @api private
plan peadm::update_compiler_extensions (
  TargetSpec       $compiler_hosts,
  Peadm::SingleTargetSpec $primary_host,
  Boolean                 $legacy = false,
) {
  $primary_target            = peadm::get_targets($primary_host, 1)
  $host_targets              = peadm::get_targets($compiler_hosts)

  run_task('peadm::puppet_runonce', $primary_target)
  run_task('peadm::puppet_runonce', $host_targets)

  if $legacy {
    run_command('systemctl restart pe-puppetserver.service', $host_targets)
  } else {
    run_command('systemctl restart pe-puppetserver.service pe-puppetdb.service', $host_targets)
  }

  return("Added legacy cert with value ${legacy} to compiler hosts ${compiler_hosts}")
}
