source "https://rubygems.org"

gem "bootsnap", require: false
gem "dotenv-rails", groups: [:development, :test]
gem "httparty"
gem "puma", ">= 5.0"
gem "rails", "~> 8.1.2"
gem "sqlite3", ">= 2.1"
gem "tzinfo-data", platforms: %i[windows jruby]
gem 'redis', '~> 5.4'

group :development, :test do
  gem "brakeman", require: false
  gem "bundler-audit", require: false
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "rspec-rails"
  gem "rubocop-rails-omakase", require: false
  gem "webmock"
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end
