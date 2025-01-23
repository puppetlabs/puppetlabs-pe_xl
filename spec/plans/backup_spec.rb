# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require 'spec_helper'

describe 'peadm::backup' do
  include BoltSpec::Plans
  let(:default_params) { { 'targets' => 'primary', 'backup_type' => 'recovery' } }
  let(:classifier_only) do
    {
      'targets' => 'primary',
      'backup_type' => 'custom',
      'backup' => {
        'activity'     => false,
        'ca'           => false,
        'classifier'   => true,
        'code'         => false,
        'config'       => false,
        'orchestrator' => false,
        'puppetdb'     => false,
        'rbac'         => false,
        'hac'          => false,
        'patching'     => false,
      }
    }
  end
  let(:all_backup_options) do
    {
      'targets' => 'primary',
      'backup_type' => 'custom',
      'backup' => {} # set all to true
    }
  end
  let(:pe_version) { '2023.7.0' }
  let(:cluster) do
    {
      'pe_version' => pe_version,
      'params' => {
        'primary_host' => 'primary',
        'primary_postgresql_host' => 'postgres',
      }
    }
  end

  before(:each) do
    # define a zero timestamp
    mocktime = Puppet::Pops::Time::Timestamp.new(0)
    # mock the timestamp to always return the zero timestamp
    # so the directory name is always the same - /tmp/pe-backup-1970-01-01T000000Z
    allow(Puppet::Pops::Time::Timestamp).to receive(:now).and_return(mocktime)

    allow_apply

    expect_task('peadm::get_peadm_config').always_return(cluster)
  end

  it 'runs with backup type recovery' do
    expect_out_message.with_params('# Backing up ca, certs, code and config for recovery')
    expect_out_message.with_params('# Backing up database pe-puppetdb')

    expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/tmp/pe-backup-1970-01-01T000000Z/recovery --scope=certs,code,config\n")
    expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/puppetdb/pe-puppetdb.dump.d   "sslmode=verify-ca    host=postgres    user=pe-puppetdb    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-puppetdb"' + "\n")
    expect_command('umask 0077   && cd /tmp   && tar -czf /tmp/pe-backup-1970-01-01T000000Z.tar.gz pe-backup-1970-01-01T000000Z   && rm -rf /tmp/pe-backup-1970-01-01T000000Z' + "\n")

    expect(run_plan('peadm::backup', default_params)).to be_ok
  end

  it 'runs with backup type recovery by default' do
    expect_out_message.with_params('# Backing up ca, certs, code and config for recovery')
    expect_out_message.with_params('# Backing up database pe-puppetdb')

    expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/tmp/pe-backup-1970-01-01T000000Z/recovery --scope=certs,code,config\n")
    expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/puppetdb/pe-puppetdb.dump.d   "sslmode=verify-ca    host=postgres    user=pe-puppetdb    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-puppetdb"' + "\n")
    expect_command('umask 0077   && cd /tmp   && tar -czf /tmp/pe-backup-1970-01-01T000000Z.tar.gz pe-backup-1970-01-01T000000Z   && rm -rf /tmp/pe-backup-1970-01-01T000000Z' + "\n")

    expect(run_plan('peadm::backup', { 'targets' => 'primary' })).to be_ok
  end

  it 'runs with backup and defined output folder' do
    expect_out_message.with_params('# Backing up ca, certs, code and config for recovery')
    expect_out_message.with_params('# Backing up database pe-puppetdb')

    expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/user/home/folder/pe-backup-1970-01-01T000000Z/recovery --scope=certs,code,config\n")
    expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /user/home/folder/pe-backup-1970-01-01T000000Z/puppetdb/pe-puppetdb.dump.d   "sslmode=verify-ca    host=postgres    user=pe-puppetdb    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-puppetdb"' + "\n")
    expect_command('umask 0077   && cd /user/home/folder   && tar -czf /user/home/folder/pe-backup-1970-01-01T000000Z.tar.gz pe-backup-1970-01-01T000000Z   && rm -rf /user/home/folder/pe-backup-1970-01-01T000000Z' + "\n")

    expect(run_plan('peadm::backup', { 'targets' => 'primary', 'output_directory' => '/user/home/folder' })).to be_ok
  end

  it 'runs with backup type custom, classifier only' do
    expect_task('peadm::backup_classification').with_params({ 'directory' => '/tmp/pe-backup-1970-01-01T000000Z/classifier' })
    expect_out_message.with_params('# Backing up classification')
    expect_command('umask 0077   && cd /tmp   && tar -czf /tmp/pe-backup-1970-01-01T000000Z.tar.gz pe-backup-1970-01-01T000000Z   && rm -rf /tmp/pe-backup-1970-01-01T000000Z' + "\n")

    expect(run_plan('peadm::backup', classifier_only)).to be_ok
  end

  shared_context('all 2023.6.0 backups') do
    before(:each) do
      expect_task('peadm::backup_classification').with_params({ 'directory' => '/tmp/pe-backup-1970-01-01T000000Z/classifier' })

      expect_out_message.with_params('# Backing up classification')
      expect_out_message.with_params('# Backing up database pe-orchestrator')
      expect_out_message.with_params('# Backing up database pe-activity')
      expect_out_message.with_params('# Backing up database pe-rbac')
      expect_out_message.with_params('# Backing up database pe-puppetdb')

      expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/tmp/pe-backup-1970-01-01T000000Z/ca --scope=certs\n")
      expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/tmp/pe-backup-1970-01-01T000000Z/code --scope=code\n")
      expect_command('chown pe-postgres /tmp/pe-backup-1970-01-01T000000Z/config')
      expect_command("/opt/puppetlabs/bin/puppet-backup create --dir=/tmp/pe-backup-1970-01-01T000000Z/config --scope=config\n")
      expect_command("test -f /etc/puppetlabs/console-services/conf.d/secrets/keys.json   && cp -rp /etc/puppetlabs/console-services/conf.d/secrets /tmp/pe-backup-1970-01-01T000000Z/rbac/   || echo secret ldap key doesnt exist\n")
      expect_command("cp -rp /etc/puppetlabs/orchestration-services/conf.d/secrets /tmp/pe-backup-1970-01-01T000000Z/orchestrator/\n")
      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/orchestrator/pe-orchestrator.dump.d   "sslmode=verify-ca    host=primary    user=pe-orchestrator    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-orchestrator"' + "\n")
      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/activity/pe-activity.dump.d   "sslmode=verify-ca    host=primary    user=pe-activity    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-activity"' + "\n")
      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/rbac/pe-rbac.dump.d   "sslmode=verify-ca    host=primary    user=pe-rbac    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-rbac"' + "\n")
      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/puppetdb/pe-puppetdb.dump.d   "sslmode=verify-ca    host=postgres    user=pe-puppetdb    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-puppetdb"' + "\n")
      expect_command('umask 0077   && cd /tmp   && tar -czf /tmp/pe-backup-1970-01-01T000000Z.tar.gz pe-backup-1970-01-01T000000Z   && rm -rf /tmp/pe-backup-1970-01-01T000000Z' + "\n")
    end
  end

  context '>= 2025.0.0' do
    let(:pe_version) { '2025.0.0' }

    include_context('all 2023.6.0 backups')

    it 'runs with backup type custom, all backup params set to true' do
      expect_out_message.with_params('# Backing up database pe-hac')
      expect_out_message.with_params('# Backing up database pe-patching')

      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/hac/pe-hac.dump.d   "sslmode=verify-ca    host=primary    user=pe-hac    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-hac"' + "\n")
      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/patching/pe-patching.dump.d   "sslmode=verify-ca    host=primary    user=pe-patching    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-patching"' + "\n")

      expect(run_plan('peadm::backup', all_backup_options)).to be_ok
    end
  end

  context '>= 2023.7.0 < 2025.0' do
    let(:pe_version) { '2023.7.0' }

    include_context('all 2023.6.0 backups')

    it 'runs with backup type custom, all backup params set to true' do
      expect_out_message.with_params('# Backing up database pe-hac')

      expect_command('/opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4   -f /tmp/pe-backup-1970-01-01T000000Z/hac/pe-hac.dump.d   "sslmode=verify-ca    host=primary    user=pe-hac    sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem    sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem    sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem    dbname=pe-hac"' + "\n")

      expect(run_plan('peadm::backup', all_backup_options)).to be_ok
    end
  end

  context '< 2023.7.0' do
    let(:pe_version) { '2023.6.0' }

    include_context('all 2023.6.0 backups')

    it 'ignores hac' do
      expect(run_plan('peadm::backup', all_backup_options)).to be_ok
    end
  end

  context 'pe_version unknown' do
    let(:pe_version) { nil }

    include_context('all 2023.6.0 backups')

    it 'warns that hac is ignored' do
      expect_out_message.with_params(<<~MSG.strip)
        WARNING: Retrieved a missing or unparseable PE version of ''.
        Newer service databases released in 2023.7+ will be skipped from defaults.
        (host-action-collector, patching)
      MSG

      expect(run_plan('peadm::backup', all_backup_options)).to be_ok
    end
  end
end
