require 'spec_helper'

describe Seira::Secrets do
  subject { described_class.new(app: 'appname', action: @action, args: @args, context: { cluster: 'clustername' }) }

  def run_and_expect_update(old_secrets:, action:, args:, new_secrets:)
    @action = action
    @args = args

    allow(Seira::Cluster).to receive(:current_cluster).and_return('clustername')
    expect(subject).to receive(:`).with('kubectl get secret appname-secrets --namespace appname -o json').and_return(old_secrets.to_json)
    expect(subject).to receive(:system).with('kubectl get secret appname-secrets --namespace appname > /dev/null').and_return(true)
    expect(File).to receive(:open) do |filename, &block|
      file = double('file')
      expect(file).to receive(:write).with(new_secrets.to_json)
      block.call(file)
      expect(subject).to receive(:system).with("kubectl replace --namespace appname -f #{filename}").and_return(true)
      expect(File).to receive(:delete).with(filename)
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
          'FOO' => Base64.encode64('blah').chomp
        }
      }
    )
  end

  it 'allows updating a secret' do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.encode64('old_value').chomp
        }
      },
      action: 'set',
      args: ['FOO=new_value'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'FOO' => Base64.encode64('new_value').chomp
        }
      }
    )
  end

  it 'keeps existing secrets' do
    run_and_expect_update(
      old_secrets: {
        'kind' => 'Secret',
        'data' => {
          'OTHER_KEY' => Base64.encode64('other_value').chomp
        }
      },
      action: 'set',
      args: ['FOO=blah'],
      new_secrets: {
        'kind' => 'Secret',
        'data' => {
          'OTHER_KEY' => Base64.encode64('other_value').chomp,
          'FOO' => Base64.encode64('blah').chomp
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
          'FOO' => Base64.encode64('blah').chomp,
          'BAR' => Base64.encode64('asdf').chomp
        }
      }
    )
  end
end
