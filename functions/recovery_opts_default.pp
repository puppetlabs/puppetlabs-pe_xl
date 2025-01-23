function peadm::recovery_opts_default (
  Peadm::Pe_version $pe_version,
) {
  $base_opts = {
    'activity'     => false,
    'ca'           => true,
    'classifier'   => false,
    'code'         => true,
    'config'       => true,
    'orchestrator' => false,
    'puppetdb'     => true,
    'rbac'         => false,
  }
  peadm::amend_recovery_defaults_by_pe_version($base_opts, $pe_version, false)
}
