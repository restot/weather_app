# frozen_string_literal: true

require "rails_helper"

RSpec.describe ForecastService do
  include ActiveSupport::Testing::TimeHelpers

  let(:address) { "123 Main St, Cupertino, CA 95014" }
  let(:location) do
    {
      zip: "95014",
      city: "Cupertino",
      state: "CA",
      lat: 37.3230,
      lng: -122.0322
    }
  end

  let(:weather_data) do
    {
      current: {
        temp: 68,
        condition: "Partly Cloudy",
        humidity: 45
      },
      high: 72,
      low: 58,
      extended: [
        { date: "Mon", high: 70, low: 55, condition: "Sunny" },
        { date: "Tue", high: 68, low: 54, condition: "Cloudy" }
      ]
    }
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
  end

  before do
    Rails.cache.clear

    geocoding_service = instance_double(GeocodingService, cache_key: "geocoding:123 main st, cupertino, ca 95014")
    allow(GeocodingService).to receive(:new).with(address, bypass_cache: false).and_return(geocoding_service)
    allow(geocoding_service).to receive(:call).and_return(location)

    weather_service = instance_double(WeatherService,
      current_cache_key: "weather:zip:95014:current",
      forecast_cache_key: "weather:zip:95014:forecast")
    allow(WeatherService).to receive(:new).with(location, bypass_cache: false).and_return(weather_service)
    allow(weather_service).to receive(:fetch) do
      Rails.cache.write("weather:zip:95014:current", true, expires_in: 30.minutes)
      Rails.cache.write("weather:zip:95014:forecast", true, expires_in: 3.hours)
      weather_data
    end
  end

  describe "#call" do
    it "returns weather data with location" do
      result = described_class.new(address).call

      expect(result[:data]).to eq(weather_data)
      expect(result[:location]).to eq(location)
    end

    it "returns cached: false on first call" do
      result = described_class.new(address).call

      expect(result[:cached]).to be false
    end

    it "returns cached: true on second call (same coords)" do
      described_class.new(address).call

      result = described_class.new(address).call

      expect(result[:cached]).to be true
    end

    it "returns cache_details with hit/miss info" do
      result = described_class.new(address).call

      expect(result[:cache_details]).to include(:geocoding, :weather_current, :weather_forecast)
      result[:cache_details].each_value do |detail|
        expect(detail).to have_key(:key)
        expect(detail).to have_key(:hit)
      end
    end

    context "with bypass_cache: true" do
      before do
        geocoding_service = instance_double(GeocodingService, cache_key: "geocoding:123 main st, cupertino, ca 95014")
        allow(GeocodingService).to receive(:new).with(address, bypass_cache: true).and_return(geocoding_service)
        allow(geocoding_service).to receive(:call).and_return(location)

        weather_service = instance_double(WeatherService,
          current_cache_key: "weather:zip:95014:current",
          forecast_cache_key: "weather:zip:95014:forecast")
        allow(WeatherService).to receive(:new).with(location, bypass_cache: true).and_return(weather_service)
        allow(weather_service).to receive(:fetch).and_return(weather_data)
      end

      it "forces fresh fetch even when cached" do
        # Prime the cache
        described_class.new(address).call

        result = described_class.new(address, bypass_cache: true).call

        expect(result[:cached]).to be false
      end
    end

    context "when different addresses resolve to the same coords" do
      let(:different_address) { "456 Oak Ave, Cupertino, CA 95014" }

      before do
        geocoding_service = instance_double(GeocodingService, cache_key: "geocoding:456 oak ave, cupertino, ca 95014")
        allow(GeocodingService).to receive(:new).with(different_address, bypass_cache: false).and_return(geocoding_service)
        allow(geocoding_service).to receive(:call).and_return(location)
      end

      it "shares cache between addresses with the same coords" do
        described_class.new(address).call

        result = described_class.new(different_address).call

        expect(result[:cached]).to be true
      end
    end

    context "when cache expires after TTL" do
      it "returns cached: false after 30 minutes" do
        described_class.new(address).call

        travel 31.minutes

        result = described_class.new(address).call
        expect(result[:cached]).to be false
      end

      it "returns cached: true within 30 minutes" do
        described_class.new(address).call

        travel 29.minutes

        result = described_class.new(address).call
        expect(result[:cached]).to be true
      end
    end

    context "when geocoding fails" do
      before do
        geocoding_service = instance_double(GeocodingService, cache_key: "geocoding:123 main st, cupertino, ca 95014")
        allow(GeocodingService).to receive(:new).with(address, bypass_cache: false).and_return(geocoding_service)
        allow(geocoding_service).to receive(:call).and_raise(GeocodingService::GeocodingError, "Could not find address")
      end

      it "raises the geocoding error" do
        expect { described_class.new(address).call }.to raise_error(GeocodingService::GeocodingError, "Could not find address")
      end
    end

    context "when weather service fails" do
      before do
        weather_service = instance_double(WeatherService,
          current_cache_key: "weather:zip:95014:current",
          forecast_cache_key: "weather:zip:95014:forecast")
        allow(WeatherService).to receive(:new).with(location, bypass_cache: false).and_return(weather_service)
        allow(weather_service).to receive(:fetch).and_raise(WeatherService::WeatherError, "Weather service unavailable")
      end

      it "raises the weather error" do
        expect { described_class.new(address).call }.to raise_error(WeatherService::WeatherError, "Weather service unavailable")
      end
    end
  end
end
