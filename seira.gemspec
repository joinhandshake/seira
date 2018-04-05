# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'seira/version'

Gem::Specification.new do |spec|
  spec.name          = "seira"
  spec.version       = Seira::VERSION
  spec.authors       = ["Scott Ringwelski"]
  spec.email         = ["scott@joinhandshake.com"]

  spec.summary       = %q{An opinionated library for building applications on Kubernetes.}
  spec.description   = %q{An opinionated library for building applications on Kubernetes.}
  spec.homepage      = "https://github.com/joinhandshake/seira"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.executables   = ['seira']
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "highline"
  spec.add_runtime_dependency "colorize"

  spec.add_development_dependency "bundler", "~> 1.14"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "0.54.0"
end