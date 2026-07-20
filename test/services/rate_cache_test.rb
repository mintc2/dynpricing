require "test_helper"

class RateCacheTest < ActiveSupport::TestCase
  RATE = {
    period: "Summer",
    hotel: "FloatingPointResort",
    room: "SingletonRoom",
    rate: "15000"
  }.freeze

  def setup
    redis.del(*test_keys)
  end

  def teardown
    redis.del(*test_keys)
  end

  test ".combinations returns every catalog combination" do
    combinations = RateCache.combinations

    assert_equal 36, combinations.size
    assert_equal combinations.uniq, combinations
    assert_includes combinations, RATE.slice(:period, :hotel, :room)
  end

  test ".write_many preserves a numeric rate when .read retrieves it" do
    RateCache.write_many([RATE.merge(rate: 15_000)])

    rate = RateCache.read(**RATE.slice(:period, :hotel, :room))

    assert_equal 15_000, rate
    assert_instance_of Integer, rate
  end

  test ".write_many queues every write in a Redis transaction" do
    writes = []
    multi_calls = 0
    transaction = Object.new
    transaction.define_singleton_method(:set) do |key, value, **options|
      writes << [key, value, options]
    end

    transactional_redis = Object.new
    transactional_redis.define_singleton_method(:multi) do |&block|
      multi_calls += 1
      block.call(transaction)
    end

    rates = [
      RATE.merge(rate: 15_000),
      RATE.merge(room: "BooleanTwin", rate: 20_000)
    ]

    RateCache.stub(:redis, transactional_redis) do
      RateCache.write_many(rates)
    end

    assert_equal 1, multi_calls
    assert_equal [
      ["rate:v1:Summer:FloatingPointResort:SingletonRoom", "15000", { ex: RateCache::TTL }],
      ["rate:v1:Summer:FloatingPointResort:BooleanTwin", "20000", { ex: RateCache::TTL }]
    ], writes
  end

  test ".write_many sets a five-minute expiration" do
    RateCache.write_many([RATE])

    ttl = redis.ttl(RateCache.key(**RATE.slice(:period, :hotel, :room)))
    assert_includes (RateCache::TTL - 1)..RateCache::TTL, ttl
  end

  test ".read returns nil for a missing rate" do
    assert_nil RateCache.read(**RATE.slice(:period, :hotel, :room))
  end

  test ".read wraps Redis connection errors in UnavailableError" do
    unavailable_redis = Object.new
    unavailable_redis.define_singleton_method(:get) do |_key|
      raise Redis::CannotConnectError, "connection refused"
    end

    RateCache.stub(:redis, unavailable_redis) do
      error = assert_raises(RateCache::UnavailableError) do
        RateCache.read(**RATE.slice(:period, :hotel, :room))
      end

      assert_instance_of Redis::CannotConnectError, error.original_error
      assert_instance_of Redis::CannotConnectError, error.cause
    end
  end

  private

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
  end

  def test_keys
    [RateCache.key(**RATE.slice(:period, :hotel, :room))]
  end
end
