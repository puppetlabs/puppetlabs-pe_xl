#
# @summary check if a group of targets are reachable for bolt
#
# @param targets list of targets that are going to be checked
# @param output_details flag to enable/disable error output for failed nodes
#
# @return counter for unavailable nodes
#
# @author Tim Meusel <tim@bastelfreak.de>
#
function peadm::check_availability(
  TargetSpec $targets,
  Boolean $output_details = true
) >> Integer {
  $check_result = wait_until_available($targets, wait_time => 2, _catch_errors => true)
  unless $check_result.ok {
    $end_message = "${check_result.error_set.count} targets are not reachable, stopping plan"
    fail_plan($end_message, 'peadm/unreachable-nodes', error_set => $check_result.error_set)
  }

  return $check_result.error_set.count
}
