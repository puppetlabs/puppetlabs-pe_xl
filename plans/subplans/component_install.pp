# @api private
#
# @summary Install a new PEADM component
# @param targets _ The hostname of the new component server
# @param primary_host _ The hostname the primary Puppet server
# @param avail_group_letter _ Either A or B; whichever of the two letter designations the component is assigned to
# @param dns_alt_names _ A comma_separated list of DNS alt names for the component
# @param role _ Optional PEADM role the component will serve
plan peadm::subplans::component_install(
  Peadm::SingleTargetSpec                $targets,
  Peadm::SingleTargetSpec                $primary_host,
  Enum['A', 'B']                         $avail_group_letter,
  Optional[Variant[String[1], Array]]    $dns_alt_names = undef,
  Optional[String[1]]                    $role          = undef
) {
  $component_target          = peadm::get_targets($targets, 1)
  $primary_target            = peadm::get_targets($primary_host, 1)

  # Set pp_auth_role instead of peadm_role for compiler role
  if $role == 'pe_compiler' {
    $certificate_extensions = {
      peadm::oid('pp_auth_role')             => 'pe_compiler',
      peadm::oid('peadm_availability_group') => $avail_group_letter,
    }
  } elsif $role == 'pe_compiler_legacy' {
    $certificate_extensions = {
      peadm::oid('pp_auth_role')             => 'pe_compiler_legacy',
      peadm::oid('peadm_availability_group') => $avail_group_letter,
    }
  } else {
    $certificate_extensions = {
      peadm::oid('peadm_role')               => $role,
      peadm::oid('peadm_availability_group') => $avail_group_letter,
    }
  }

  run_plan('peadm::subplans::prepare_agent', $component_target,
    primary_host           => $primary_target,
    dns_alt_names          => peadm::flatten_compact([$dns_alt_names]),
    certificate_extensions => $certificate_extensions,
  )

  # On component, run the puppet agent to finish initial configuring of component
  run_task('peadm::puppet_runonce', $component_target)

  return("Installation of component ${$component_target.peadm::certname()} with peadm_role: ${role} succeeded.")
}
