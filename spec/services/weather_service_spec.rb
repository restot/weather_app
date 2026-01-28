# frozen_string_literal: true

require "rails_helper"

RSpec.describe WeatherService do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_key) { "test_openweathermap_api_key" }
  let(:location) do
    {
      zip: "95014",
      city: "Cupertino",
      state: "CA",
      lat: 37.3346,
      lng: -122.0096
    }
  end

  let(:current_weather_response) do
    {
      "weather" => [{ "description" => "partly cloudy" }],
      "main" => { "temp" => 68.5, "temp_min" => 58.3, "temp_max" => 72.1, "humidity" => 45 }
    }
  end

  let(:forecast_response) do
    {
      "list" => [
        {
          "dt_txt" => "2026-01-24 09:00:00",
          "main" => { "temp" => 62.5 },
          "weather" => [{ "description" => "sunny" }]
        },
        {
          "dt_txt" => "2026-01-24 12:00:00",
          "main" => { "temp" => 70.0 },
          "weather" => [{ "description" => "sunny" }]
        },
        {
          "dt_txt" => "2026-01-24 15:00:00",
          "main" => { "temp" => 68.0 },
          "weather" => [{ "description" => "partly cloudy" }]
        },
        {
          "dt_txt" => "2026-01-25 09:00:00",
          "main" => { "temp" => 60.0 },
          "weather" => [{ "description" => "cloudy" }]
        },
        {
          "dt_txt" => "2026-01-25 12:00:00",
          "main" => { "temp" => 65.0 },
          "weather" => [{ "description" => "cloudy" }]
        },
        {
          "dt_txt" => "2026-01-26 09:00:00",
          "main" => { "temp" => 58.0 },
          "weather" => [{ "description" => "light rain" }]
        },
        {
          "dt_txt" => "2026-01-26 15:00:00",
          "main" => { "temp" => 55.0 },
          "weather" => [{ "description" => "light rain" }]
        },
        {
          "dt_txt" => "2026-01-27 12:00:00",
          "main" => { "temp" => 63.0 },
          "weather" => [{ "description" => "sunny" }]
        },
        {
          "dt_txt" => "2026-01-28 12:00:00",
          "main" => { "temp" => 67.0 },
          "weather" => [{ "description" => "sunny" }]
        }
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

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENWEATHERMAP_API_KEY").and_return(api_key)

    allow(QuotaManager).to receive(:request!).with(:openweathermap).and_return(true)
    allow(QuotaManager).to receive(:track).with(:openweathermap).and_return(true)
  end

  describe "#fetch" do
    context "with valid API responses" do
      before do
        stub_request(:get, "https://api.openweathermap.org/data/2.5/weather")
          .with(query: hash_including("zip" => "95014,US", "appid" => api_key, "units" => "imperial"))
          .to_return(
            status: 200,
            body: current_weather_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "https://api.openweathermap.org/data/2.5/forecast")
          .with(query: hash_including("zip" => "95014,US", "appid" => api_key, "units" => "imperial"))
          .to_return(
            status: 200,
            body: forecast_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns normalized structure with all expected keys" do
        result = described_class.new(location).fetch

        expect(result).to have_key(:current)
        expect(result).to have_key(:high)
        expect(result).to have_key(:low)
        expect(result).to have_key(:extended)
      end

      it "returns current weather with temp, condition, and humidity" do
        result = described_class.new(location).fetch

        expect(result[:current]).to include(
          temp: 69,
          condition: "Partly Cloudy",
          humidity: 45
        )
      end

      it "returns high and low temperatures" do
        result = described_class.new(location).fetch

        expect(result[:high]).to eq(72)
        expect(result[:low]).to eq(58)
      end

      it "returns extended forecast with 5 days" do
        result = described_class.new(location).fetch

        expect(result[:extended]).to be_an(Array)
        expect(result[:extended].length).to eq(5)
      end

      it "returns extended forecast entries with date, high, low, and condition" do
        result = described_class.new(location).fetch

        result[:extended].each do |day|
          expect(day).to have_key(:date)
          expect(day).to have_key(:high)
          expect(day).to have_key(:low)
          expect(day).to have_key(:condition)
        end
      end

      it "formats extended forecast dates as day abbreviations" do
        result = described_class.new(location).fetch

        expect(result[:extended].first[:date]).to match(/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/)
      end

      it "calculates daily high/low from all entries for that day" do
        result = described_class.new(location).fetch

        first_day = result[:extended].first
        expect(first_day[:high]).to eq(70)
        expect(first_day[:low]).to eq(63)
      end

      it "picks the most common condition for each day" do
        result = described_class.new(location).fetch

        first_day = result[:extended].first
        expect(first_day[:condition]).to eq("Sunny")
      end

      it "calls QuotaManager.request! before each API request" do
        expect(QuotaManager).to receive(:request!).with(:openweathermap).twice

        described_class.new(location).fetch
      end

      it "calls QuotaManager.track after each successful API request" do
        expect(QuotaManager).to receive(:track).with(:openweathermap).twice

        described_class.new(location).fetch
      end
    end

    context "caching" do
      before do
        stub_request(:get, "https://api.openweathermap.org/data/2.5/weather")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(
            status: 200,
            body: current_weather_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "https://api.openweathermap.org/data/2.5/forecast")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(
            status: 200,
            body: forecast_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "does not hit APIs on second fetch" do
        described_class.new(location).fetch
        described_class.new(location).fetch

        expect(WebMock).to have_requested(:get, /data\/2\.5\/weather/).once
        expect(WebMock).to have_requested(:get, /data\/2\.5\/forecast/).once
      end

      it "re-fetches current weather after 30 minutes" do
        described_class.new(location).fetch

        travel 31.minutes

        described_class.new(location).fetch

        expect(WebMock).to have_requested(:get, /data\/2\.5\/weather/).twice
      end

      it "keeps forecast cached for 3 hours" do
        described_class.new(location).fetch

        travel 31.minutes

        described_class.new(location).fetch

        expect(WebMock).to have_requested(:get, /data\/2\.5\/forecast/).once
      end

      it "re-fetches forecast after 3 hours" do
        described_class.new(location).fetch

        travel 3.hours + 1.minute

        described_class.new(location).fetch

        expect(WebMock).to have_requested(:get, /data\/2\.5\/forecast/).twice
      end
    end

    context "with bypass_cache: true" do
      before do
        stub_request(:get, "https://api.openweathermap.org/data/2.5/weather")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(
            status: 200,
            body: current_weather_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "https://api.openweathermap.org/data/2.5/forecast")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(
            status: 200,
            body: forecast_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "forces API calls on second request" do
        described_class.new(location).fetch
        described_class.new(location, bypass_cache: true).fetch

        expect(WebMock).to have_requested(:get, /data\/2\.5\/weather/).twice
        expect(WebMock).to have_requested(:get, /data\/2\.5\/forecast/).twice
      end
    end

    context "when current weather API returns an error" do
      before do
        stub_request(:get, "https://api.openweathermap.org/data/2.5/weather")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "raises a WeatherError" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /weather API request failed with status 500/)
      end
    end

    context "when forecast API returns an error" do
      before do
        stub_request(:get, "https://api.openweathermap.org/data/2.5/weather")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(
            status: 200,
            body: current_weather_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "https://api.openweathermap.org/data/2.5/forecast")
          .with(query: hash_including("zip" => "95014,US"))
          .to_return(status: 401, body: '{"cod":401,"message":"Invalid API key"}')
      end

      it "raises a WeatherError" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /forecast API request failed with status 401/)
      end
    end

    context "when OPENWEATHERMAP_API_KEY is not set" do
      before do
        allow(ENV).to receive(:[]).with("OPENWEATHERMAP_API_KEY").and_return(nil)
      end

      it "raises a WeatherError about missing API key" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /OPENWEATHERMAP_API_KEY environment variable is not set/)
      end
    end

    context "when OPENWEATHERMAP_API_KEY is empty" do
      before do
        allow(ENV).to receive(:[]).with("OPENWEATHERMAP_API_KEY").and_return("")
      end

      it "raises a WeatherError about missing API key" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /OPENWEATHERMAP_API_KEY environment variable is not set/)
      end
    end

    context "when QuotaManager raises RateLimitExceeded" do
      before do
        allow(QuotaManager).to receive(:request!)
          .with(:openweathermap)
          .and_raise(QuotaManager::RateLimitExceeded.new(:openweathermap, 60))
      end

      it "raises a WeatherError about rate limiting" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /Rate limit exceeded/)
      end
    end

    context "when QuotaManager raises QuotaExceeded" do
      before do
        allow(QuotaManager).to receive(:request!)
          .with(:openweathermap)
          .and_raise(QuotaManager::QuotaExceeded.new(:openweathermap))
      end

      it "raises a WeatherError about quota exceeded" do
        expect { described_class.new(location).fetch }
          .to raise_error(WeatherService::WeatherError, /Monthly quota exceeded/)
      end
    end
  end
end
