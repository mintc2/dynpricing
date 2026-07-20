class Api::V1::PricingController < ApplicationController
  VALID_PERIODS = PricingCatalog::PERIODS
  VALID_HOTELS = PricingCatalog::HOTELS
  VALID_ROOMS = PricingCatalog::ROOMS

  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    service = Api::V1::PricingService.new(period:, hotel:, room:, request_id: request.request_id)
    service.run
    if service.valid?
      render json: { rate: service.result }
    elsif service.errors.include?(:cache_miss)
      render_pricing_unavailable(status: :service_unavailable)
    elsif service.errors.include?(:cache_unavailable)
      render_pricing_unavailable(status: :service_unavailable)
    else
      render_pricing_unavailable(status: :internal_server_error)
    end
  end

  private

  def render_pricing_unavailable(status:)
    render json: {
      error: {
        code: "pricing_unavailable",
        message: "Pricing is temporarily unavailable. Please try again later."
      }
    }, status:
  end

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless VALID_PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" }, status: :bad_request
    end

    unless VALID_HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" }, status: :bad_request
    end

    unless VALID_ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" }, status: :bad_request
    end
  end
end
