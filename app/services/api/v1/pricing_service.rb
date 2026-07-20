module Api::V1
  class PricingService < BaseService
    def initialize(period:, hotel:, room:, request_id: nil)
      @period = period
      @hotel = hotel
      @room = room
      @request_id = request_id
    end

    def run
      rate = RateCache.read(period: @period, hotel: @hotel, room: @room)

      if rate
        @result = rate
        log_request(:info, outcome: "success", cache: "hit", status: 200)
      else
        errors << :cache_miss
        log_request(:warn, outcome: "pricing_unavailable", cache: "miss", status: 503)
      end
    rescue RateCache::UnavailableError => error
      errors << :cache_unavailable
      log_request(
        :error,
        outcome: "cache_unavailable",
        cache: "unavailable",
        status: 503,
        error_class: error.original_error.class.name
      )
    end

    private

    def log_request(level, outcome:, cache:, status:, **details)
      Rails.logger.public_send(
        level,
        event: "pricing_request",
        request_id: @request_id,
        period: @period,
        hotel: @hotel,
        room: @room,
        outcome: outcome,
        cache: cache,
        status: status,
        **details
      )
    end
  end
end
