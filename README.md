# Weather Forecast

**Demo:** [weather-app.restot.top](https://weather-app.restot.top/)

Rails app that takes a US address, geocodes it, fetches the weather, and caches results by coordinates.

What you get: current temp/conditions, daily high/low, 5-day forecast, and humidity. Current weather is cached for 30 minutes and the extended forecast for 3 hours — a "Cached" badge shows when you're seeing stored data.

## How it works

The controller hands off to `ForecastService`, which geocodes the address via Mapbox and calls `WeatherService` for weather data. `WeatherService` caches current weather (30 min) and the extended forecast (3 hours) by coordinates. Each API provider has rate limiting and quota tracking through `QuotaManager`. All business logic lives in service objects under `app/services/`.

```mermaid
sequenceDiagram
    participant U as User
    participant C as ForecastsController
    participant FS as ForecastService
    participant GS as GeocodingService
    participant WS as WeatherService
    participant QM as QuotaManager
    participant Cache as Rails.cache
    participant MB as Mapbox API
    participant OWM as OpenWeatherMap API

    U->>C: POST /forecasts (address)
    C->>FS: call(address)

    FS->>Cache: exist?(geocoding key)
    FS->>GS: call(address)
    GS->>Cache: fetch(geocoding key, 7d)
    alt cache miss
        GS->>QM: request!(:mapbox)
        GS->>MB: GET geocoding
        MB-->>GS: location data
        GS->>QM: track(:mapbox)
    end
    GS-->>FS: {zip, city, state, lat, lng}

    FS->>WS: fetch(location)
    WS->>Cache: fetch(current key, 30m)
    alt cache miss
        WS->>QM: request!(:openweathermap)
        WS->>OWM: GET /weather
        OWM-->>WS: current weather
        WS->>QM: track(:openweathermap)
    end
    WS->>Cache: fetch(forecast key, 3h)
    alt cache miss
        WS->>QM: request!(:openweathermap)
        WS->>OWM: GET /forecast
        OWM-->>WS: 5-day forecast
        WS->>QM: track(:openweathermap)
    end
    WS-->>FS: normalized response

    FS-->>C: {data, cached, location, cache_details}
    C-->>U: render show
```

## Tech stack

| What | Choice | Why |
|------|--------|-----|
| Framework | Rails 8.1 / Ruby 3.4 | |
| Geocoding | Mapbox | 100k/mo free |
| Weather | OpenWeatherMap | 1M/mo free |
| CSS | Pico (CDN) | No build step, dark mode |
| HTTP | HTTParty | |
| Tests | RSpec + WebMock | |
| Cache | Memory (dev) / Redis (prod) | |

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MAPBOX_API_KEY` | Yes | Mapbox geocoding API key ([get one](https://account.mapbox.com/)) |
| `OPENWEATHERMAP_API_KEY` | Yes | OpenWeatherMap API key ([get one](https://home.openweathermap.org/api_keys)) |
| `SECRET_KEY_BASE` | Prod only | Rails secret (`bin/rails secret`) |
| `REDIS_URL` | Prod only | Redis connection URL (default `redis://redis:6379/0`) |
| `CLOUDFLARE_TUNNEL_TOKEN` | No | Cloudflare Tunnel token for zero-trust access |
| `MAPBOX_QUOTA_OFFSET` | No | Added to tracked Mapbox monthly usage (default `0`) |
| `OPENWEATHERMAP_QUOTA_OFFSET` | No | Added to tracked OpenWeatherMap monthly usage (default `0`) |

## Setup

### Local

```bash
cd weather_forecast
bundle install
cp .env.example .env
# Add your MAPBOX_API_KEY and OPENWEATHERMAP_API_KEY
bin/dev
```

Open http://localhost:3000

### Docker

```bash
cp .env.example .env
# Add API keys, SECRET_KEY_BASE (rails secret), optionally CLOUDFLARE_TUNNEL_TOKEN
docker-compose up -d
```

Starts Rails, Redis, Nginx (port 80), and optionally a Cloudflare tunnel.

## Tests

```bash
bundle exec rspec                    # run full suite
bundle exec rspec --format documentation  # verbose output
bundle exec rspec spec/services/     # run service specs only
bundle exec rspec spec/requests/     # run request specs only
```

Covers services, request cycle, and cache behavior (94 examples). No API keys or network access needed — all HTTP calls are stubbed with WebMock.

## Tradeoffs

| Decision | Trade |
|----------|-------|
| Memory cache in dev | Simple, no persistence — Redis in prod |
| Mapbox over Google | Generous free tier, maybe less accurate |
| No database | Can't store history or favorites |
| Pico CSS via CDN | No build step, less customization |
| Cache by zip | Efficient for nearby addresses, less granular than lat/lng |
| Service objects | More files, but thin controller and isolated tests |
| Debug panel in all environments | This is a portfolio project — the panel shows cache status and quota usage to demonstrate how the internals work |

## License

[MIT](LICENSE)
