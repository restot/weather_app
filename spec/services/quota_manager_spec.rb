# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuotaManager do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    QuotaManager.clear_configurations!
    allow(Rails).to receive(:cache).and_return(memory_store)
  end

  shared_context "with rate limited provider" do
    before do
      QuotaManager.configure(:rate_limited, {
        requests_per_minute: 3,
        requests_per_month: 1000
      })
    end
  end

  shared_context "with quota limited provider" do
    before do
      QuotaManager.configure(:quota_limited, {
        requests_per_minute: 1000,
        requests_per_month: 5
      })
    end
  end

  describe ".configure" do
    it "configures a provider with the given limits" do
      QuotaManager.configure(:test_provider, {
        requests_per_minute: 100,
        requests_per_month: 10_000
      })

      expect(QuotaManager.configured_providers).to include(:test_provider)
    end

    it "accepts string provider names and converts to symbols" do
      QuotaManager.configure("string_provider", { requests_per_minute: 50 })

      expect(QuotaManager.configured_providers).to include(:string_provider)
    end

    it "merges with default configuration values" do
      QuotaManager.configure(:partial_config, { requests_per_minute: 100 })

      status = QuotaManager.status(:partial_config)
      expect(status[:limits][:per_minute]).to eq(100)
      expect(status[:limits][:per_month]).to be_nil
    end

    it "allows configuration for multiple providers" do
      QuotaManager.configure(:provider_a, { requests_per_minute: 100 })
      QuotaManager.configure(:provider_b, { requests_per_minute: 200 })

      expect(QuotaManager.configured_providers).to contain_exactly(:provider_a, :provider_b)
    end
  end

  describe ".request!" do
    context "when provider is not configured" do
      it "raises ProviderNotConfigured error" do
        expect { QuotaManager.request!(:unconfigured) }
          .to raise_error(QuotaManager::ProviderNotConfigured)
          .with_message(/unconfigured/)
      end
    end

    context "with per-minute rate limiting" do
      include_context "with rate limited provider"

      it "allows requests within rate limit" do
        expect { QuotaManager.request!(:rate_limited) }.not_to raise_error
      end

      it "raises RateLimitExceeded when rate limit is reached" do
        3.times { QuotaManager.track(:rate_limited) }

        expect { QuotaManager.request!(:rate_limited) }
          .to raise_error(QuotaManager::RateLimitExceeded)
          .with_message(/Rate limit exceeded for rate_limited/)
      end

      it "includes retry_after in RateLimitExceeded error" do
        3.times { QuotaManager.track(:rate_limited) }

        begin
          QuotaManager.request!(:rate_limited)
        rescue QuotaManager::RateLimitExceeded => e
          expect(e.retry_after).to be_a(Integer)
          expect(e.retry_after).to be_between(1, 60)
        end
      end
    end

    context "with per-second rate limiting" do
      before do
        QuotaManager.configure(:second_limited, {
          requests_per_second: 2,
          requests_per_month: 1000
        })
      end

      it "raises RateLimitExceeded when per-second limit is reached" do
        2.times { QuotaManager.track(:second_limited) }

        expect { QuotaManager.request!(:second_limited) }
          .to raise_error(QuotaManager::RateLimitExceeded)
      end
    end

    context "with monthly quota" do
      include_context "with quota limited provider"

      it "allows requests within quota" do
        4.times { QuotaManager.track(:quota_limited) }

        expect { QuotaManager.request!(:quota_limited) }.not_to raise_error
      end

      it "raises QuotaExceeded when monthly quota is reached" do
        5.times { QuotaManager.track(:quota_limited) }

        expect { QuotaManager.request!(:quota_limited) }
          .to raise_error(QuotaManager::QuotaExceeded)
          .with_message(/Monthly quota exceeded for quota_limited/)
      end

      it "checks quota before rate limit" do
        QuotaManager.configure(:both_limits, {
          requests_per_minute: 10,
          requests_per_month: 3
        })

        3.times { QuotaManager.track(:both_limits) }

        expect { QuotaManager.request!(:both_limits) }
          .to raise_error(QuotaManager::QuotaExceeded)
      end
    end
  end

  describe ".track" do
    before do
      QuotaManager.configure(:trackable, {
        requests_per_minute: 100,
        requests_per_month: 10_000
      })
    end

    it "increments usage counters" do
      expect { QuotaManager.track(:trackable) }
        .to change { QuotaManager.status(:trackable)[:requests_this_minute] }.by(1)
        .and change { QuotaManager.status(:trackable)[:requests_this_month] }.by(1)
    end

    it "raises ProviderNotConfigured for unconfigured providers" do
      expect { QuotaManager.track(:unknown) }
        .to raise_error(QuotaManager::ProviderNotConfigured)
    end

    it "persists usage in cache across calls" do
      3.times { QuotaManager.track(:trackable) }

      status = QuotaManager.status(:trackable)
      expect(status[:requests_this_minute]).to eq(3)
      expect(status[:requests_this_month]).to eq(3)
    end
  end

  describe ".status" do
    before do
      QuotaManager.configure(:status_test, {
        requests_per_second: 10,
        requests_per_minute: 100,
        requests_per_month: 10_000
      })
    end

    it "returns current usage statistics" do
      5.times { QuotaManager.track(:status_test) }

      status = QuotaManager.status(:status_test)

      expect(status[:provider]).to eq(:status_test)
      expect(status[:requests_this_second]).to eq(5)
      expect(status[:requests_this_minute]).to eq(5)
      expect(status[:requests_this_month]).to eq(5)
      expect(status[:limits]).to eq({
        per_second: 10,
        per_minute: 100,
        per_month: 10_000
      })
      expect(status[:within_limits]).to be(true)
    end

    it "shows within_limits as false when over limit" do
      100.times { QuotaManager.track(:status_test) }

      status = QuotaManager.status(:status_test)
      expect(status[:within_limits]).to be(false)
    end
  end

  describe ".within_limits?" do
    before do
      QuotaManager.configure(:limit_check, {
        requests_per_minute: 5,
        requests_per_month: 100
      })
    end

    it "returns true when within all limits" do
      expect(QuotaManager.within_limits?(:limit_check)).to be(true)
    end

    it "returns false when rate limit exceeded" do
      5.times { QuotaManager.track(:limit_check) }

      expect(QuotaManager.within_limits?(:limit_check)).to be(false)
    end

    it "returns false when quota exceeded" do
      QuotaManager.configure(:low_quota, {
        requests_per_minute: 1000,
        requests_per_month: 3
      })

      3.times { QuotaManager.track(:low_quota) }

      expect(QuotaManager.within_limits?(:low_quota)).to be(false)
    end

    it "returns false for unconfigured providers" do
      expect(QuotaManager.within_limits?(:not_configured)).to be(false)
    end
  end

  describe ".backoff_delay" do
    before do
      QuotaManager.configure(:backoff_test, {
        requests_per_minute: 100,
        backoff_base: 1.0,
        max_retries: 3
      })
    end

    it "calculates exponential backoff delay" do
      expect(QuotaManager.backoff_delay(:backoff_test, 0)).to eq(1.0)
      expect(QuotaManager.backoff_delay(:backoff_test, 1)).to eq(2.0)
      expect(QuotaManager.backoff_delay(:backoff_test, 2)).to eq(4.0)
    end

    it "respects custom backoff_base" do
      QuotaManager.configure(:custom_backoff, {
        requests_per_minute: 100,
        backoff_base: 2.0
      })

      expect(QuotaManager.backoff_delay(:custom_backoff, 0)).to eq(2.0)
    end

    it "caps delay at max_retries" do
      delay_at_max = QuotaManager.backoff_delay(:backoff_test, 3)
      delay_beyond_max = QuotaManager.backoff_delay(:backoff_test, 10)

      expect(delay_at_max).to be_within(0.5).of(delay_beyond_max)
    end
  end

  describe ".can_retry?" do
    before do
      QuotaManager.configure(:retry_test, {
        requests_per_minute: 100,
        max_retries: 3
      })
    end

    it "returns true when attempts are below max_retries" do
      expect(QuotaManager.can_retry?(:retry_test, 0)).to be(true)
      expect(QuotaManager.can_retry?(:retry_test, 1)).to be(true)
      expect(QuotaManager.can_retry?(:retry_test, 2)).to be(true)
    end

    it "returns false when attempts reach max_retries" do
      expect(QuotaManager.can_retry?(:retry_test, 3)).to be(false)
      expect(QuotaManager.can_retry?(:retry_test, 5)).to be(false)
    end
  end

  describe ".reset!" do
    before do
      QuotaManager.configure(:reset_test, {
        requests_per_minute: 100,
        requests_per_month: 1000
      })
    end

    it "clears all counters for the provider" do
      5.times { QuotaManager.track(:reset_test) }

      QuotaManager.reset!(:reset_test)

      status = QuotaManager.status(:reset_test)
      expect(status[:requests_this_second]).to eq(0)
      expect(status[:requests_this_minute]).to eq(0)
      expect(status[:requests_this_month]).to eq(0)
    end
  end

  describe "error classes" do
    describe QuotaManager::RateLimitExceeded do
      it "stores provider and retry_after" do
        error = QuotaManager::RateLimitExceeded.new(:test_provider, 30)

        expect(error.provider).to eq(:test_provider)
        expect(error.retry_after).to eq(30)
        expect(error.message).to include("test_provider")
        expect(error.message).to include("30")
      end

      it "handles nil retry_after" do
        error = QuotaManager::RateLimitExceeded.new(:test_provider)

        expect(error.retry_after).to be_nil
        expect(error.message).not_to include("retry after")
      end
    end

    describe QuotaManager::QuotaExceeded do
      it "stores provider" do
        error = QuotaManager::QuotaExceeded.new(:test_provider)

        expect(error.provider).to eq(:test_provider)
        expect(error.message).to include("test_provider")
      end
    end

    describe QuotaManager::ProviderNotConfigured do
      it "stores provider" do
        error = QuotaManager::ProviderNotConfigured.new(:missing)

        expect(error.provider).to eq(:missing)
        expect(error.message).to include("missing")
      end
    end
  end

  describe "quota offset" do
    before do
      QuotaManager.configure(:mapbox, {
        requests_per_minute: 600,
        requests_per_month: 100
      })
      allow(ENV).to receive(:[]).and_call_original
    end

    it "adds offset to monthly_usage" do
      allow(ENV).to receive(:[]).with("MAPBOX_QUOTA_OFFSET").and_return("5")

      3.times { QuotaManager.track(:mapbox) }

      status = QuotaManager.status(:mapbox)
      expect(status[:requests_this_month]).to eq(8)
    end

    it "triggers QuotaExceeded when actual + offset >= limit" do
      allow(ENV).to receive(:[]).with("MAPBOX_QUOTA_OFFSET").and_return("95")

      5.times { QuotaManager.track(:mapbox) }

      expect { QuotaManager.request!(:mapbox) }
        .to raise_error(QuotaManager::QuotaExceeded)
    end

    it "defaults to 0 when env var is unset" do
      allow(ENV).to receive(:[]).with("MAPBOX_QUOTA_OFFSET").and_return(nil)

      3.times { QuotaManager.track(:mapbox) }

      status = QuotaManager.status(:mapbox)
      expect(status[:requests_this_month]).to eq(3)
      expect(status[:quota_offset]).to eq(0)
    end

    it "exposes offset in status" do
      allow(ENV).to receive(:[]).with("MAPBOX_QUOTA_OFFSET").and_return("42")

      status = QuotaManager.status(:mapbox)
      expect(status[:quota_offset]).to eq(42)
    end
  end

  describe "cache expiration" do
    before do
      QuotaManager.configure(:expiry_test, {
        requests_per_second: 10,
        requests_per_minute: 100,
        requests_per_month: 1000
      })
    end

    it "uses appropriate cache keys based on time periods" do
      QuotaManager.track(:expiry_test)

      status = QuotaManager.status(:expiry_test)
      expect(status[:requests_this_second]).to eq(1)
      expect(status[:requests_this_minute]).to eq(1)
      expect(status[:requests_this_month]).to eq(1)
    end
  end

  describe "integration with multiple providers" do
    before do
      QuotaManager.configure(:mapbox, {
        requests_per_minute: 600,
        requests_per_month: 100_000
      })

      QuotaManager.configure(:openweathermap, {
        requests_per_minute: 60,
        requests_per_month: 1_000_000
      })
    end

    it "tracks usage independently per provider" do
      5.times { QuotaManager.track(:mapbox) }
      3.times { QuotaManager.track(:openweathermap) }

      mapbox_status = QuotaManager.status(:mapbox)
      owm_status = QuotaManager.status(:openweathermap)

      expect(mapbox_status[:requests_this_minute]).to eq(5)
      expect(owm_status[:requests_this_minute]).to eq(3)
    end

    it "enforces limits independently per provider" do
      QuotaManager.configure(:low_limit, { requests_per_minute: 2 })
      QuotaManager.configure(:high_limit, { requests_per_minute: 100 })

      2.times { QuotaManager.track(:low_limit) }
      2.times { QuotaManager.track(:high_limit) }

      expect { QuotaManager.request!(:low_limit) }
        .to raise_error(QuotaManager::RateLimitExceeded)

      expect { QuotaManager.request!(:high_limit) }.not_to raise_error
    end
  end
end
