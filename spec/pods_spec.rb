require 'spec_helper'

describe Seira::Pods do
  it 'exists with error when no pods can be fetched' do
    pods = Seira::Pods.new(app: 'spec', action: 'connect', args: [], context: '')

    expect(Seira::Helpers).to receive(:fetch_pods).and_return([])

    expect do
      expect { pods.run }.to raise_exception(SystemExit)
    end.to output("Could not find pod to connect to\n").to_stdout
  end
end
