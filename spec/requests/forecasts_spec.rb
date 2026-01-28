# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Forecasts", type: :request do
  let(:mock_location) do
    {
      zip: "10001",
      city: "New York",
      state: "NY",
      lat: 40.7484,
      lng: -73.9967
    }
  end

  let(:mock_forecast_data) do
    {
      current: {
        temp: 72,
        condition: "Sunny",
        humidity: 45
      },
      high: 78,
      low: 65,
      extended: [
        { date: "Mon", high: 78, low: 65, condition: "Sunny" },
        { date: "Tue", high: 75, low: 62, condition: "Cloudy" }
      ]
    }
  end

  let(:mock_service_result) do
    {
      data: mock_forecast_data,
      location: mock_location,
      cached: false
    }
  end

  describe "GET /" do
    it "renders the new forecast form" do
      get root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /forecasts" do
    context "with valid address" do
      before do
        forecast_service = instance_double(ForecastService, call: mock_service_result)
        allow(ForecastService).to receive(:new).with("123 Main St, New York, NY", bypass_cache: false).and_return(forecast_service)
      end

      it "returns success status" do
        post forecasts_path, params: { address: "123 Main St, New York, NY" }

        expect(response).to have_http_status(:ok)
      end

      it "calls ForecastService with the address" do
        expect(ForecastService).to receive(:new).with("123 Main St, New York, NY", bypass_cache: false)

        post forecasts_path, params: { address: "123 Main St, New York, NY" }
      end
    end

    context "with empty address" do
      it "returns success status with flash error" do
        post forecasts_path, params: { address: "" }

        expect(response).to have_http_status(:ok)
        expect(flash[:error]).to eq("Please enter an address (US Only)")
      end

      it "does not call ForecastService" do
        expect(ForecastService).not_to receive(:new)

        post forecasts_path, params: { address: "" }
      end
    end

    context "with missing address parameter" do
      it "returns success status with flash error" do
        post forecasts_path, params: {}

        expect(response).to have_http_status(:ok)
        expect(flash[:error]).to eq("Please enter an address (US Only)")
      end
    end

    context "when GeocodingService raises an error" do
      before do
        forecast_service = instance_double(ForecastService)
        allow(ForecastService).to receive(:new).and_return(forecast_service)
        allow(forecast_service).to receive(:call).and_raise(
          GeocodingService::GeocodingError, "Could not find address: Invalid Address"
        )
      end

      it "returns success status with flash error" do
        post forecasts_path, params: { address: "Invalid Address" }

        expect(response).to have_http_status(:ok)
        expect(flash[:error]).to eq("Could not find address: Invalid Address")
      end
    end

    context "when WeatherService raises an error" do
      before do
        forecast_service = instance_double(ForecastService)
        allow(ForecastService).to receive(:new).and_return(forecast_service)
        allow(forecast_service).to receive(:call).and_raise(
          WeatherService::WeatherError, "OpenWeatherMap API request failed with status 401: Unauthorized"
        )
      end

      it "returns success status with flash error" do
        post forecasts_path, params: { address: "123 Main St" }

        expect(response).to have_http_status(:ok)
        expect(flash[:error]).to eq("OpenWeatherMap API request failed with status 401: Unauthorized")
      end
    end

    context "with cached result" do
      let(:cached_result) { mock_service_result.merge(cached: true) }

      before do
        forecast_service = instance_double(ForecastService, call: cached_result)
        allow(ForecastService).to receive(:new).and_return(forecast_service)
      end

      it "returns success status" do
        post forecasts_path, params: { address: "123 Main St, New York, NY" }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
