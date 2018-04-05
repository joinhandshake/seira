require 'spec_helper'

describe Seira::Secrets do
  let(:context) { { cluster: 'clustername' } }
  subject { described_class.new(app: 'appname', action: @action, args: @args, context: context) }

  def run_and_expect_update(old_secrets:, action:, args:, new_secrets:)
    @action = action
    @args = args

    allow(Seira::Cluster).to receive(:current_cluster).and_return('clustername')
    expect(subject).to receive(:kubectl).with('get secret appname-secrets -o json', context: context, return_output: anything).and_return(old_secrets.to_json)
    expect(subject).to receive(:kubectl).with('get secret appname-secrets', context: context).and_return(true)
    expect(Dir).to receive(:mktmpdir).and_call_original # Make sure we are operating in a temp directory
    expect(File).to receive(:open) do |filename, &block|
      file = double('file')
      expect(file).to receive(:write).with(new_secrets.to_json)
      block.call(file)
      expect(subject).to receive(:kubectl).with("replace -f #{filename}", context: context).and_return(true)
    end

    subject.run
  end

  it 'allows setting a secret' do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {}
      },
      action: 'set',
      args: ['FOO=blah'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.strict_encode64('blah')
        }
      }
    )
  end

  it 'allows updating a secret' do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.strict_encode64('old_value')
        }
      },
      action: 'set',
      args: ['FOO=new_value'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.strict_encode64('new_value')
        }
      }
    )
  end

  it 'keeps existing secrets' do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {
          'OTHER_KEY' => Base64.strict_encode64('other_value')
        }
      },
      action: 'set',
      args: ['FOO=blah'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'OTHER_KEY' => Base64.strict_encode64('other_value'),
          'FOO' => Base64.strict_encode64('blah')
        }
      }
    )
  end

  it "allows setting multiple values" do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {}
      },
      action: 'set',
      args: ['FOO=blah', 'BAR=asdf'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.strict_encode64('blah'),
          'BAR' => Base64.strict_encode64('asdf')
        }
      }
    )
  end
end
