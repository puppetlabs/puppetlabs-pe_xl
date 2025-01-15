#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'net/https'
require 'puppet'

# NodeGroupUnpin task class
class NodeGroupUnpin
  def initialize(params)
    @params = params
    raise "Missing required parameter 'node_certname'" unless @params['node_certname']
    raise "Missing required parameter 'group_name'" unless @params['group_name']
    @auth = YAML.load_file('/etc/puppetlabs/puppet/classifier.yaml')
  rescue Errno::ENOENT
    raise 'Could not find classifier.yaml at /etc/puppetlabs/puppet/classifier.yaml'
  end

  def https_client
    client = Net::HTTP.new(Puppet.settings[:certname], 4433)
    client.use_ssl = true
    client.cert = @cert ||= OpenSSL::X509::Certificate.new(File.read(Puppet.settings[:hostcert]))
    client.key = @key ||= OpenSSL::PKey::RSA.new(File.read(Puppet.settings[:hostprivkey]))
    client.verify_mode = OpenSSL::SSL::VERIFY_PEER
    client.ca_file = Puppet.settings[:localcacert]
    client
  end

  def groups
    @groups ||= begin
      net = https_client
      res = net.get('/classifier-api/v1/groups')

      unless res.code == '200'
        raise "Failed to fetch groups: HTTP #{res.code} - #{res.body}"
      end

      NodeGroup.new(JSON.parse(res.body))
                rescue JSON::ParserError => e
                  raise "Invalid JSON response from server: #{e.message}"
                rescue StandardError => e
                  raise "Error fetching groups: #{e.message}"
    end
  end

  def unpin_node(group, node)
    raise 'Invalid group object' unless group.is_a?(Hash) && group['id'] && group['name']

    net = https_client
    begin
      data = { "nodes": [node] }.to_json
      url = "/classifier-api/v1/groups/#{group['id']}/unpin"

      req = Net::HTTP::Post.new(url)
      req['Content-Type'] = 'application/json'
      req.body = data

      res = net.request(req)

      case res.code
      when '204'
        puts "Successfully unpinned node '#{node}' from group '#{group['name']}'"
      else
        begin
          error_body = JSON.parse(res.body.to_s)
          raise "Failed to unpin node: #{error_body['kind'] || error_body}"
        rescue JSON::ParserError
          raise "Invalid response from server (status #{res.code}): #{res.body}"
        end
      end
    rescue StandardError => e
      raise "Error during unpin request: #{e.message}"
    end
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
  end

  def execute!
    group_name = @params['group_name']
    node_certname = @params['node_certname']
    group = groups.dig(group_name)
    if group
      unpin_node(group, node_certname)
      puts "Unpinned #{node_certname} from #{group_name}"
    else
      puts "Group #{group_name} not found"
    end
  end
end

# Run the task unless an environment flag has been set
unless ENV['RSPEC_UNIT_TEST_MODE']
  Puppet.initialize_settings
  task = NodeGroupUnpin.new(JSON.parse(STDIN.read))
  task.execute!
end
