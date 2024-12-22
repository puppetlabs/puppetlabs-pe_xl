require 'spec_helper'

describe 'peadm::install' do
  include BoltSpec::Plans

  describe 'basic functionality' do
    it 'runs successfully with the minimum required parameters' do
      allow_out_message
      expect_plan('peadm::subplans::install')
      expect_plan('peadm::subplans::configure')
      expect(run_plan('peadm::install', 'primary_host' => 'primary', 'console_password' => 'puppetLabs123!', 'version' => '2021.7.9')).to be_ok
    end
  end
end
