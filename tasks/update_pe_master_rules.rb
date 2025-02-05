#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require 'net/https'
require 'puppet'

# UpdatePeMasterRules task class
class UpdatePeMasterRules
  def initialize(params)
    @params = params
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

  def get_pe_master_group_id
    net = https_client
    res = net.get('/classifier-api/v1/groups')

    unless res.code == '200'
      raise "Failed to fetch groups: HTTP #{res.code} - #{res.body}"
    end

    groups = JSON.parse(res.body)
    pe_master_group = groups.find { |group| group['name'] == 'PE Master' }
    
    raise "Could not find PE Master group" unless pe_master_group
    pe_master_group['id']
  rescue JSON::ParserError => e
    raise "Invalid JSON response from server: #{e.message}"
  rescue StandardError => e
    raise "Error fetching PE Master group ID: #{e.message}"
  end

  def get_current_rules(group_id)
    net = https_client
    url = "/classifier-api/v1/groups/#{group_id}/rules"
    req = Net::HTTP::Get.new(url)
    res = net.request(req)

    unless res.code == '200'
      raise "Failed to fetch rules: HTTP #{res.code} - #{res.body}"
    end

    JSON.parse(res.body)['rule']
  rescue JSON::ParserError => e
    raise "Invalid JSON response from server: #{e.message}"
  rescue StandardError => e
    raise "Error fetching rules: #{e.message}"
  end

  def transform_rule(rule)
    return rule unless rule.is_a?(Array)
    
    if rule[0] == '=' && 
       rule[1].is_a?(Array) && 
       rule[1] == ['trusted', 'extensions', 'pp_auth_role'] && 
       rule[2] == 'pe_compiler'
      return ['~', ['trusted', 'extensions', 'pp_auth_role'], '^pe_compiler(?:_legacy)?$']
    end
    
    # Recursively transform nested rules
    rule.map { |element| transform_rule(element) }
  end

  def update_rules(group_id)
    net = https_client
    begin
      current_rules = get_current_rules(group_id)
      
      # Transform rules recursively to handle nested structures
      new_rules = transform_rule(current_rules)
      
      # Update the group with the modified rules
      url = "/classifier-api/v1/groups/#{group_id}"
      req = Net::HTTP::Post.new(url)
      req['Content-Type'] = 'application/json'
      req.body = { rule: new_rules }.to_json

      res = net.request(req)

      case res.code
      when '200', '201', '204'
        puts "Successfully transformed pe_compiler rule to use regex match for *_compiler roles in group #{group_id}"
      else
        begin
          error_body = JSON.parse(res.body.to_s)
          raise "Failed to update rules: #{error_body['kind'] || error_body}"
        rescue JSON::ParserError
          raise "Invalid response from server (status #{res.code}): #{res.body}"
        end
      end
    rescue StandardError => e
      raise "Error during rules update: #{e.message}"
    end
  end

  def execute!
    group_id = get_pe_master_group_id
    update_rules(group_id)
  end
end

# Run the task unless an environment flag has been set
unless ENV['RSPEC_UNIT_TEST_MODE']
  Puppet.initialize_settings
  task = UpdatePeMasterRules.new(JSON.parse(STDIN.read))
  task.execute!
end 