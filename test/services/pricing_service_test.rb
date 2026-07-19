require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  ATTRIBUTES = {
    period: "Summer",
    hotel: "FloatingPointResort",
    room: "SingletonRoom"
  }.freeze

  test "returns the cached rate on a cache hit and emits a structured log" do
    logged_message = nil

    RateCache.stub(:read, "15000") do
      Rails.logger.stub(:info, ->(message) { logged_message = message }) do
        service = Api::V1::PricingService.new(**ATTRIBUTES, request_id: "request-123")

        service.run

        assert_predicate service, :valid?
        assert_equal "15000", service.result
        assert_empty service.errors
      end
    end

    assert_equal "pricing_request", logged_message[:event]
    assert_equal "request-123", logged_message[:request_id]
    assert_equal "Summer", logged_message[:period]
    assert_equal "FloatingPointResort", logged_message[:hotel]
    assert_equal "SingletonRoom", logged_message[:room]
    assert_equal "success", logged_message[:outcome]
    assert_equal "hit", logged_message[:cache]
    assert_equal 200, logged_message[:status]
  end

  test "adds a typed cache_miss error and logs the failure once" do
    logged_messages = []

    RateCache.stub(:read, nil) do
      Rails.logger.stub(:warn, ->(message) { logged_messages << message }) do
        service = Api::V1::PricingService.new(**ATTRIBUTES, request_id: "request-123")

        service.run

        assert_not_predicate service, :valid?
        assert_nil service.result
        assert_equal [:cache_miss], service.errors
      end
    end

    assert_equal 1, logged_messages.size
    assert_equal "pricing_request", logged_messages.first[:event]
    assert_equal "pricing_unavailable", logged_messages.first[:outcome]
    assert_equal "miss", logged_messages.first[:cache]
    assert_equal 503, logged_messages.first[:status]
  end

  test "adds a typed cache_unavailable error without logging connection details" do
    logged_message = nil
    unavailable = ->(**) { raise RateCache::UnavailableError.new(Redis::CannotConnectError.new("redis.internal token=secret")) }

    RateCache.stub(:read, unavailable) do
      Rails.logger.stub(:error, ->(message) { logged_message = message }) do
        service = Api::V1::PricingService.new(**ATTRIBUTES)

        service.run

        assert_not_predicate service, :valid?
        assert_nil service.result
        assert_equal [:cache_unavailable], service.errors
      end
    end

    assert_equal "pricing_request", logged_message[:event]
    assert_equal "cache_unavailable", logged_message[:outcome]
    assert_equal "unavailable", logged_message[:cache]
    assert_equal 500, logged_message[:status]
    assert_equal "Redis::CannotConnectError", logged_message[:error_class]
    assert_not_includes logged_message.inspect, "redis.internal"
    assert_not_includes logged_message.inspect, "secret"
  end
end
