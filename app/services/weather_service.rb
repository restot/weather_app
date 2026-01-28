# frozen_string_literal: true

class WeatherService
  class WeatherError < StandardError; end

  OPENWEATHERMAP_BASE_URL = "https://api.openweathermap.org/data/2.5"
  PROVIDER = :openweathermap
  CURRENT_CACHE_TTL = 30.minutes
  FORECAST_CACHE_TTL = 3.hours

  def initialize(location, bypass_cache: false)
    @location = location
    @bypass_cache = bypass_cache
  end

  def fetch
    current_data = cached_fetch(current_cache_key, CURRENT_CACHE_TTL) { api_request("weather", current_weather_params) }
    forecast_data = cached_fetch(forecast_cache_key, FORECAST_CACHE_TTL) { api_request("forecast", forecast_params) }

    build_normalized_response(current_data, forecast_data)
  rescue QuotaManager::RateLimitExceeded => e
    raise WeatherError, "Rate limit exceeded for OpenWeatherMap API. Please try again in #{e.retry_after} seconds."
  rescue QuotaManager::QuotaExceeded
    raise WeatherError, "Monthly quota exceeded for OpenWeatherMap API. Please contact support."
  end

  def location_cache_key
    if valid_zip?
      "weather:zip:#{@location[:zip]}"
    else
      "weather:coords:#{@location[:lat]},#{@location[:lng]}"
    end
  end

  def current_cache_key
    "#{location_cache_key}:current"
  end

  def forecast_cache_key
    "#{location_cache_key}:forecast"
  end

  private

  def cached_fetch(cache_key, ttl)
    Rails.cache.fetch(cache_key, expires_in: ttl, force: @bypass_cache) do
      QuotaManager.request!(PROVIDER)
      data = yield
      QuotaManager.track(PROVIDER)
      data
    end
  end

  def api_request(endpoint, params)
    url = "#{OPENWEATHERMAP_BASE_URL}/#{endpoint}"
    log_request("GET", url, params)

    start_time = Time.current
    response = HTTParty.get(url, query: params)
    log_response(response, start_time)

    unless response.success?
      raise WeatherError, "OpenWeatherMap #{endpoint} API request failed with status #{response.code}: #{response.message}"
    end

    response.parsed_response
  end

  def location_params
    if valid_zip?
      { zip: "#{@location[:zip]},US" }
    else
      { lat: @location[:lat], lon: @location[:lng] }
    end
  end

  def valid_zip?
    zip = @location[:zip].to_s
    zip.match?(/\A\d{5}(-\d{4})?\z/)
  end

  def current_weather_params
    location_params.merge(
      appid: api_key,
      units: "imperial"
    )
  end

  def forecast_params
    location_params.merge(
      appid: api_key,
      units: "imperial"
    )
  end

  def build_normalized_response(current_data, forecast_data)
    {
      current: {
        temp: current_data.dig("main", "temp")&.round,
        condition: extract_condition(current_data),
        humidity: current_data.dig("main", "humidity")
      },
      high: current_data.dig("main", "temp_max")&.round,
      low: current_data.dig("main", "temp_min")&.round,
      extended: build_extended_forecast(forecast_data)
    }
  end

  def extract_condition(data)
    weather = data["weather"]
    return nil if weather.nil? || weather.empty?
    weather.first["description"]&.split&.map(&:capitalize)&.join(" ")
  end

  def build_extended_forecast(forecast_data)
    list = forecast_data["list"] || []
    daily_forecasts = group_by_day(list)

    daily_forecasts.first(5).map do |date, entries|
      temps = entries.map { |e| e.dig("main", "temp") }.compact
      conditions = entries.map { |e| extract_condition(e) }.compact

      {
        date: format_date(date),
        high: temps.max&.round,
        low: temps.min&.round,
        condition: most_common_condition(conditions)
      }
    end
  end

  def group_by_day(list)
    list.group_by do |entry|
      timestamp = entry["dt_txt"]
      Date.parse(timestamp)
    end.sort.to_h
  end

  def format_date(date)
    date.strftime("%a")
  end

  def most_common_condition(conditions)
    return nil if conditions.empty?

    conditions.group_by(&:itself)
              .max_by { |_, v| v.size }
              &.first
  end

  def api_key
    key = ENV["OPENWEATHERMAP_API_KEY"]
    raise WeatherError, "OPENWEATHERMAP_API_KEY environment variable is not set" if key.nil? || key.empty?

    key
  end

  def log_request(method, url, params)
    filtered_params = params.merge(appid: "[FILTERED]")
    Rails.logger.tagged("WeatherService", "OpenWeatherMap") do
      Rails.logger.info "Request: #{method} #{url}?#{filtered_params.to_query}"
    end
  end

  def log_response(response, start_time)
    duration = ((Time.current - start_time) * 1000).round(1)
    Rails.logger.tagged("WeatherService", "OpenWeatherMap") do
      Rails.logger.info "Response: #{response.code} in #{duration}ms"
    end
  end
end
