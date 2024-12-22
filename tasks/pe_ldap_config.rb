#!/opt/puppetlabs/puppet/bin/ruby
# Puppet Task Name: pe_ldap_config
#
# Update the LDAP configuration
#

require 'json'
require 'net/http'
require 'open3'

def main
  params = JSON.parse(STDIN.read)
  data = params['ldap_config']
  pe_main = params['pe_main']
  pe_version = params['pe_version']

  caf = ['/opt/puppetlabs/bin/puppet', 'config', 'print', 'localcacert']
  cafout, cafstatus = Open3.capture2(*caf)
  unless cafstatus.success?
    raise 'Could not get the CA file path.'
  end

  cert = ['/opt/puppetlabs/bin/puppet', 'config', 'print', 'hostcert']
  certout, certstatus = Open3.capture2(*cert)
  unless certstatus.success?
    raise 'Could not get the Cert file path.'
  end

  key = ['/opt/puppetlabs/bin/puppet', 'config', 'print', 'hostprivkey']
  keyout, keystatus = Open3.capture2(*key)
  unless keystatus.success?
    raise 'Could not get the Key file path.'
  end

  if Gem::Version.new(pe_version) < Gem::Version.new('2023.8.0')
    ldap_path = URI('rbac-api/v1/ds')
    uri = URI("https://#{pe_main}:4433/#{ldap_path}")
    req = Net::HTTP::Put.new(uri, 'Content-type' => 'application/json')
  else
    ldap_path = URI('rbac-api/v1/command/ldap/create')
    uri = URI("https://#{pe_main}:4433/#{ldap_path}")
    req = Net::HTTP::Post.new(uri, 'Content-type' => 'application/json')
  end

  https = Net::HTTP.new(pe_main, '4433')
  https.use_ssl = true
  https.verify_mode = OpenSSL::SSL::VERIFY_PEER
  https.ca_file = cafout.strip
  https.cert = OpenSSL::X509::Certificate.new(File.read(certout.strip))
  https.key = OpenSSL::PKey::RSA.new(File.read(keyout.strip))

  req.body = data.to_json

  resp = https.request(req)

  puts resp.body
  raise "API response code #{resp.code}" unless resp.code == '200'
end

begin
  main
rescue => e
  result = {
    '_error' => {
      'msg'     => e.message,
      'kind'    => 'RuntimeError',
      'details' => e.message,
    }
  }
  puts result.to_json
  exit(1)
end
