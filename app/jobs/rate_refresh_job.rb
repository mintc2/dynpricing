class RateRefreshJob
  include Sidekiq::Job

  # This job owns its bounded retry behavior; so disable the auto Sidekiq retry.
  sidekiq_options retry: false

  REFRESH_INTERVAL_SECONDS = 2.minutes.to_i
  SAFETY_MARGIN_SECONDS = 1
  SLOT_CLAIM_TTL_SECONDS = 5.minutes.to_i
  INITIAL_RETRY_DELAY_SECONDS = 0.005
  SLOT_KEY_PREFIX = "rate_refresh:v1:slot"

  class RetryDeadlineReached < StandardError; end
  private_constant :RetryDeadlineReached

  def perform
    started_at = monotonic_time
    slot, deadline = current_slot_and_deadline(started_at)
    slot_key = slot_key(slot)
    delay = INITIAL_RETRY_DELAY_SECONDS
    attempts = 0
    last_error = nil
    slot_claimed = false

    loop do
      break if monotonic_time >= deadline

      begin
        unless slot_claimed
          unless claim_slot(slot_key)
            log_skipped(slot_key:, reason: "slot_already_claimed", duration_ms: elapsed_ms(started_at))
            return
          end

          slot_claimed = true
          # Separates the slot acquisition retry delay from the main get/write operation.
          delay = INITIAL_RETRY_DELAY_SECONDS
        end

        attempts += 1
        rates = RateApiClient.get_rates(attributes: RateCache.combinations)

        if monotonic_time >= deadline
          last_error = RetryDeadlineReached.new("Refresh completed after its deadline")
          break
        end

        RateCache.write_many(rates)
        log_success(slot_key:, attempts:, keys_written: rates.size, duration_ms: elapsed_ms(started_at))
        return
      rescue RateApiClient::RetryableError, RateCache::UnavailableError, Redis::BaseError => error
        last_error = error
        break if monotonic_time + delay >= deadline

        # sleep is used as much simpler alternative to scheduling another job with perform_in(delay).
        # IMHO justifiable here.
        sleep(delay)
        delay *= 2
      rescue StandardError => error
        log_failure(error, slot_key:, attempts:, duration_ms: elapsed_ms(started_at))
        return
      end
    end

    last_error ||= RetryDeadlineReached.new("Refresh deadline reached")
    log_failure(last_error, slot_key:, attempts:, duration_ms: elapsed_ms(started_at))
  end

  private

  def current_slot_and_deadline(started_at)
    now = wall_time.to_f
    slot = now.to_i.div(REFRESH_INTERVAL_SECONDS)
    slot_ends_at = (slot + 1) * REFRESH_INTERVAL_SECONDS
    deadline = started_at + slot_ends_at - now - SAFETY_MARGIN_SECONDS

    [slot, deadline]
  end

  def slot_key(slot)
    "#{SLOT_KEY_PREFIX}:#{slot}"
  end

  def claim_slot(slot_key)
    # Slot claims are intentionally not released. Delayed or duplicate executions for
    # this slot exit, while the next slot uses a different key and remains independent.
    slot_redis.set(
      slot_key,
      "claimed",
      nx: true,
      ex: SLOT_CLAIM_TTL_SECONDS
    )
  end

  def slot_redis
    @slot_redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
  end

  def log_skipped(slot_key:, reason:, duration_ms:)
    Rails.logger.info(
      event: "rate_refresh_skipped",
      slot_key:,
      reason:,
      duration_ms:
    )
  end

  def log_success(slot_key:, attempts:, keys_written:, duration_ms:)
    Rails.logger.info(
      event: "rate_refresh_succeeded",
      slot_key:,
      attempts: attempts,
      keys_written: keys_written,
      duration_ms: duration_ms
    )
  end

  def log_failure(error, slot_key:, attempts:, duration_ms:)
    Rails.logger.error(
      event: "rate_refresh_failed",
      slot_key:,
      attempts: attempts,
      duration_ms: duration_ms,
      error_class: error.class.name,
      error_message: sanitize_error_message(error),
    )
  end

  def sanitize_error_message(error)
    return error.message if error.is_a?(RateApiClient::Error)

    "Rate refresh failed"
  end

  def wall_time
    Time.current
  end

  def monotonic_time
    # Monotonic time only moves forward and is unaffected by wall-clock adjustments.
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_time - started_at) * 1_000).round
  end
end
