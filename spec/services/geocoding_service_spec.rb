# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeocodingService do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_key) { "test_mapbox_api_key" }

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
  end

  before do
    Rails.cache.clear
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAPBOX_API_KEY").and_return(api_key)

    allow(QuotaManager).to receive(:request!).with(:mapbox).and_return(true)
    allow(QuotaManager).to receive(:track).with(:mapbox).and_return(true)
  end

  describe "#call" do
    context "with a valid address" do
      let(:address) { "1 Apple Park Way, Cupertino, CA" }
      let(:mapbox_response) do
        {
          "features" => [
            {
              "text" => "Apple Park Way",
              "center" => [-122.0096, 37.3346],
              "context" => [
                { "id" => "postcode.123", "text" => "95014" },
                { "id" => "place.456", "text" => "Cupertino" },
                { "id" => "region.789", "text" => "California", "short_code" => "US-CA" }
              ]
            }
          ]
        }
      end

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(
            status: 200,
            body: mapbox_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns location hash with all required keys" do
        result = described_class.new(address).call

        expect(result).to include(
          zip: "95014",
          city: "Cupertino",
          state: "CA",
          lat: 37.3346,
          lng: -122.0096
        )
      end

      it "returns a hash with symbol keys" do
        result = described_class.new(address).call

        expect(result.keys).to all(be_a(Symbol))
      end

      it "calls QuotaManager.request! before making API request" do
        expect(QuotaManager).to receive(:request!).with(:mapbox).ordered
        expect(QuotaManager).to receive(:track).with(:mapbox).ordered

        described_class.new(address).call
      end

      it "calls QuotaManager.track after successful API request" do
        expect(QuotaManager).to receive(:track).with(:mapbox)

        described_class.new(address).call
      end
    end

    context "when address has no zip code" do
      let(:address) { "Remote Location, Somewhere" }
      let(:lat) { 45.1234 }
      let(:lng) { -120.5678 }
      let(:mapbox_response) do
        {
          "features" => [
            {
              "text" => "Remote Location",
              "center" => [lng, lat],
              "context" => [
                { "id" => "place.456", "text" => "Somewhere" },
                { "id" => "region.789", "text" => "Oregon", "short_code" => "US-OR" }
              ]
            }
          ]
        }
      end

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(
            status: 200,
            body: mapbox_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "uses lat/lng as fallback for zip" do
        result = described_class.new(address).call

        expect(result[:zip]).to eq("#{lat},#{lng}")
      end

      it "still returns other location data" do
        result = described_class.new(address).call

        expect(result).to include(
          city: "Somewhere",
          state: "OR",
          lat: lat,
          lng: lng
        )
      end
    end

    context "when API returns an error" do
      let(:address) { "123 Test Street" }

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "raises a GeocodingError with descriptive message" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /Mapbox API request failed with status 500/)
      end
    end

    context "when API returns unauthorized error" do
      let(:address) { "123 Test Street" }

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(status: 401, body: '{"message":"Unauthorized"}')
      end

      it "raises a GeocodingError" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /Mapbox API request failed with status 401/)
      end
    end

    context "when address is not found" do
      let(:address) { "xyznonexistent12345" }
      let(:mapbox_response) do
        {
          "features" => []
        }
      end

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(
            status: 200,
            body: mapbox_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises a GeocodingError with address not found message" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /Could not find address/)
      end
    end

    context "when MAPBOX_API_KEY is not set" do
      let(:address) { "123 Test Street" }

      before do
        allow(ENV).to receive(:[]).with("MAPBOX_API_KEY").and_return(nil)
      end

      it "raises a GeocodingError about missing API key" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /MAPBOX_API_KEY environment variable is not set/)
      end
    end

    context "when QuotaManager raises RateLimitExceeded" do
      let(:address) { "123 Test Street" }

      before do
        allow(QuotaManager).to receive(:request!)
          .with(:mapbox)
          .and_raise(QuotaManager::RateLimitExceeded.new(:mapbox, 30))
      end

      it "raises a GeocodingError about rate limiting" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /Rate limit exceeded/)
      end
    end

    context "caching" do
      let(:address) { "1 Apple Park Way, Cupertino, CA" }
      let(:mapbox_response) do
        {
          "features" => [
            {
              "text" => "Apple Park Way",
              "center" => [-122.0096, 37.3346],
              "context" => [
                { "id" => "postcode.123", "text" => "95014" },
                { "id" => "place.456", "text" => "Cupertino" },
                { "id" => "region.789", "text" => "California", "short_code" => "US-CA" }
              ]
            }
          ]
        }
      end

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(
            status: 200,
            body: mapbox_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "does not hit the API on second call" do
        described_class.new(address).call
        described_class.new(address).call

        expect(WebMock).to have_requested(:get, /api\.mapbox\.com/).once
      end

      it "hits the API again after cache expires (7 days)" do
        described_class.new(address).call

        travel 7.days + 1.minute

        described_class.new(address).call

        expect(WebMock).to have_requested(:get, /api\.mapbox\.com/).twice
      end
    end

    context "with bypass_cache: true" do
      let(:address) { "1 Apple Park Way, Cupertino, CA" }
      let(:mapbox_response) do
        {
          "features" => [
            {
              "text" => "Apple Park Way",
              "center" => [-122.0096, 37.3346],
              "context" => [
                { "id" => "postcode.123", "text" => "95014" },
                { "id" => "place.456", "text" => "Cupertino" },
                { "id" => "region.789", "text" => "California", "short_code" => "US-CA" }
              ]
            }
          ]
        }
      end

      before do
        stub_request(:get, /api\.mapbox\.com\/geocoding\/v5\/mapbox\.places/)
          .with(query: hash_including("access_token" => api_key))
          .to_return(
            status: 200,
            body: mapbox_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "forces API call on second request" do
        described_class.new(address).call
        described_class.new(address, bypass_cache: true).call

        expect(WebMock).to have_requested(:get, /api\.mapbox\.com/).twice
      end
    end

    context "when QuotaManager raises QuotaExceeded" do
      let(:address) { "123 Test Street" }

      before do
        allow(QuotaManager).to receive(:request!)
          .with(:mapbox)
          .and_raise(QuotaManager::QuotaExceeded.new(:mapbox))
      end

      it "raises a GeocodingError about quota exceeded" do
        expect { described_class.new(address).call }
          .to raise_error(GeocodingService::GeocodingError, /Monthly quota exceeded/)
      end
    end
  end
end
