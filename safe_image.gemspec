# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "safe_image"
  spec.version = File.read(File.expand_path("lib/safe_image/version.rb", __dir__)).match(/VERSION = "([^"]+)"/)[1]
  spec.summary = "Hardened image processing boundary for untrusted uploads"
  spec.description = "Safe Image is a small Ruby image-processing boundary for untrusted uploads: direct libvips thumbnails/probing, hardened ImageMagick compatibility operations, optimisation, SVG sanitising, and optional atomic Landlock sandbox execution."
  spec.homepage = "https://github.com/sam-saffron-jarvis/safe-image"
  spec.license = "MIT"
  spec.authors = ["Sam Saffron", "Jarvis"]
  spec.email = ["sam@discourse.org"]
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "ext/**/*.{c,rb}", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/safe_image_native/extconf.rb"]

  spec.add_runtime_dependency "rexml", "~> 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }
end
