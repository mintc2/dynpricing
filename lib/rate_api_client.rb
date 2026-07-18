class RateApiClient
  include HTTParty

  class Error < StandardError
    attr_reader :original_error, :status_code

    def initialize(message = nil, original_error: nil, status_code: nil)
      @original_error = original_error
      @status_code = status_code
      super(message)
    end
  end

  class RetryableError < Error; end

  RATE_KEYS = %w[period hotel room rate].freeze
  RATE_ATTRIBUTE_KEYS = %w[period hotel room].freeze

  base_uri ENV.fetch("RATE_API_URL", "http://localhost:8080")
  headers "Content-Type" => "application/json"
  headers "token" => ENV.fetch("RATE_API_TOKEN", "")
  # to_f ensures the result is fractional seconds: `50.to_f / 1_000` becomes `0.05`,
  # rather than relying on integer semantics.
  default_timeout ENV.fetch("RATE_API_TIMEOUT_MS", 50).to_f / 1_000

  def self.get_rates(attributes:)
    response = request_rates(attributes)
    status_code = response.code.to_i

    unless status_code.between?(200, 299)
      raise RetryableError.new("RateAPI returned HTTP #{status_code}", status_code: status_code)
    end

    rates = parse_rates(response.body)
    validate_requested_combinations!(rates, attributes)
    rates
  end

  def self.request_rates(attributes)
    post("/pricing", body: { attributes: attributes }.to_json)
  rescue StandardError => error
    raise RetryableError.new("RateAPI request failed", original_error: error)
  end
  private_class_method :request_rates

  def self.parse_rates(body)
    payload = JSON.parse(body)
    raise InvalidResponse unless payload.is_a?(Hash) && payload.keys == ["rates"] && payload["rates"].is_a?(Array)

    payload["rates"].map { |rate| normalize_rate(rate) }
  rescue JSON::JSONError, KeyError, TypeError, InvalidResponse => error
    raise RetryableError.new("RateAPI returned an invalid success payload", original_error: error)
  end
  private_class_method :parse_rates

  def self.normalize_rate(rate)
    raise InvalidResponse unless rate.is_a?(Hash) && rate.keys.sort == RATE_KEYS.sort

    normalized_rate = rate.stringify_keys
    raise InvalidResponse unless normalized_rate.slice(*RATE_ATTRIBUTE_KEYS).values.all? { |value| value.is_a?(String) }

    rate_value = normalized_rate["rate"]
    raise InvalidResponse unless rate_value.is_a?(Numeric) && rate_value.finite?

    normalized_rate
  end
  private_class_method :normalize_rate

  def self.validate_requested_combinations!(rates, attributes)
    expected = attributes.map { |attribute| attribute.stringify_keys.slice("period", "hotel", "room") }
    actual = rates.map { |rate| rate.slice("period", "hotel", "room") }

    raise InvalidResponse unless actual.sort_by(&:to_a) == expected.sort_by(&:to_a)
  rescue InvalidResponse => error
    raise RetryableError.new("RateAPI returned incomplete, duplicate, or unexpected rates", original_error: error)
  end
  private_class_method :validate_requested_combinations!

  class InvalidResponse < StandardError; end
  private_constant :InvalidResponse
end
