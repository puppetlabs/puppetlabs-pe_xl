require 'spec_helper'

describe 'peadm::util::retrieve_and_upload' do
  # Include the BoltSpec library functions
  include BoltSpec::Plans

  it 'file needs downloaded and needs uploaded' do
    allow_task('facts').be_called_times(1).with_targets('local://localhost').always_return({ 'os' => { 'family' => 'RedHat' } })
    expect_command("test -e '/tmp/download'").error_with('kind' => 'nope', 'msg' => 'The command failed with exit code 1')
    expect_task('peadm::download')
    expect_task('peadm::filesize').be_called_times(2).return_for_targets(
      'local://localhost' => { 'size' => '2' },
      'primary' => { 'size' => 'null' },
    )

    #########
    ## <🤮>
    # rubocop:disable AnyInstance
    allow(Pathname).to receive(:new).and_call_original
    allow(Puppet::FileSystem).to receive(:exist?).and_call_original
    allow_any_instance_of(BoltSpec::Plans::MockExecutor).to receive(:module_file_id).and_call_original

    mockpath = instance_double('Pathname', absolute?: true)
    allow(Pathname).to receive(:new).with('/tmp/download').and_return(mockpath)
    allow(Puppet::FileSystem).to receive(:exist?).with('/tmp/download').and_return(true)
    allow_any_instance_of(BoltSpec::Plans::MockExecutor).to(receive(:module_file_id))
                                                        .with('/tmp/download')
                                                        .and_return('/tmp/download')

    expect_upload('/tmp/download')
      .with_destination('/tmp/upload')
      .return do |targets:, source:, destination:, **_kwargs|
        results = targets.map do |target|
          Bolt::Result.new(target, value: { 'path' => File.join(destination, source) })
        end
        Bolt::ResultSet.new(results)
      end

    # rubocop:enable AnyInstance
    ## </🤮>
    ##########

    expect(run_plan('peadm::util::retrieve_and_upload', 'nodes' => 'primary', 'source' => '/tmp/source', 'upload_path' => '/tmp/upload', 'local_path' => '/tmp/download')).to be_ok
  end

  it 'fails when nodes are configured to use the pcp transport' do
    result = run_plan('peadm::util::retrieve_and_upload',
                      { 'nodes'       => ['pcp://node.example'],
                        'source'      => '/tmp/source',
                        'upload_path' => '/tmp/upload',
                        'local_path'  => '/tmp/download' })

    expect(result).not_to be_ok
    expect(result.value.kind).to eq('unexpected-transport')
    expect(result.value.msg).to match(%r{The "pcp" transport is not available for uploading PE installers})
  end
end
