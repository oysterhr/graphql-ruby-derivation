# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'

  # SPEC.md V.37 wants 100% for every coverage type; current baseline is
  # ~99% line / ~90% branch (~10 files, mostly single guard-clause branches
  # -- see SPEC.md T.51). Floor set just below today's measured numbers so
  # CI enforces "no regression" without blocking on closing that gap; raise
  # toward 100% as gaps close. Line floor has margin below the exact
  # measured value (99.02%) because CI's graphql_2.1.gemfile matrix leg
  # (SPEC.md §12.6) exercises one fewer line -- a `visibility_profile`
  # pending spec that only runs against newer graphql-ruby -- landing at
  # 98.89% on that leg.
  minimum_coverage line: 98, branch: 90
end

require 'graphql/derivation'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.default_formatter = 'doc' if config.files_to_run.one?
  config.order = :random

  Kernel.srand config.seed
end
