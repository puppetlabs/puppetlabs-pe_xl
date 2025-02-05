# @summary Install a new PE cluster
#
# @param compiler_pool_address 
#   The service address used by agents to connect to compilers, or the Puppet
#   service. Typically this is a load balancer.
# @param internal_compiler_a_pool_address
#   A load balancer address directing traffic to any of the "A" pool
#   compilers. This is used for DR configuration in large and extra large
#   architectures.
# @param internal_compiler_b_pool_address
#   A load balancer address directing traffic to any of the "B" pool
#   compilers. This is used for DR configuration in large and extra large
#   architectures.
# @param pe_installer_source
#   The URL to download the Puppet Enterprise installer media from. If not
#   specified, PEAdm will attempt to download PE installation media from its
#   standard public source. When specified, PEAdm will download directly from the
#   URL given.
# @param ldap_config
#   If specified, configures PE RBAC DS with the supplied configuration hash.
#   The parameter should be set to a valid set of connection settings as
#   documented for the PE RBAC /ds endpoint. See:
#   https://puppet.com/docs/pe/latest/rbac_api_v1_directory.html#put_ds-request_format
# @param final_agent_state
#   Configures the state the puppet agent should be in on infrastructure nodes
#   after PE is configured successfully.
# @param stagingdir
#   Directory on the Bolt host where the installer tarball will be cached if
#   download_mode is 'bolthost' (default)
# @param uploaddir
#   Directory the installer tarball will be uploaded to or expected to be in
#   for offline usage.
#
plan peadm::install (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts = undef,
  Optional[TargetSpec]              $legacy_compilers = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host = undef,

  # Common Configuration
  String                            $console_password,
  Peadm::Pe_version                 $version                          = '2023.8.0',
  Optional[Stdlib::HTTPSUrl]        $pe_installer_source              = undef,
  Optional[Array[String]]           $dns_alt_names                    = undef,
  Optional[String]                  $compiler_pool_address            = undef,
  Optional[String]                  $internal_compiler_a_pool_address = undef,
  Optional[String]                  $internal_compiler_b_pool_address = undef,
  Optional[Hash]                    $pe_conf_data                     = {},
  Optional[Peadm::Ldap_config]      $ldap_config                      = undef,

  # Code Manager
  Optional[Boolean]                 $code_manager_auto_configure = undef,
  Optional[String]                  $r10k_remote              = undef,
  Optional[String]                  $r10k_private_key_file    = undef,
  Optional[Peadm::Pem]              $r10k_private_key_content = undef,
  Optional[Peadm::Known_hosts]      $r10k_known_hosts         = undef,
  Optional[String]                  $deploy_environment       = undef,

  # License Key
  Optional[String]                  $license_key_file    = undef,
  Optional[String]                  $license_key_content = undef,

  # Other
  Optional[String]           $stagingdir             = undef,
  Optional[String]           $uploaddir              = undef,
  Enum['running', 'stopped'] $final_agent_state      = 'running',
  Peadm::Download_mode       $download_mode          = 'bolthost',
  Boolean                    $permit_unsafe_versions = false,
  String                     $token_lifetime         = '1y',
) {
  peadm::assert_supported_bolt_version()

  peadm::assert_supported_pe_version($version, $permit_unsafe_versions)

  $install_result = run_plan('peadm::subplans::install',
    # Standard
    primary_host                   => $primary_host,
    replica_host                   => $replica_host,

    # Large
    compiler_hosts                 => $compiler_hosts,
    legacy_compilers               => $legacy_compilers,

    # Extra Large
    primary_postgresql_host        => $primary_postgresql_host,
    replica_postgresql_host        => $replica_postgresql_host,

    # Common Configuration
    version                        => $version,
    pe_installer_source            => $pe_installer_source,
    console_password               => $console_password,
    dns_alt_names                  => $dns_alt_names,
    pe_conf_data                   => $pe_conf_data,

    # Code Manager
    code_manager_auto_configure => $code_manager_auto_configure,
    r10k_remote                    => $r10k_remote,
    r10k_private_key_file          => $r10k_private_key_file,
    r10k_private_key_content       => $r10k_private_key_content,
    r10k_known_hosts               => $r10k_known_hosts,

    # License Key
    license_key_file               => $license_key_file,
    license_key_content            => $license_key_content,

    # Other
    stagingdir                     => $stagingdir,
    uploaddir                      => $uploaddir,
    download_mode                  => $download_mode,
    permit_unsafe_versions         => $permit_unsafe_versions,
    token_lifetime                 => $token_lifetime,
  )

  $configure_result = run_plan('peadm::subplans::configure',
    # Standard
    primary_host                     => $primary_host,
    replica_host                     => $replica_host,

    # Large
    compiler_hosts                   => $compiler_hosts,
    legacy_compilers                 => $legacy_compilers,

    # Extra Large
    primary_postgresql_host          => $primary_postgresql_host,
    replica_postgresql_host          => $replica_postgresql_host,

    # Common Configuration
    compiler_pool_address            => $compiler_pool_address,
    internal_compiler_a_pool_address => $internal_compiler_a_pool_address,
    internal_compiler_b_pool_address => $internal_compiler_b_pool_address,
    deploy_environment               => $deploy_environment,
    ldap_config                      => $ldap_config,

    # Other
    stagingdir                       => $stagingdir,
    final_agent_state                => $final_agent_state,
  )

  run_task('peadm::update_pe_master_rules', $primary_host)

  # Return a string banner reporting on what was done
  return([$install_result, $configure_result])
}
