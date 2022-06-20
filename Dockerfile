FROM ruby:3.0.2-alpine3.14 AS ruby-base

RUN apk --update upgrade

# --- Build image
FROM ruby-base
WORKDIR /app

# bundle install deps
RUN apk add ca-certificates git build-base openssl-dev
RUN gem install bundler -v '>= 2'

# bundle install
COPY Gemfile* ./
RUN bundle

# --- Runtime image
FROM ruby:3.0.2-alpine3.14
WORKDIR /app

COPY --from=1 /usr/local/bundle /usr/local/bundle
RUN apk add ca-certificates

COPY . .
RUN addgroup -g 1000 -S app \
  && adduser -u 1000 -S app -G app \
  && chown -R app: .

USER app
ENTRYPOINT ["bundle", "exec", "ruby", "main.rb", "dl"]
