plan peadm_spec::provision_test_cluster (
  $provider,
  $architecture,
  $image,
) {
  $nodes =
    case $architecture {
      'standard': {
        ['primary']
      }
      'standard-with-dr': {
        ['primary', 'replica']
      }
      'standard-and-spare-replica': {
        ['primary', 'spare-replica']
      }
      'standard-with-dr-and-spare-replica': {
        ['primary', 'replica', 'spare-replica']
      }
      'large': {
        ['primary', 'compiler']
      }
      'large-with-two-compilers': {
        ['primary', 'compiler', 'compiler']
      }
      'large-with-dr': {
        ['primary', 'compiler', 'replica', 'compiler']
      }
      'large-and-spare-replica': {
        ['primary', 'compiler', 'compiler', 'spare-replica']
      }
      'large-with-dr-and-spare-replica': {
        ['primary', 'compiler', 'replica', 'compiler', 'spare-replica']
      }
      'extra-large': {
        ['primary', 'primary-pdb-postgresql', 'compiler']
      }
      'extra-large-with-dr': {
        ['primary', 'primary-pdb-postgresql', 'compiler', 'replica', 'replica-pdb-postgresql', 'compiler']
      }
      'extra-large-with-dr-migration': {
        ['primary', 'primary-pdb-postgresql', 'compiler', 'replica', 'replica-pdb-postgresql', 'compiler', 'primary2', 'primary-pdb-postgresql2', 'replica2', 'replica-pdb-postgresql2']
      }
      'standard-with-extra-compiler': {
        ['primary', 'unconfigured-compiler']
      }
      'large-with-extra-compiler': {
        ['primary', 'compiler', 'unconfigured-compiler']
      }
      'extra-large-with-extra-compiler': {
        ['primary', 'primary-pdb-postgresql', 'compiler', 'unconfigured-compiler']
      }
      'extra-large-and-spare-replica': {
        ['primary', 'primary-pdb-postgresql', 'compiler', 'compiler', 'spare-replica']
      }
      'extra-large-with-dr-and-spare-replica': {
        ['primary', 'primary-pdb-postgresql', 'compiler',
        'replica', 'replica-pdb-postgresql', 'compiler', 'spare-replica']
      }
      default: {
        fail_plan("Unknown architecture: ${architecture}")
      }
  }

  $provision_results =
    # This SHOULD be `parallelize() || {}`. However, provision::* is entirely
  # side-effect based, and not at all parallel-safe.
  $nodes.each |$role| {
    run_task("provision::${provider}", 'localhost',
      action   => 'provision',
      platform => $image,
      vars     => "role: ${role}"
    )
  }

  return($provision_results)
}
