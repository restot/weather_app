# frozen_string_literal: true

class ForecastService
  class ForecastError < StandardError; end

  def initialize(address, bypass_cache: false)
    @address = address
    @bypass_cache = bypass_cache
  end

  def call
    geocoding_service = GeocodingService.new(@address, bypass_cache: @bypass_cache)
    geocoding_cache_key = geocoding_service.cache_key
    geocoding_hit = Rails.cache.exist?(geocoding_cache_key) && !@bypass_cache

    location = geocoding_service.call

    weather_service = WeatherService.new(location, bypass_cache: @bypass_cache)
    weather_current_key = weather_service.current_cache_key
    weather_forecast_key = weather_service.forecast_cache_key
    weather_current_hit = Rails.cache.exist?(weather_current_key) && !@bypass_cache
    weather_forecast_hit = Rails.cache.exist?(weather_forecast_key) && !@bypass_cache

    data = weather_service.fetch

    {
      data: data,
      cached: weather_current_hit && weather_forecast_hit,
      location: location,
      cache_details: {
        geocoding: { key: geocoding_cache_key, hit: geocoding_hit, ttl: remaining_ttl(geocoding_cache_key) },
        weather_current: { key: weather_current_key, hit: weather_current_hit, ttl: remaining_ttl(weather_current_key) },
        weather_forecast: { key: weather_forecast_key, hit: weather_forecast_hit, ttl: remaining_ttl(weather_forecast_key) }
      }
    }
  end

  private

  def remaining_ttl(key)
    entry = Rails.cache.send(:read_entry, key)
    return nil unless entry&.expires_at
    remaining = (entry.expires_at - Time.current.to_f).round
    remaining > 0 ? remaining : nil
  rescue
    nil
  end
end
