FROM ruby:3.4-alpine

RUN apk add --no-cache build-base git tzdata sqlite-dev sqlite yaml-dev

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

EXPOSE 3000

ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_SERVE_STATIC_FILES=true

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
