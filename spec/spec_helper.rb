require "simplecov"
SimpleCov.start

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'sidekiq/batch'
require 'pry-byebug'
require 'mock_redis'

def new_mocked_redis
  mocked_redis = MockRedis.new
  # Patch usage of MockRedis#info that only handles symbols for arg
  mocked_redis.define_singleton_method(:info) { |section = 'default'| super(section.to_sym) }
  mocked_redis
end

Sidekiq.configure_client do |config|
  config.redis = { url: nil }
end

Sidekiq.configure_server do |config|
  config.redis = { url: nil }
end

RSpec.configure do |config|
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true

  config.before(:each) do
    allow(Sidekiq).to receive(:redis).and_yield(new_mocked_redis)
  end
end

Dir[File.dirname(__FILE__) + "/support/**/*.rb"].each {|f| require f }

Sidekiq::Batch::Middleware.configure
