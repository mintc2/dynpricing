require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  test "returns the cached rate on a cache hit" do
    RateCache.stub(:read, "15000") do
      get api_v1_pricing_url, params: valid_params

      assert_response :success
      assert_equal "application/json", @response.media_type
      assert_equal "15000", JSON.parse(@response.body)["rate"]
    end
  end

  test "returns a safe 503 response on a cache miss" do
    RateCache.stub(:read, nil) do
      get api_v1_pricing_url, params: valid_params

      assert_response :service_unavailable
      assert_safe_pricing_error
    end
  end

  test "returns a safe 500 response when the cache is unavailable" do
    unavailable = ->(**) { raise RateCache::UnavailableError.new(StandardError.new("redis.internal:6379")) }

    RateCache.stub(:read, unavailable) do
      get api_v1_pricing_url, params: valid_params

      assert_response :internal_server_error
      assert_safe_pricing_error
    end
  end

  test "returns a generic 500 response for unexpected errors" do
    RateCache.stub(:read, ->(**) { raise StandardError, "rate-api.internal token=secret" }) do
      get api_v1_pricing_url, params: valid_params

      assert_response :internal_server_error
      error = JSON.parse(@response.body).fetch("error")
      assert_equal "internal_error", error.fetch("code")
      assert_equal "An unexpected error occurred. Please try again later.", error.fetch("message")
      assert_not_includes @response.body, "rate-api.internal"
      assert_not_includes @response.body, "secret"
    end
  end

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
  end

  private

  def valid_params
    {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }
  end

  def assert_safe_pricing_error
    error = JSON.parse(@response.body).fetch("error")

    assert_equal "pricing_unavailable", error.fetch("code")
    assert_equal "Pricing is temporarily unavailable. Please try again later.", error.fetch("message")
    assert_not_includes @response.body, "redis.internal"
  end
end
