# @api private
plan peadm::util::retrieve_and_upload(
  TargetSpec $nodes,
  String[1]  $source,
  String[1]  $local_path,
  String[1]  $upload_path,
) {
  # lint:ignore:strict_indent
  $nodes.peadm::fail_on_transport('pcp', @(HEREDOC/n))
    \nThe "pcp" transport is not available for uploading PE installers as
    the ".tar.gz" file is too large to send over the PE Orchestrator
    as an argument to the "bolt_shim::upload" task.

    To upgrade PE XL database nodes via PCP, use "download_mode = direct".
    If Puppet download servers are not reachable over the internet,
    upload the ".tar.gz" to an internal fileserver and use the
    "pe_installer_source" parameter to retrieve it.

    For information on configuring plan parameters, see:

        https://forge.puppet.com/modules/puppetlabs/peadm/plans

    Or, use the "ssh" transport for database nodes so that the
    installer can be transferred via SCP.

    For information on configuring transports, see:

        https://www.puppet.com/docs/bolt/latest/bolt_transports_reference.html
    |-HEREDOC
    # lint:endignore

  $operating_system = run_task('facts', 'local://localhost')
  $os_string =$operating_system.first.value['os']['family']

  if 'windows' in $os_string {
    $exists = run_command("[System.IO.File]::Exists('${local_path}')", 'local://localhost')
    if $exists.first['stdout'].chomp == 'false' {
      run_task('peadm::download', 'local://localhost',
        source => $source,
        path   => $local_path,
      )
    }

    $result_size = run_task('peadm::filesize', 'local://localhost',
      path => $local_path,
    )
    $local_size = $result_size.first.value['_output']
  } else {
    $exists = without_default_logging() || {
      run_command("test -e '${local_path}'", 'local://localhost',
        _catch_errors => true,
      ).ok()
    }
    unless $exists {
      run_task('peadm::download', 'local://localhost',
        source => $source,
        path   => $local_path,
      )
    }

    $local_size = run_task('peadm::filesize', 'local://localhost',
      path => $local_path,
    ).first['size']
  }

  $targets_needing_file = run_task('peadm::filesize', $nodes,
    path => $upload_path,
  ).filter |$result| {
    $result['size'] != $local_size
  }.map |$result| {
    $result.target
  }

  upload_file($local_path, $upload_path, $targets_needing_file)
}
