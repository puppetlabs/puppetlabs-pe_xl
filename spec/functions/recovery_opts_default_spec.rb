require 'spec_helper'

describe 'peadm::recovery_opts_default' do
  it 'returns pre 2023.7 defaults' do
    is_expected.to run.with_params('2023.6.0').and_return(
      {
        'activity'     => false,
        'ca'           => true,
        'classifier'   => false,
        'code'         => true,
        'config'       => true,
        'orchestrator' => false,
        'puppetdb'     => true,
        'rbac'         => false,
      },
    )
  end

  it 'returns 2023.7+ defaults with hac' do
    is_expected.to run.with_params('2023.7.0').and_return(
      {
        'activity'     => false,
        'ca'           => true,
        'classifier'   => false,
        'code'         => true,
        'config'       => true,
        'orchestrator' => false,
        'puppetdb'     => true,
        'rbac'         => false,
        'hac'          => false,
      },
    )
  end

  it 'returns 2025.0+ defaults with hac and patching' do
    is_expected.to run.with_params('2025.0.0').and_return(
      {
        'activity'     => false,
        'ca'           => true,
        'classifier'   => false,
        'code'         => true,
        'config'       => true,
        'orchestrator' => false,
        'puppetdb'     => true,
        'rbac'         => false,
        'hac'          => false,
        'patching'     => false,
      },
    )
  end
end
