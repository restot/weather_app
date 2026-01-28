# frozen_string_literal: true

class GeocodingService
  class GeocodingError < StandardError; end

  MAPBOX_BASE_URL = "https://api.mapbox.com/geocoding/v5/mapbox.places"
  PROVIDER = :mapbox
  CACHE_TTL = 7.days

  def initialize(address, bypass_cache: false)
    @address = address
    @bypass_cache = bypass_cache
  end

  def call
    result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, force: @bypass_cache) do
      QuotaManager.request!(PROVIDER)
      response = fetch_geocoding_data
      data = parse_response(response)
      QuotaManager.track(PROVIDER)
      data
    end
    result = JSON.parse(result) if result.is_a?(String)
    result.symbolize_keys
  rescue QuotaManager::RateLimitExceeded => e
    raise GeocodingError, "Rate limit exceeded for Mapbox API. Please try again in #{e.retry_after} seconds."
  rescue QuotaManager::QuotaExceeded
    raise GeocodingError, "Monthly quota exceeded for Mapbox API. Please contact support."
  end

  def cache_key
    "geocoding:#{@address.downcase.strip}"
  end

  private

  def fetch_geocoding_data
    encoded_address = URI.encode_www_form_component(@address)
    url = "#{MAPBOX_BASE_URL}/#{encoded_address}.json"
    filtered_url = "#{url}?access_token=[FILTERED]"

    Rails.logger.tagged("GeocodingService", "Mapbox") do
      Rails.logger.info "Request: GET #{filtered_url}"
    end

    start_time = Time.current
    response = HTTParty.get(url, query: { access_token: api_key })
    duration = ((Time.current - start_time) * 1000).round(1)

    Rails.logger.tagged("GeocodingService", "Mapbox") do
      Rails.logger.info "Response: #{response.code} in #{duration}ms"
    end

    unless response.success?
      raise GeocodingError, "Mapbox API request failed with status #{response.code}: #{response.message}"
    end

    data = response.parsed_response
    data.is_a?(String) ? JSON.parse(data) : data
  end

  def parse_response(data)
    features = data["features"]

    if features.nil? || features.empty?
      raise GeocodingError, "Could not find address: #{@address}"
    end

    feature = features.first
    context = feature["context"] || []

    lat = feature.dig("center", 1)
    lng = feature.dig("center", 0)

    zip = extract_context_value(context, "postcode")
    city = extract_context_value(context, "place") || feature["text"]
    state = extract_context_value(context, "region")

    zip ||= "#{lat},#{lng}"

    {
      zip: zip,
      city: city,
      state: state,
      lat: lat,
      lng: lng
    }
  end

  def extract_context_value(context, type)
    entry = context.find { |c| c["id"]&.start_with?("#{type}.") }
    return nil unless entry

    if type == "region" && entry["short_code"]
      entry["short_code"].split("-").last
    else
      entry["text"]
    end
  end

  def api_key
    key = ENV["MAPBOX_API_KEY"]
    raise GeocodingError, "MAPBOX_API_KEY environment variable is not set" if key.nil? || key.empty?

    key
  end
end
