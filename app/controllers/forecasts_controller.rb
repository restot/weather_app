# frozen_string_literal: true

class ForecastsController < ApplicationController
  before_action :set_debug_info

  def new
  end

  def create
    unless params[:address].present?
      flash.now[:error] = "Please enter an address (US Only)"
      return render :new
    end

    result = ForecastService.new(params[:address], bypass_cache: params[:bypass_cache].present?).call

    @forecast = result[:data]
    @location = result[:location]
    @cached = result[:cached]
    @cache_details = result[:cache_details]

    render :show
  rescue GeocodingService::GeocodingError, WeatherService::WeatherError => e
    flash.now[:error] = e.message
    render :new
  end

  private

  def set_debug_info
    @quota_status = QuotaManager.configured_providers.each_with_object({}) do |provider, hash|
      hash[provider] = QuotaManager.status(provider)
    end
  end
end
