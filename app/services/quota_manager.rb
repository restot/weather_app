# frozen_string_literal: true

class QuotaManager
  class RateLimitExceeded < StandardError
    attr_reader :provider, :retry_after

    def initialize(provider, retry_after = nil)
      @provider = provider
      @retry_after = retry_after
      super("Rate limit exceeded for #{provider}#{retry_after ? ", retry after #{retry_after}s" : ""}")
    end
  end

  class QuotaExceeded < StandardError
    attr_reader :provider

    def initialize(provider)
      @provider = provider
      super("Monthly quota exceeded for #{provider}")
    end
  end

  class ProviderNotConfigured < StandardError
    attr_reader :provider

    def initialize(provider)
      @provider = provider
      super("Provider #{provider} is not configured")
    end
  end

  DEFAULT_CONFIG = {
    requests_per_minute: nil,
    requests_per_second: nil,
    requests_per_month: nil,
    backoff_base: 1.0,
    max_retries: 3
  }.freeze

  LIMIT_CHECKS = [
    { key: :requests_per_month, usage: :monthly_usage, error: QuotaExceeded, retry_after: nil },
    { key: :requests_per_second, usage: :second_usage, error: RateLimitExceeded, retry_after: -> { 1 } },
    { key: :requests_per_minute, usage: :minute_usage, error: RateLimitExceeded, retry_after: -> { 60 - (Time.current.to_i % 60) } }
  ].freeze

  class << self
    def configure(provider, limits = {})
      provider = provider.to_sym
      configurations[provider] = DEFAULT_CONFIG.merge(limits)
    end

    def request!(provider)
      provider = provider.to_sym
      config = config_for(provider)

      LIMIT_CHECKS.each do |check|
        limit = config[check[:key]]
        next unless limit

        usage = send(check[:usage], provider)
        if usage >= limit
          retry_val = check[:retry_after]&.call
          raise check[:error].new(provider, *[retry_val].compact)
        end
      end

      true
    end

    def track(provider)
      provider = provider.to_sym
      config_for(provider)

      second_key = cache_key(provider, :second)
      increment_counter(second_key, expires_in: 2.seconds)

      minute_key = cache_key(provider, :minute)
      increment_counter(minute_key, expires_in: 61.seconds)

      monthly_key = cache_key(provider, :month)
      increment_counter(monthly_key, expires_in: days_until_month_end.days)

      true
    end

    def status(provider)
      provider = provider.to_sym
      config = config_for(provider)

      {
        provider: provider,
        requests_this_second: second_usage(provider),
        requests_this_minute: minute_usage(provider),
        requests_this_month: monthly_usage(provider),
        limits: {
          per_second: config[:requests_per_second],
          per_minute: config[:requests_per_minute],
          per_month: config[:requests_per_month]
        },
        within_limits: within_limits?(provider),
        quota_offset: quota_offset(provider)
      }
    end

    def within_limits?(provider)
      request!(provider.to_sym)
      true
    rescue ProviderNotConfigured, RateLimitExceeded, QuotaExceeded
      false
    end

    def backoff_delay(provider, attempt)
      provider = provider.to_sym
      config = config_for(provider)

      base = config[:backoff_base] || 1.0
      max_retries = config[:max_retries] || 3

      attempt = [attempt, max_retries].min

      base * (2**attempt)
    end

    def can_retry?(provider, attempt)
      provider = provider.to_sym
      config = config_for(provider)
      attempt < (config[:max_retries] || 3)
    end

    def reset!(provider)
      provider = provider.to_sym

      Rails.cache.delete(cache_key(provider, :second))
      Rails.cache.delete(cache_key(provider, :minute))
      Rails.cache.delete(cache_key(provider, :month))
    end

    def clear_configurations!
      @configurations = {}
    end

    def configured_providers
      configurations.keys
    end

    private

    def configurations
      @configurations ||= {}
    end

    def config_for(provider)
      config = configurations[provider]
      raise ProviderNotConfigured.new(provider) unless config

      config
    end

    def cache_key(provider, period)
      suffix = case period
               when :second then Time.current.to_i
               when :minute then Time.current.strftime("%Y%m%d%H%M")
               when :month  then Time.current.strftime("%Y%m")
               end
      "quota_manager:#{provider}:#{period}:#{suffix}"
    end

    def second_usage(provider)
      Rails.cache.read(cache_key(provider, :second)).to_i
    end

    def minute_usage(provider)
      Rails.cache.read(cache_key(provider, :minute)).to_i
    end

    def monthly_usage(provider)
      count = Rails.cache.read(cache_key(provider, :month)).to_i
      count + quota_offset(provider)
    end

    def quota_offset(provider)
      ENV["#{provider.to_s.upcase}_QUOTA_OFFSET"].to_i
    end

    def increment_counter(key, expires_in:)
      current = Rails.cache.read(key).to_i
      Rails.cache.write(key, current + 1, expires_in: expires_in)
    end

    def days_until_month_end
      today = Date.current
      end_of_month = today.end_of_month
      (end_of_month - today).to_i + 1
    end
  end
end
