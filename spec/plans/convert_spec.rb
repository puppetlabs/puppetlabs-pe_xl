require 'spec_helper'

describe 'peadm::convert' do
  # Include the BoltSpec library functions
  include BoltSpec::Plans

  let(:trustedjson) do
    JSON.parse File.read(File.expand_path(File.join(fixtures, 'plans', 'trusted_facts.json')))
  end

  let(:params) do
    { 'primary_host' => 'primary', 'legacy_compilers' => ['pe_compiler_legacy'] }
  end

  it 'single primary no dr valid' do
    allow_out_message
    allow_any_command
    allow_any_task
    allow_apply

    expect_task('peadm::cert_data').return_for_targets('primary' => trustedjson)
    expect_task('peadm::read_file').always_return({ 'content' => '2021.7.9' })
    expect_task('peadm::get_group_rules').return_for_targets('primary' => { '_output' => '{"rules": []}' })
    expect_task('peadm::node_group_unpin').with_targets('primary').with_params({ 'node_certnames' => ['pe_compiler_legacy'], 'group_name' => 'PE Master' })
    expect_task('peadm::check_legacy_compilers').with_targets('primary').with_params({ 'legacy_compilers' => 'pe_compiler_legacy' }).return_for_targets('primary' => { '_output' => '' })

    # For some reason, expect_plan() was not working??
    allow_plan('peadm::modify_certificate').always_return({})

    expect(run_plan('peadm::convert', params)).to be_ok
  end
end
