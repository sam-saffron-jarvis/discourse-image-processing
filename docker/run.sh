#!/bin/bash
# Runs the test suite inside a Debian bookworm container against the stock
# packaged libvips (8.14) with no toolchain installed, validating both the
# oldest supported libvips and the no-compile gem install.
set -euo pipefail

cd "$(dirname "$0")/.."
docker build -f docker/bookworm.dockerfile -t safe-image-bookworm-test .
exec docker run --rm safe-image-bookworm-test
