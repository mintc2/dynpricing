class ApplicationController < ActionController::API
  rescue_from StandardError do |error|
    Rails.logger.error("Unhandled application error: #{error.class}")

    render json: {
      error: {
        code: "internal_error",
        message: "An unexpected error occurred. Please try again later."
      }
    }, status: :internal_server_error
  end
end
