require "sidekiq/cron/job"

redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379")

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  Sidekiq::Cron::Job.load_from_hash(YAML.load_file(Rails.root.join("config/schedule.yml")))

  config.on(:startup) do
    RateRefreshJob.perform_async
  end
end
