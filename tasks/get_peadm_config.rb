#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'
require 'puppet'

# GetPEAdmConfig task class
class GetPEAdmConfig
  def initialize(params); end

  def execute!
    # if there is no 'PE Primary A' node group, it's not a peadm-configured cluster.
    peadm_primary_a_group = groups.data.find { |obj| obj['name'] == 'PE Primary A' }
    if peadm_primary_a_group
      puts config.to_json
    else
      puts({ 'error' => 'This is not a peadm-compatible cluster. Use peadm::convert first.' }).to_json
    end
  end

  def config
    # Compute values
    primary = groups.pinned('PE Certificate Authority')
    replica = groups.pinned('PE HA Replica')
    server_a = server('puppet/server', 'A', [primary, replica].compact)
    server_b = server('puppet/server', 'B', [primary, replica].compact)
    primary_letter = primary.eql?(server_a) ? 'A' : 'B'
    replica_letter = primary_letter.eql?('A') ? 'B' : 'A'

    configured_postgresql_servers = [
      groups.dig('PE Primary A', 'config_data', 'puppet_enterprise::profile::puppetdb', 'database_host'),
      groups.dig('PE Primary B', 'config_data', 'puppet_enterprise::profile::puppetdb', 'database_host'),
    ].compact

    postgresql = {
      'A' => server('puppet/puppetdb-database', 'A', configured_postgresql_servers),
      'B' => server('puppet/puppetdb-database', 'B', configured_postgresql_servers),
    }

    # Build and return the task output
    {
      'pe_version' => pe_version,
      'params' => {
        'primary_host' => primary,
        'replica_host' => replica,
        'primary_postgresql_host' => postgresql[primary_letter],
        'replica_postgresql_host' => postgresql[replica_letter],
        'compilers' => compilers.map { |c| c['certname'] },
        'legacy_compilers' => legacy_compilers.map { |c| c['certname'] },
        'compiler_pool_address' => groups.dig('PE Master', 'config_data', 'pe_repo', 'compile_master_pool_address'),
        'internal_compiler_a_pool_address' => groups.dig('PE Compiler Group B', 'classes', 'puppet_enterprise::profile::master', 'puppetdb_host', 1),
        'internal_compiler_b_pool_address' => groups.dig('PE Compiler Group A', 'classes', 'puppet_enterprise::profile::master', 'puppetdb_host', 1),
      },
      'role-letter' => {
        'server' => {
          'A' => server_a,
          'B' => server_b,
        },
        'postgresql' => {
          'A' => postgresql['A'],
          'B' => postgresql['B'],
        },
        'compilers' => {
          'A' => compilers.select { |c| c['letter'] == 'A' }.map { |c| c['certname'] },
          'B' => compilers.select { |c| c['letter'] == 'B' }.map { |c| c['certname'] },
        },
        'legacy_compilers' => {
          'A' => legacy_compilers.select { |c| c['letter'] == 'A' }.map { |c| c['certname'] },
          'B' => legacy_compilers.select { |c| c['letter'] == 'B' }.map { |c| c['certname'] },
        },
      },
    }
  end

  # @return [String] Local PE version string.
  def pe_version
    pe_build_file = '/opt/puppetlabs/server/pe_build'
    File.read(pe_build_file).strip if File.exist?(pe_build_file)
  end

  # Returns a GetPEAdmConfig::NodeGroups object created from the /groups object
  # returned by the classifier
  def groups
    @groups ||= begin
      net = https(4433)
      res = net.get('/classifier-api/v1/groups')
      NodeGroup.new(JSON.parse(res.body))
    end
  end

  # Returns a list of compiler certnames and letters, based on a PuppetDB query
  def compilers
    @compilers ||=
      pdb_query('inventory[certname,trusted.extensions] {
            trusted.extensions.pp_auth_role = "pe_compiler"
          }').map do |c|
        {
          'certname' => c['certname'],
          'letter'   => c.dig('trusted.extensions', '1.3.6.1.4.1.34380.1.1.9813'),
        }
      end
  end

  # Returns a list of legacy compiler certnames and letters, based on a PuppetDB query
  def legacy_compilers
    @legacy_compilers ||=
      pdb_query('inventory[certname,trusted.extensions] {
          trusted.extensions.pp_auth_role = "legacy_compiler"
        }').map do |c|
        {
          'certname' => c['certname'],
          'letter'   => c.dig('trusted.extensions', '1.3.6.1.4.1.34380.1.1.9813'),
        }
      end
  end

  def server(role, letter, certname_array)
    query = 'inventory[certname] { '\
            '  trusted.extensions."1.3.6.1.4.1.34380.1.1.9812" = "' + role + '" and ' \
            '  trusted.extensions."1.3.6.1.4.1.34380.1.1.9813" = "' + letter + '" and ' \
            '  certname in ' + certname_array.to_json + '}'

    server = pdb_query(query).map { |n| n['certname'] }
    raise "More than one #{letter} #{role} server found!" unless server.size <= 1
    server.first
  end

  def https(port)
    https = Net::HTTP.new(Puppet.settings[:certname], port)
    https.use_ssl = true
    https.cert = @cert ||= OpenSSL::X509::Certificate.new(File.read(Puppet.settings[:hostcert]))
    https.key = @key ||= OpenSSL::PKey::RSA.new(File.read(Puppet.settings[:hostprivkey]))
    https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    https.ca_file = Puppet.settings[:localcacert]
    https
  end

  def pdb_query(query)
    pdb = https(8081)
    pdb_request = Net::HTTP::Get.new('/pdb/query/v4')
    pdb_request.set_form_data({ 'query' => query })
    JSON.parse(pdb.request(pdb_request).body)
  end

  # Utility class to aid in retrieving useful information from the node group
  # data
  class NodeGroup
    attr_reader :data

    def initialize(data)
      @data = data
    end

    # Aids in digging into node groups by name, rather than UUID
    def dig(name, *args)
      group = @data.find { |obj| obj['name'] == name }
      if group.nil?
        nil
      elsif args.empty?
        group
      else
        group.dig(*args)
      end
    end

    # Return the node pinned to the named group
    # If there is more than one node, error
    def pinned(name)
      rule = dig(name, 'rule')
      return nil if rule.nil?
      raise "#{name} rule incompatible with pinning" unless rule.first == 'or'
      pinned = rule.drop(1)
                   .select { |r| r[0] == '=' && r[1] == 'name' }
                   .map { |r| r[2] }
      raise "#{name} contains more than one server!" unless pinned.size <= 1
      pinned.first
    end
  end
end

# Run the task unless an environment flag has been set, signaling not to. The
# environment flag is used to disable auto-execution and enable Ruby unit
# testing of this task.
unless ENV['RSPEC_UNIT_TEST_MODE']
  Puppet.initialize_settings
  task = GetPEAdmConfig.new(JSON.parse(STDIN.read))
  task.execute!
end
