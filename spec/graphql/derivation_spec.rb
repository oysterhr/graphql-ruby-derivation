# frozen_string_literal: true

RSpec.describe GraphQL::Derivation do
  it 'has a version number' do
    expect(GraphQL::Derivation::VERSION).not_to be_nil
  end
end
