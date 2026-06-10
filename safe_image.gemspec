# frozen_string_literal: true

require_relative "lib/safe_image/version"

Gem::Specification.new do |spec|
  spec.name = "safe_image"
  spec.version = SafeImage::VERSION
  spec.summary = "Hardened image processing boundary for untrusted uploads"
  spec.description = "Safe Image is a small Ruby image-processing boundary for untrusted uploads: direct libvips thumbnails/probing, hardened ImageMagick compatibility operations, optimisation, SVG sanitising, and optional atomic Landlock sandbox execution."
  spec.homepage = "https://github.com/sam-saffron-jarvis/safe-image"
  spec.license = "MIT"
  spec.authors = ["Sam Saffron", "Jarvis"]
  spec.email = ["sam@discourse.org"]
  spec.required_ruby_version = ">= 3.1"

  # Explicit allowlist of shipped files.
  spec.files = Dir[
    "lib/**/*.rb",
    "lib/safe_image/RT_sRGB.icm",
    "lib/safe_image/imagemagick_policy/policy.xml",
    "lib/safe_image/fonts/DejaVuSans.ttf",
    "lib/safe_image/fonts/DEJAVU-LICENSE",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "CHANGELOG.md"
  ]
  spec.require_paths = ["lib"]

  # libvips is bound at runtime through Fiddle (stdlib today, a bundled gem
  # from Ruby 3.5); nothing compiles at install time.
  spec.add_runtime_dependency "fiddle", ">= 1.0"
  spec.add_runtime_dependency "rexml", "~> 3.4"

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop-discourse", "~> 3.18"
  # Exercises the Landlock sandbox tests (they skip when unavailable);
  # intentionally NOT a runtime dependency — see README.
  spec.add_development_dependency "landlock"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }
end
