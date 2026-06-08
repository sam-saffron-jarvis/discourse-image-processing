# frozen_string_literal: true

require "rake/extensiontask"

Rake::ExtensionTask.new("safe_image_native") do |ext|
  ext.lib_dir = "lib"
  ext.ext_dir = "ext/safe_image_native"
end

task default: [:compile, :test]

task :test => :compile do
  ruby "-Ilib -I. test/smoke.rb"
  ruby "-Ilib -I. test/compat_smoke.rb"
  ruby "-Ilib -I. test/golden_compat.rb"
  ruby "-Ilib -I. test/imagemagick_parity.rb"
  ruby "-Ilib -I. test/safety_policy.rb"
  ruby "-Ilib -I. test/local_metadata.rb"
  ruby "-Ilib -I. test/remote_metadata.rb"
  ruby "-Ilib -I. test/atomic_sandbox_all.rb"
end
