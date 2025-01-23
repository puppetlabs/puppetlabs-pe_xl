function peadm::amend_recovery_defaults_by_pe_version (
  Hash              $base_opts,
  Peadm::Pe_version $pe_version,
  Boolean           $opt_value,
) {
  # work around puppet-lint check_unquoted_string_in_case
  $pe_2025_0 = SemVerRange('>= 2025.0')
  $pe_2023_7 = SemVerRange('>= 2023.7')
  case $pe_version {
    $pe_2025_0: {
      $base_opts + {
        'hac'      => $opt_value,
        'patching' => $opt_value,
      }
    }
    $pe_2023_7: {
      $base_opts + {
        'hac' => $opt_value,
      }
    }
    default: {
      $base_opts
    }
  }
}
