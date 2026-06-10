# Validates safe_image against the oldest supported distro libvips: Debian
# bookworm's stock 8.14 package. Deliberately installs NO build-essential,
# NO pkg-config and NO libvips-dev — the gem must install and run with
# runtime packages only (the libvips binding is pure Ruby via Fiddle).
#
# Build/run from the repository root via docker/run.sh.
FROM ruby:3.4-slim-bookworm

RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    libvips42 imagemagick jpegoptim pngquant libjpeg-turbo-progs fonts-dejavu-core \
    wget ca-certificates >/dev/null

# oxipng has no bookworm package; static musl build, pinned like
# discourse_docker's install-oxipng.
ARG OXIPNG_VERSION=9.1.2
ARG OXIPNG_HASH=211d53f3781be4a71566fbaad6611a3da018ac9b22d500651b091c2b42ebe318
RUN wget -q "https://github.com/shssoichiro/oxipng/releases/download/v${OXIPNG_VERSION}/oxipng-${OXIPNG_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
 && echo "${OXIPNG_HASH}  oxipng-${OXIPNG_VERSION}-x86_64-unknown-linux-musl.tar.gz" | sha256sum -c \
 && tar --strip-components=1 -xzf oxipng-${OXIPNG_VERSION}-*.tar.gz "oxipng-${OXIPNG_VERSION}-x86_64-unknown-linux-musl/oxipng" \
 && mv oxipng /usr/local/bin/ && rm oxipng-${OXIPNG_VERSION}-*.tar.gz

COPY . /safe_image
WORKDIR /safe_image

# Prove the no-toolchain install claim, then run the suite against the
# installed gem's environment. minitest is pinned to the gemspec line.
RUN gem build safe_image.gemspec \
 && gem install ./safe_image-*.gem \
 && gem install --no-document minitest:5.25.4 rake

CMD ["ruby", "-Itest", "-e", "Dir['test/**/*_test.rb'].each { |f| require File.expand_path(f) }"]
