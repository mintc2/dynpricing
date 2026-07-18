require "test_helper"

class RateRefreshJobTest < ActiveSupport::TestCase
  def setup
    @slot_redis = Object.new
    @slot_redis.define_singleton_method(:set) { |_key, _value, **_options| true }
  end

  test "retries Redis errors while claiming the slot" do
    rates = rates_for(RateCache.combinations)
    claim_attempts = 0
    delays = []
    current_time = 0.0

    @slot_redis.define_singleton_method(:set) do |_key, _value, **_options|
      claim_attempts += 1
      raise Redis::CannotConnectError, "connection refused" if claim_attempts == 1

      true
    end

    RateApiClient.stub(:get_rates, rates) do
      RateCache.stub(:write_many, ->(*) {}) do
        perform_job(monotonic_clock: -> { current_time }, sleep: ->(delay) {
          delays << delay
          current_time += delay
        })
      end
    end

    assert_equal 2, claim_attempts
    assert_equal [0.005], delays
  end

  test "logs and does not refresh when the current slot has already been claimed" do
    claimed_key = nil
    claimed_options = nil
    logged_message = nil
    @slot_redis.define_singleton_method(:set) do |key, _value, **options|
      claimed_key = key
      claimed_options = options
      false
    end

    RateApiClient.stub(:get_rates, ->(*) { flunk "duplicate job must not call RateAPI" }) do
      Rails.logger.stub(:info, ->(message) { logged_message = message }) do
        perform_job(wall_clock: -> { Time.at(240) })
      end
    end

    assert_equal "rate_refresh:v1:slot:2", claimed_key
    assert_equal({ nx: true, ex: 300 }, claimed_options)
    assert_equal "rate_refresh_skipped", logged_message[:event]
    assert_equal "rate_refresh:v1:slot:2", logged_message[:slot_key]
    assert_equal "slot_already_claimed", logged_message[:reason]
    assert_kind_of Integer, logged_message[:duration_ms]
  end

  test "writes all 36 validated batch rates and logs structured refresh metadata" do
    rates = rates_for(RateCache.combinations)
    written_rates = nil
    logged_message = nil

    RateApiClient.stub(:get_rates, rates) do
      RateCache.stub(:write_many, ->(values) { written_rates = values }) do
        Rails.logger.stub(:info, ->(message) { logged_message = message }) do
          perform_job
        end
      end
    end

    assert_equal 36, written_rates.size
    assert_equal rates, written_rates
    assert_equal "rate_refresh_succeeded", logged_message[:event]
    assert_equal "rate_refresh:v1:slot:0", logged_message[:slot_key]
    assert_equal 1, logged_message[:attempts]
    assert_equal 36, logged_message[:keys_written]
    assert_kind_of Integer, logged_message[:duration_ms]
  end

  test "retries a client RetryableError with exponential backoff and then writes rates" do
    rates = rates_for(RateCache.combinations)
    calls = 0
    delays = []
    written_rates = nil
    current_time = 0.0

    RateApiClient.stub(:get_rates, lambda { |attributes:|
      calls += 1
      raise RateApiClient::RetryableError, "RateAPI request failed" if calls <= 2

      rates
    }) do
      RateCache.stub(:write_many, ->(values) { written_rates = values }) do
        perform_job(monotonic_clock: -> { current_time }, sleep: ->(delay) {
          delays << delay
          current_time += delay
        })
      end
    end

    assert_equal 3, calls
    assert_equal [0.005, 0.01], delays
    assert_equal rates, written_rates
  end

  test "retries a cache UnavailableError and then writes rates" do
    rates = rates_for(RateCache.combinations)
    calls = 0
    delays = []
    current_time = 0.0

    RateApiClient.stub(:get_rates, rates) do
      RateCache.stub(:write_many, lambda { |values|
        calls += 1
        raise RateCache::UnavailableError, Redis::CannotConnectError.new("connection refused") if calls == 1

        assert_equal rates, values
      }) do
        perform_job(monotonic_clock: -> { current_time }, sleep: ->(delay) {
          delays << delay
          current_time += delay
        })
      end
    end

    assert_equal 2, calls
    assert_equal [0.005], delays
  end

  test "time spent acquiring the slot is included in the deadline" do
    logged_error = nil
    claim_attempts = 0
    current_time = 0.0

    @slot_redis.define_singleton_method(:set) do |_key, _value, **_options|
      claim_attempts += 1
      current_time = 119.0
      raise Redis::CannotConnectError, "connection refused"
    end

    Rails.logger.stub(:error, ->(message) { logged_error = message }) do
      perform_job(monotonic_clock: -> { current_time }, sleep: ->(*) { flunk "must not sleep past deadline" })
    end

    assert_equal 1, claim_attempts
    assert_equal "rate_refresh:v1:slot:0", logged_error[:slot_key]
    assert_equal 0, logged_error[:attempts]
    assert_equal "Redis::CannotConnectError", logged_error[:error_class]
  end

  test "uses the next two-minute boundary rather than a fresh 109-second window" do
    logged_error = nil
    current_time = 0.0

    RateApiClient.stub(:get_rates, lambda { |attributes:|
      raise RateApiClient::RetryableError, "RateAPI request failed"
    }) do
      Rails.logger.stub(:error, ->(message) { logged_error = message }) do
        perform_job(
          monotonic_clock: -> { current_time },
          wall_clock: -> { Time.at(30) },
          sleep: ->(*) { current_time = 89.0 }
        )
      end
    end

    assert_equal 1, logged_error[:attempts]
    assert_equal 89_000, logged_error[:duration_ms]
  end

  test "does not write rates returned after the deadline" do
    rates = rates_for(RateCache.combinations)
    logged_error = nil
    current_time = 0.0

    RateApiClient.stub(:get_rates, lambda { |attributes:|
      current_time = 119.0
      rates
    }) do
      RateCache.stub(:write_many, ->(*) { flunk "late rates must not be written" }) do
        Rails.logger.stub(:error, ->(message) { logged_error = message }) do
          perform_job(monotonic_clock: -> { current_time })
        end
      end
    end

    assert_equal "rate_refresh:v1:slot:0", logged_error[:slot_key]
    assert_equal 1, logged_error[:attempts]
    assert_equal "RateRefreshJob::RetryDeadlineReached", logged_error[:error_class]
  end

  test "retries a client error returned for a non-2xx response" do
    rates = rates_for(RateCache.combinations)
    calls = 0
    current_time = 0.0

    RateApiClient.stub(:get_rates, lambda { |attributes:|
      calls += 1
      raise RateApiClient::RetryableError.new("RateAPI returned HTTP 400", status_code: 400) if calls == 1

      rates
    }) do
      RateCache.stub(:write_many, ->(*) {}) do
        perform_job(monotonic_clock: -> { current_time }, sleep: ->(delay) { current_time += delay })
      end
    end

    assert_equal 2, calls
  end

  private

  def perform_job(monotonic_clock: nil, wall_clock: nil, sleep: nil)
    job = RateRefreshJob.new
    monotonic_clock ||= -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    wall_clock ||= -> { Time.at(0) }

    job.stub(:slot_redis, @slot_redis) do
      job.stub(:monotonic_time, monotonic_clock) do
        job.stub(:wall_time, wall_clock) do
          sleep ? job.stub(:sleep, sleep) { job.perform } : job.perform
        end
      end
    end
  end

  def rates_for(attributes)
    attributes.map { |attribute| attribute.stringify_keys.merge("rate" => 15_000) }
  end
end
