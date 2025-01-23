require 'spec_helper'

describe 'peadm::recovery_opts_all' do
  it 'returns pre 2023.7 defaults' do
    is_expected.to run.with_params('2023.6.0').and_return(
      {
        'activity'     => true,
        'ca'           => true,
        'classifier'   => true,
        'code'         => true,
        'config'       => true,
        'orchestrator' => true,
        'puppetdb'     => true,
        'rbac'         => true,
      },
    )
  end

  it 'returns 2023.7+ defaults with hac' do
    is_expected.to run.with_params('2023.7.0').and_return(
      {
        'activity'     => true,
        'ca'           => true,
        'classifier'   => true,
        'code'         => true,
        'config'       => true,
        'orchestrator' => true,
        'puppetdb'     => true,
        'rbac'         => true,
        'hac'          => true,
      },
    )
  end

  it 'returns 2023.7+ defaults with hac if >2023.7 <2025.0' do
    is_expected.to run.with_params('2024.9999.0').and_return(
      {
        'activity'     => true,
        'ca'           => true,
        'classifier'   => true,
        'code'         => true,
        'config'       => true,
        'orchestrator' => true,
        'puppetdb'     => true,
        'rbac'         => true,
        'hac'          => true,
      },
    )
  end

  it 'returns 2025.0+ defaults with hac and patching' do
    is_expected.to run.with_params('2025.0.0').and_return(
      {
        'activity'     => true,
        'ca'           => true,
        'classifier'   => true,
        'code'         => true,
        'config'       => true,
        'orchestrator' => true,
        'puppetdb'     => true,
        'rbac'         => true,
        'hac'          => true,
        'patching'     => true,
      },
    )
  end
end
