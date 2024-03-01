lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'rollout/ui/version'

Gem::Specification.new do |spec|
  spec.name          = 'rollout-ui'
  spec.version       = Rollout::UI::VERSION
  spec.authors       = ['FetLife']
  spec.email         = ['dev@fetlife.com']

  spec.summary       = %q{}
  spec.description   = %q{}
  spec.homepage      = 'https://github.com/fetlife/rollout-ui'
  spec.license       = 'MIT'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'rollout', '~> 2.6'
  spec.add_dependency 'sinatra', ['>= 2.0', '< 5.0']
  spec.add_dependency 'sinatra-contrib', ['>= 2.0', '< 5.0']
  spec.add_dependency 'slim', ['>= 3.0', '< 6.0']

  spec.add_development_dependency 'bundler', '>= 1.17'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rerun', '~> 0.14'
  spec.add_development_dependency 'rack-test'
  spec.add_development_dependency 'rackup'
  spec.add_development_dependency 'puma'
  spec.add_development_dependency 'pry'
end
