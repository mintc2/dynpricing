class RateCache
  TTL = Integer(ENV.fetch("RATE_CACHE_TTL_SECONDS", 5.minutes.to_s), 10)
  KEY_PREFIX = "rate:v1"

  raise ArgumentError, "RATE_CACHE_TTL_SECONDS must be positive" unless TTL.positive?

  class UnavailableError < StandardError
    attr_reader :original_error

    def initialize(original_error)
      @original_error = original_error
      super("Rate cache is unavailable")
    end
  end

  class << self
    def combinations
      PricingCatalog::PERIODS.product(PricingCatalog::HOTELS, PricingCatalog::ROOMS).map do |period, hotel, room|
        { period:, hotel:, room: }
      end
    end

    def key(period:, hotel:, room:)
      "#{KEY_PREFIX}:#{period}:#{hotel}:#{room}"
    end

    def read(period:, hotel:, room:)
      redis.get(key(period:, hotel:, room:))
    rescue Redis::BaseError => error
      raise UnavailableError.new(error)
    end

    def write_many(rates)
      redis.pipelined do |pipeline|
        rates.each do |rate|
          pipeline.set(
            key(period: rate_value(rate, :period), hotel: rate_value(rate, :hotel), room: rate_value(rate, :room)),
            rate_value(rate, :rate),
            ex: TTL
          )
        end
      end
    rescue Redis::BaseError => error
      raise UnavailableError.new(error)
    end

    private

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
    end

    def rate_value(rate, attribute)
      rate.fetch(attribute) { rate.fetch(attribute.to_s) }
    end
  end
end
