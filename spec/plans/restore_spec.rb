# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require 'spec_helper'

describe 'peadm::restore' do
  include BoltSpec::Plans

  backup_dir = '/input/file'
  backup_tarball = "#{backup_dir}.tar.gz"

  let(:recovery_params) do
    {
      'targets'      => 'primary',
      'input_file'   => backup_tarball,
      'restore_type' => 'recovery'
    }
  end
  let(:recovery_db_params) do
    {
      'targets'      => 'primary',
      'input_file'   => backup_tarball,
      'restore_type' => 'recovery-db'
    }
  end
  let(:all_recovery_options) do
    {
      'targets' => 'primary',
      'input_file'   => backup_tarball,
      'restore_type' => 'custom', # defaults to all
    }
  end
  let(:classifier_only_params) do
    {
      'targets' => 'primary',
      'input_file'   => backup_tarball,
      'restore_type' => 'custom',
      'restore' => {
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

  let(:pe_version) { '2023.7.0' }
  let(:cluster) do
    {
      'pe_version' => pe_version,
      'params' => {
        'primary_host'            => 'primary',
        'primary_postgresql_host' => 'postgres',
      },
    }
  end

  before(:each) do
    allow_apply

    expect_out_message.with_params('cluster: ' + cluster.to_s.delete('"').gsub(%r{=>}, ' => '))
    expect_out_message.with_params('# Restoring ldap secret key if it exists')
    allow_task('peadm::puppet_runonce')
  end

  # only run for tests that have the :valid_cluster tag
  before(:each, valid_cluster: true) do
    expect_task('peadm::get_peadm_config').always_return(cluster)
  end

  def expect_restore_for_db(name, server)
    database = "pe-#{name}"
    expect_out_message.with_params("# Restoring database #{database}")

    expect_command(%(su - pe-postgres -s /bin/bash -c   "/opt/puppetlabs/server/bin/psql      --tuples-only      -d '#{database}'      -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'"\n)).be_called_times(2)
    expect_command(%(su - pe-postgres -s /bin/bash -c   "/opt/puppetlabs/server/bin/psql      -d '#{database}'      -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"\n))
    expect_command(%(su - pe-postgres -s /bin/bash -c   "/opt/puppetlabs/server/bin/psql      -d '#{database}'      -c 'ALTER USER \\"#{database}\\" WITH SUPERUSER;'"\n))
    expect_command(%(/opt/puppetlabs/server/bin/pg_restore   -j 4   -d "sslmode=verify-ca       host=#{server}       sslcert=/etc/puppetlabs/puppetdb/ssl/primary.cert.pem       sslkey=/etc/puppetlabs/puppetdb/ssl/primary.private_key.pem       sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem       dbname=#{database}       user=#{database}"   -Fd /input/file/#{name}/#{database}.dump.d\n))
    expect_command(%(su - pe-postgres -s /bin/bash -c   "/opt/puppetlabs/server/bin/psql      -d '#{database}'      -c 'ALTER USER \\"#{database}\\" WITH NOSUPERUSER;'"\n))
    expect_command(%(su - pe-postgres -s /bin/bash -c   "/opt/puppetlabs/server/bin/psql      -d '#{database}'      -c 'DROP EXTENSION IF EXISTS pglogical CASCADE;'"\n))
  end

  it 'runs with recovery params', valid_cluster: true do
    expect_out_message.with_params('# Restoring ca, certs, code and config for recovery')

    expect_command("umask 0077   && cd /input   && tar -xzf /input/file.tar.gz\n")
    expect_command("/opt/puppetlabs/bin/puppet-backup restore   --scope=certs,code,config   --tempdir=/input/file   --force   /input/file/recovery/pe_backup-*tgz\n")
    expect_command("systemctl stop pe-console-services pe-nginx pxp-agent pe-puppetserver                pe-orchestration-services puppet pe-puppetdb\n")
    expect_command("test -f /input/file/rbac/keys.json   && cp -rp /input/file/keys.json /etc/puppetlabs/console-services/conf.d/secrets/   || echo secret ldap key doesnt exist\n")
    expect_restore_for_db('puppetdb', 'postgres')
    expect_command("/opt/puppetlabs/bin/puppet-infrastructure configure --no-recover\n")

    expect(run_plan('peadm::restore', recovery_params)).to be_ok
  end

  it 'runs with default recovery', valid_cluster: true do
    allow_any_command

    expect_out_message.with_params('# Restoring database pe-puppetdb')
    expect_out_message.with_params('# Restoring ca, certs, code and config for recovery')

    expect(run_plan('peadm::restore', { 'targets' => 'primary', 'input_file' => backup_tarball })).to be_ok
  end

  it 'runs with recovery-db params', valid_cluster: true do
    allow_any_command

    expect_out_message.with_params('# Restoring primary database for recovery')
    expect_out_message.with_params('# Restoring database pe-puppetdb')

    expect(run_plan('peadm::restore', recovery_db_params)).to be_ok
  end

  it 'runs with classifier-only params', valid_cluster: true do
    allow_any_command

    expect_task('peadm::restore_classification').with_params({
                                                               'classification_file' => "#{backup_dir}/classifier/classification_backup.json"
                                                             })

    expect(run_plan('peadm::restore', classifier_only_params)).to be_ok
  end

  def expect_peadm_config_fallback(backup_dir, file)
    # simulate a failure to get the cluster configuration
    expect_task('peadm::get_peadm_config').always_return({})
    expect_out_message.with_params('Failed to get cluster configuration, loading from backup...')

    # download mocked to return the path to a fixtures file
    expect_download("#{backup_dir}/peadm/peadm_config.json").return do |targets, _source, _destination, _params|
      results = targets.map do |target|
        Bolt::Result.new(target, value: { 'path' => File.expand_path(File.join(fixtures, file)) })
      end

      Bolt::ResultSet.new(results)
    end
  end

  it 'runs with recovery params, no valid cluster', valid_cluster: false do
    allow_any_command

    expect_peadm_config_fallback(backup_dir, 'peadm_config.json')

    expect(run_plan('peadm::restore', recovery_params)).to be_ok
  end

  shared_context('all 2023.6.0 backups') do
    before(:each) do
      expect_out_message.with_params('# Restoring ca and ssl certificates')
      expect_out_message.with_params('# Restoring code')
      expect_out_message.with_params('# Restoring config')

      expect_command("umask 0077   && cd /input   && tar -xzf /input/file.tar.gz\n")
      expect_task('peadm::restore_classification').with_params(
        {
          'classification_file' => "#{backup_dir}/classifier/classification_backup.json",
        },
      )
      expect_command("/opt/puppetlabs/bin/puppet-backup restore   --scope=certs   --tempdir=/input/file   --force   /input/file/ca/pe_backup-*tgz\n")
      expect_command("/opt/puppetlabs/bin/puppet-backup restore   --scope=code   --tempdir=/input/file   --force   /input/file/code/pe_backup-*tgz\n")
      expect_command("/opt/puppetlabs/bin/puppet-backup restore   --scope=config   --tempdir=/input/file   --force   /input/file/config/pe_backup-*tgz\n")
      expect_command("systemctl stop pe-console-services pe-nginx pxp-agent pe-puppetserver                pe-orchestration-services puppet pe-puppetdb\n")
      expect_command("cp -rp /input/file/orchestrator/secrets/* /etc/puppetlabs/orchestration-services/conf.d/secrets/\n")
      expect_command("test -f /input/file/rbac/keys.json   && cp -rp /input/file/keys.json /etc/puppetlabs/console-services/conf.d/secrets/   || echo secret ldap key doesnt exist\n")
      expect_restore_for_db('activity', 'primary')
      expect_restore_for_db('orchestrator', 'primary')
      expect_restore_for_db('puppetdb', 'postgres')
      expect_restore_for_db('rbac', 'primary')
      expect_command("/opt/puppetlabs/bin/puppet-infrastructure configure --no-recover\n")
    end
  end

  context '>= 2025.0.0' do
    let(:pe_version) { '2025.0.0' }

    include_context('all 2023.6.0 backups')

    it 'runs with backup type custom, all params set to true', valid_cluster: true do
      expect_restore_for_db('hac', 'primary')
      expect_restore_for_db('patching', 'primary')

      expect(run_plan('peadm::restore', all_recovery_options)).to be_ok
    end
  end

  context '>= 2023.7.0 < 2025.0' do
    let(:pe_version) { '2023.7.0' }

    include_context('all 2023.6.0 backups')

    it 'runs with backup type custom, all params set to true', valid_cluster: true do
      expect_restore_for_db('hac', 'primary')

      expect(run_plan('peadm::restore', all_recovery_options)).to be_ok
    end
  end

  context '< 2023.7.0' do
    let(:pe_version) { '2023.6.0' }

    include_context('all 2023.6.0 backups')

    it 'ignores hac', valid_cluster: true do
      expect(run_plan('peadm::restore', all_recovery_options)).to be_ok
    end
  end

  # restoring an older backup that does not have the pe_version in it
  context 'no valid cluster, pe_version missing from recovery params (older backup)' do
    let(:cluster) do
      {
        'params' => {
          'primary_host'            => 'primary',
          'primary_postgresql_host' => 'postgres',
        },
      }
    end

    include_context('all 2023.6.0 backups')

    it 'warns that hac is ignored', valid_cluster: false do
      expect_out_message.with_params(<<~MSG.strip)
        WARNING: Retrieved a missing or unparseable PE version of ''.
        Newer service databases released in 2023.7+ will be skipped from defaults.
        (host-action-collector, patching)
      MSG

      expect_peadm_config_fallback(backup_dir, 'peadm_config.no_pe_version.json')

      expect(run_plan('peadm::restore', all_recovery_options)).to be_ok
    end
  end
end
