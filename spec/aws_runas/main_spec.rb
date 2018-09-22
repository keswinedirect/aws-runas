# Copyright 2015 Chris Marchesi
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'spec_helper'
require 'aws_runas/main'

MFA_ERROR = 'No mfa_serial in selected profile, session will be useless'.freeze
AWS_DEFAULT_CFG_PATH = "#{Dir.home}/.aws/config".freeze
AWS_DEFAULT_CREDENTIALS_PATH = "#{Dir.home}/.aws/credentials".freeze
AWS_LOCAL_CFG_PATH = "#{Dir.pwd}/aws_config".freeze

describe AwsRunAs::Main do
  before(:context) do
    @main = AwsRunAs::Main.new(
      path: MOCK_AWS_CONFIGPATH,
      profile: 'test-profile',
      mfa_code: '123456'
    )
  end

  describe '#sts_client' do
    it 'returns a proper Aws::STS::Client object' do
      expect(@main.sts_client.class.name).to eq('Aws::STS::Client')
    end
  end

  describe '#user_or_access_key_id' do
    it 'returns accountID_username when caller identity is not an assumed role' do
      expect(
        @main.user_or_access_key_id(
          double(
            account: '123456789012',
            arn: 'arn:aws:iam::123456789012:user/Alice',
            user_id: 'AKIAI44QH8DHBEXAMPLE'
          )
        )
      ).to eq('123456789012_Alice')
    end

    it 'returns the access key ID when caller identity is an assumed role' do
      expect(
        @main.user_or_access_key_id(
          double(
            account: '123456789012',
            arn: 'arn:aws:sts::123456789012:assumed-role/AliceAdmins/AliceSession',
            user_id: 'AKIAI44QH8DHBEXAMPLE:AliceSession'
          )
        )
      ).to eq('AKIAI44QH8DHBEXAMPLE')
    end
  end

  describe '#session_id' do
    it 'returns a properly formatted AWS session name for assuming roles' do
      allow_any_instance_of(Aws::STS::Client).to receive(:get_caller_identity) do |obj|
        obj.stub_data(
          :get_caller_identity,
          {
            account: '123456789012',
            arn: 'arn:aws:iam::123456789012:user/Alice',
            user_id: 'AKIAI44QH8DHBEXAMPLE'
          }
        )
      end
      expect(@main.session_id).to eq("aws-runas-session_123456789012_Alice_#{Time.now.to_i}")
    end

    it 'returns a session name formatted on access key ID when user is assumed role' do
      allow_any_instance_of(Aws::STS::Client).to receive(:get_caller_identity) do |obj|
        obj.stub_data(
          :get_caller_identity,
          {
            account: '123456789012',
            arn: 'arn:aws:sts::123456789012:assumed-role/AliceAdmins/AliceSession',
            user_id: 'AKIAI44QH8DHBEXAMPLE:AliceSession'
          }
        )
      end
      expect(@main.session_id).to eq("aws-runas-session_AKIAI44QH8DHBEXAMPLE_#{Time.now.to_i}")
    end

    it 'returns a basic session ID when caller has no access to get_caller_identity' do
      allow_any_instance_of(AwsRunAs::Main).to receive(:sts_client).and_return(
        Aws::STS::Client.new(
          stub_responses: {
            get_caller_identity: 'AccessDeniedException'
          }
        )
      )
      expect(@main.session_id).to eq("aws-runas-session_#{Time.now.to_i}")
    end

    it 'returns a basic session ID if the resultant session would be longer than 64 characters' do
      allow_any_instance_of(Aws::STS::Client).to receive(:get_caller_identity) do |obj|
        obj.stub_data(
          :get_caller_identity,
          {
            account: '123456789012',
            arn: 'arn:aws:iam::123456789012:user/AliceAliceAliceAliceAliceAliceAliceAliceAliceAliceAliceAliceAlice',
            user_id: 'AKIAI44QH8DHBEXAMPLE'
          }
        )
      end
      expect(@main.session_id).to eq("aws-runas-session_#{Time.now.to_i}")
    end
  end

  describe '#assume_role' do
    it 'calls out to Aws::AssumeRoleCredentials.new' do
      expect(Aws::AssumeRoleCredentials).to receive(:new).and_call_original
      @main.assume_role
    end

    it 'calls out to Aws::AssumeRoleCredentials.new with a correct session expiration when not default' do
      expect(Aws::AssumeRoleCredentials).to receive(:new).with(hash_including(duration_seconds: 43200)).and_call_original
      @main = AwsRunAs::Main.new(
        path: MOCK_AWS_CONFIGPATH,
        profile: 'test-profile',
        mfa_code: '123456',
        duration_seconds: 43200
      )
      @main.assume_role
    end

    it 'calls out to Aws::STS::Client.get_session_token when no_role is set' do
      expect_any_instance_of(Aws::STS::Client).to receive(:get_session_token).and_call_original
      ENV.delete('AWS_SESSION_TOKEN')
      @main = AwsRunAs::Main.new(
        path: MOCK_AWS_CONFIGPATH,
        profile: 'test-profile',
        mfa_code: '123456',
        no_role: true
      )
      @main.assume_role
    end

    it 'calls out to Aws::STS::Client.get_session_token correct session expiration when not default' do
      expect_any_instance_of(Aws::STS::Client).to receive(
        :get_session_token
      ).with(
        hash_including(duration_seconds: 43200)
      ).and_call_original
      ENV.delete('AWS_SESSION_TOKEN')
      @main = AwsRunAs::Main.new(
        path: MOCK_AWS_CONFIGPATH,
        profile: 'test-profile',
        mfa_code: '123456',
        no_role: true,
        duration_seconds: 43200
      )
      @main.assume_role
    end

    it 'raises exception when no_role is set and there is no mfa_serial' do
      expect do
        ENV.delete('AWS_SESSION_TOKEN')
        @main = AwsRunAs::Main.new(
          path: MOCK_AWS_NO_MFA_PATH,
          profile: 'test-profile',
          mfa_code: '123456',
          no_role: true
        )
        @main.assume_role
      end.to raise_error(MFA_ERROR)
    end

    it 'calls out to Aws::AssumeRoleCredentials.new with no MFA when AWS_SESSION_TOKEN is set' do
      expect(Aws::AssumeRoleCredentials).to receive(:new).with(hash_including(serial_number: nil)).and_call_original
      ENV.store('AWS_SESSION_TOKEN', 'foo')
      @main.assume_role
    end

    context 'with $HOME/.aws/config (test AWS_SDK_CONFIG_OPT_OUT)' do
      before(:example) do
        Aws.config.update(stub_responses: false)
        allow(File).to receive(:exist?).with(AWS_LOCAL_CFG_PATH).and_return false
        allow(File).to receive(:exist?).with(AWS_DEFAULT_CFG_PATH).and_return true
        allow(File).to receive(:exist?).with(AWS_DEFAULT_CREDENTIALS_PATH).and_return false
        allow(File).to receive(:read).with(AWS_DEFAULT_CFG_PATH).and_return File.read(MOCK_AWS_NO_SOURCE_PATH)
        allow(IniFile).to receive(:load).with(AWS_DEFAULT_CFG_PATH).and_return IniFile.load(MOCK_AWS_NO_SOURCE_PATH)
        allow_any_instance_of(Aws::STS::Client).to receive(:get_caller_identity) do |obj|
          obj.stub_data(
            :get_caller_identity,
            {
              account: '123456789012',
              arn: 'arn:aws:iam::123456789012:user/Alice',
              user_id: 'AKIAI44QH8DHBEXAMPLE'
            }
          )
        end
        allow(Aws::AssumeRoleCredentials).to receive(:new).and_return(
          Aws::AssumeRoleCredentials.new(
            role_arn: 'roleARN',
            role_session_name: 'roleSessionName',
            stub_responses: true
          )
        )
        @main = AwsRunAs::Main.new(
          profile: 'test-profile'
        )
      end

      it 'assumes a role correctly' do
        @main.assume_role
      end
    end
  end

  describe '#credentials_env' do
    before do
      allow_any_instance_of(AwsRunAs::Main).to receive(:sts_client).and_return(
        Aws::STS::Client.new(
          stub_responses: {
            get_session_token: {
              credentials: {
                access_key_id: 'accessKeyIdType',
                secret_access_key: 'accessKeySecretType',
                session_token: 'tokenType',
                expiration: Time.utc(2017, 'jul', 10, 19, 56, 11)
              }
            }
          }
        )
      )
      allow_any_instance_of(Aws::AssumeRoleCredentials).to receive(:expiration).and_return(
        Time.utc(2017, 'jul', 10, 19, 56, 11)
      )
    end
    subject(:env) do
      ENV.delete('AWS_SESSION_TOKEN')
      main = AwsRunAs::Main.new(
        path: cfg_path,
        profile: 'test-profile',
        mfa_code: '123456',
        no_role: no_role
      )
      main.assume_role
      main.credentials_env
    end
    let(:no_role) { false }
    let(:cfg_path) { MOCK_AWS_CONFIGPATH }

    context 'with role assumed' do
      it 'returns AWS_ACCESS_KEY_ID set in env' do
        expect(env['AWS_ACCESS_KEY_ID']).to eq('accessKeyIdType')
      end
      it 'returns AWS_SECRET_ACCESS_KEY set in env' do
        expect(env['AWS_SECRET_ACCESS_KEY']).to eq('accessKeySecretType')
      end
      it 'returns AWS_SESSION_TOKEN set in env' do
        expect(env['AWS_SESSION_TOKEN']).to eq('tokenType')
      end
      it 'has AWS_RUNAS_PROFILE set to the profile in use' do
        expect(env['AWS_RUNAS_PROFILE']).to eq('test-profile')
      end
      it 'has AWS_RUNAS_ASSUMED_ROLE_ARN set to the assumed role ARN' do
        expect(env['AWS_RUNAS_ASSUMED_ROLE_ARN']).to eq('arn:aws:iam::123456789012:role/test-admin')
      end
      it 'has AWS_SESSION_EXPIRATION set in env' do
        expect(env['AWS_SESSION_EXPIRATION']).to eq('2017-07-10 19:56:11 UTC')
      end
      it 'has AWS_SESSION_EXPIRATION_UNIX set in env' do
        expect(env['AWS_SESSION_EXPIRATION_UNIX']).to eq('1499716571')
      end
      it 'has AWS_REGION set in env' do
        expect(env['AWS_REGION']).to eq('us-west-1')
      end
      it 'has AWS_DEFAULT_REGION set in env' do
        expect(env['AWS_DEFAULT_REGION']).to eq('us-west-1')
      end
      it 'has AWS_ROLE_SESSION_NAME set in env' do
        expect(env['AWS_ROLE_SESSION_NAME']).to eq("aws-runas-session_accountType_arnType_#{Time.now.to_i}")
      end
    end

    context 'with no role assumed' do
      let(:no_role) { true }

      it 'does not have AWS_RUNAS_ASSUMED_ROLE_ARN set' do
        expect(env).to_not have_key('AWS_RUNAS_ASSUMED_ROLE_ARN')
      end
      it 'has AWS_SESSION_EXPIRATION set in env' do
        expect(env['AWS_SESSION_EXPIRATION']).to eq('2017-07-10 19:56:11 UTC')
      end
      it 'has AWS_SESSION_EXPIRATION_UNIX set in env' do
        expect(env['AWS_SESSION_EXPIRATION_UNIX']).to eq('1499716571')
      end
      it 'has AWS_REGION set in env' do
        expect(env['AWS_REGION']).to eq('us-west-1')
      end
      it 'has AWS_DEFAULT_REGION set in env' do
        expect(env['AWS_DEFAULT_REGION']).to eq('us-west-1')
      end
    end

    context 'with no region in config' do
      let(:cfg_path) { MOCK_AWS_NO_REGION_PATH }

      it 'does not have AWS_REGION set in env' do
        expect(env).to_not have_key('AWS_REGION')
      end
      it 'does not have AWS_DEFAULT_REGION set in env' do
        expect(env).to_not have_key('AWS_DEFAULT_REGION')
      end
    end
  end

  describe '#handoff' do
    before(:context) do
      @env = @main.credentials_env
      ENV.store('SHELL', '/bin/sh')
    end

    it 'execs a command when a command is specified' do
      expect(@main).to receive(:exec).with(anything, '/usr/bin/foo', *['--bar', 'baz'])
      @main.handoff(command: '/usr/bin/foo', argv: ['--bar', 'baz'], skip_prompt: false)
    end
  end
end
