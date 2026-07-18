require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  Response = Struct.new(:success?, :body, :code)

  test ".get_rates returns validated rates from a successful 200 response with multiple attributes" do
    attributes = [
      { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" },
      { period: "Winter", hotel: "RecursionRetreat", room: "BooleanBunk" }
    ]
    response = successful_response_for(attributes)

    RateApiClient.stub(:post, response) do
      assert_equal rates_for(attributes), RateApiClient.get_rates(attributes: attributes)
    end
  end

  test ".get_rates translates malformed JSON into RetryableError" do
    response = Response.new(true, "{not json", 200)

    RateApiClient.stub(:post, response) do
      assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end
    end
  end

  test ".get_rates translates a successful response with an unexpected shape into RetryableError" do
    response = Response.new(true, { status: "error", message: "intermittent issue" }.to_json, 200)

    RateApiClient.stub(:post, response) do
      assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end
    end
  end

  test ".get_rates translates a successful response with a missing field into RetryableError" do
    invalid_rate = rates_for(requested_attributes).first.except("room")
    response = Response.new(true, { rates: [invalid_rate] }.to_json, 200)

    RateApiClient.stub(:post, response) do
      assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end
    end
  end

  test ".get_rates translates a successful response with a non-numeric rate into RetryableError" do
    invalid_rate = rates_for(requested_attributes).first.merge("rate" => "not-a-number")
    response = Response.new(true, { rates: [invalid_rate] }.to_json, 200)

    RateApiClient.stub(:post, response) do
      assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end
    end
  end

  test ".get_rates translates a successful response missing requested combinations into RetryableError" do
    attributes = [
      { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" },
      { period: "Winter", hotel: "RecursionRetreat", room: "BooleanBunk" }
    ]
    response = successful_response_for(attributes.first(1))

    RateApiClient.stub(:post, response) do
      assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: attributes)
      end
    end
  end

  test ".get_rates translates any request error into RetryableError" do
    original_error = RuntimeError.new("HTTP client failed unexpectedly")

    RateApiClient.stub(:post, ->(*) { raise original_error }) do
      error = assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end

      assert_same original_error, error.original_error
    end
  end

  test ".get_rates translates a 400 response into RetryableError" do
    response = Response.new(false, "", 400)

    RateApiClient.stub(:post, response) do
      error = assert_raises(RateApiClient::RetryableError) do
        RateApiClient.get_rates(attributes: requested_attributes)
      end

      assert_equal 400, error.status_code
    end
  end


  private

  def requested_attributes
    [{ period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }]
  end

  def rates_for(attributes)
    attributes.map { |attribute| attribute.stringify_keys.merge("rate" => 15_000) }
  end

  def successful_response_for(attributes)
    Response.new(true, { rates: rates_for(attributes) }.to_json, 200)
  end
end
