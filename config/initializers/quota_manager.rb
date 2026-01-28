# frozen_string_literal: true

Rails.application.config.after_initialize do
  QuotaManager.configure(:mapbox, {
    requests_per_minute: 600,
    requests_per_month: 100_000,
    backoff_base: 1.0,
    max_retries: 3
  })

  QuotaManager.configure(:openweathermap, {
    requests_per_minute: 60,
    requests_per_month: 1_000_000,
    backoff_base: 1.0,
    max_retries: 3
  })
end
