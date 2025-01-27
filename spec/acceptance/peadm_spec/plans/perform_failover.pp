# This plan performs a failover procedure on an XL architecture
# It assumes an inventory files with roles specified including a `spare-replica` role
plan peadm_spec::perform_failover(
) {
  # get node certnames
  $t = get_targets('*')
  wait_until_available($t)

  parallelize($t) |$target| {
    $fqdn = run_command('hostname -f', $target)
    $target.set_var('certname', $fqdn.first['stdout'].chomp)
  }

  # run infra status on the primary
  $primary_host = $t.filter |$n| { $n.vars['role'] == 'primary' }[0]
  out::verbose("Running peadm::status on new primary host ${primary_host}")
  run_plan('peadm::status', $primary_host)

  # bring down the current primary right now
  out::verbose("Bringing down primary host ${primary_host}")
  # prevent host from starting up networking in case it comes up again
  run_command('systemctl set-default basic.target', $primary_host, _catch_errors => true)
  run_task('reboot', $primary_host, shutdown_only => true, timeout => 0)

  # remove the certname of the failed primary from the primary postgresql database
  $primary_postgresql_host = $t.filter |$n| { $n.vars['role'] == 'primary-pdb-postgresql' }[0]
  run_task('peadm_spec::delete_certname', $primary_postgresql_host,
    certname => peadm::certname($primary_host))

  # promote the replica to new primary
  $replica_host = $t.filter |$n| { $n.vars['role'] == 'replica' }[0]
  out::verbose("Promoting replica host ${replica_host} to primary")
  run_command(@("HEREDOC"/L), $replica_host)
    /opt/puppetlabs/bin/puppet infra promote replica --topology mono-with-compile --yes
  |-HEREDOC

  # # purge the "failed" primary node
  # run_command(@("HEREDOC"/L), $replica_host)
  #   /opt/puppetlabs/bin/puppet node purge ${peadm::certname($primary_host)}
  # |-HEREDOC

  # generate access token on new primary
  out::verbose("Generating access token on replica host ${replica_host}")
  run_task('peadm::rbac_token', $replica_host,
    password       => 'puppetlabs',
    token_lifetime => '1y',
  )

  $query = '["from","resources",["extract",["certname"],["and",["=","type","Class"],["=","title","Puppet_enterprise::Profile::Master"]]]]'
  $res1 = run_command("/opt/puppetlabs/bin/puppet query \'${query}\'", $replica_host)
  out::message("Active nodes 1: ${res1.first['stdout']}")

  # forget the "failed" primary node
  run_command(@("HEREDOC"/L), $replica_host, _catch_errors => true)
    /opt/puppetlabs/bin/puppet infrastructure forget ${peadm::certname($primary_host)}
  |-HEREDOC

  $res2 = run_command("/opt/puppetlabs/bin/puppet query \'${query}\'", $replica_host)
  out::message("Active nodes 2: ${res2.first['stdout']}")

  # add new replica
  $new_replica_host = $t.filter |$n| { $n.vars['role'] == 'spare-replica' }[0]

  if $new_replica_host == [] {
    fail_plan('"spare-replica" role missing from inventory, cannot continue')
  }

  # run puppet on all infrastructure nodes (except the failed primary and the spare replica) 
  # to remove the "failed" primary node
  run_task('peadm::puppet_runonce', $t - $new_replica_host - $primary_host)

  # TODO: remove the failed primary from the pe.conf file on the primary postgresql node

  out::verbose("Adding new replica host ${new_replica_host} to primary")
  run_plan('peadm::add_replica',
    primary_host            => $replica_host.uri,
    replica_host            => $new_replica_host.uri,
  )

  $res3 = run_command("/opt/puppetlabs/bin/puppet query \'${query}\'", $replica_host)
  out::message("Active nodes 3: ${res3.first['stdout']}")

  # run infra status on the new primary
  out::verbose("Running peadm::status on new primary host ${replica_host}")
  run_plan('peadm::status', $replica_host)

  out::message('Failover process complete. New configuration:')
  run_task('peadm::get_peadm_config', $replica_host)
}
