# Verify that *pe_version* string is a valid SemVer.
# If not, warn, and return "0.0.0" as a permissive default.
function peadm::validated_pe_version_for_backup_restore(
  Optional[String] $pe_version,
) {
  # work around puppet-lint check_unquoted_string_in_case
  $semverrange = SemVerRange('>=0.0.0')
  case $pe_version {
    # Validate that the value is a SemVer value.
    $semverrange: {
      $pe_version
    }
    default: {
      $msg = @("WARN")
        WARNING: Retrieved a missing or unparseable PE version of '${pe_version}'.
        Newer service databases released in 2023.7+ will be skipped from defaults.
        (host-action-collector, patching)
        |-WARN
      out::message($msg)
      '0.0.0'
    }
  }
}
