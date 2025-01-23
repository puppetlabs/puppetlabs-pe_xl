require 'spec_helper'

describe 'peadm::amend_recovery_defaults_by_pe_version' do
  it 'just returns the base opts if version < 2023.7' do
    is_expected.to run.with_params({}, '2023.6.0', true).and_return({})
  end

  it 'adds hac if version >= 2023.7' do
    is_expected.to run.with_params({}, '2023.7.0', true).and_return({ 'hac' => true })
  end

  it 'adds hac false based on opt_value' do
    is_expected.to run.with_params({}, '2023.7.0', false).and_return({ 'hac' => false })
  end
end
