# frozen_string_literal: true

require_relative 'lib/graphql/derivation/version'

Gem::Specification.new do |spec|
  spec.name          = 'graphql-ruby-derivation'
  spec.version       = GraphQL::Derivation::VERSION
  spec.authors       = ['Oyster HR Developers']
  spec.email         = ['engineering-paperwork@oysterhr.com']

  spec.summary       = 'Composable argument and field derivation utilities for graphql-ruby schemas.'
  spec.description   = 'Derive GraphQL::Schema::Argument and GraphQL::Schema::Field definitions ' \
                       'from ObjectTypes, InputObjects, and ActiveRecord models, with optional ' \
                       'Rails integration.'
  spec.homepage      = 'https://github.com/oysterhr/graphql-ruby-derivation'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'graphql', '~> 2.0'

  # SPEC.md §1.2: the Rails plugin (`graphql/derivation/rails`) depends on
  # activesupport + actionpack, but they are *optional* -- consumed via require
  # guards, never loaded by core (`graphql/derivation`). They are declared as
  # development dependencies so the test suite can load and stub
  # `ActionController::Base`, without forcing them on consumers who only use the
  # core require path.
  spec.add_development_dependency 'actionpack', '~> 7.0'
  spec.add_development_dependency 'activerecord', '~> 7.0'
  spec.add_development_dependency 'activesupport', '~> 7.0'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
