# frozen_string_literal: true

require "open3"
require_relative "test_helper"

module SafeImage
  # Strict (:sandbox) execution must raise when the Landlock sandbox is
  # unavailable rather than silently degrading to inline execution.
  #
  # Exercised in a child process with RubyGems disabled (plus explicit load
  # paths for the gem's runtime deps), so the landlock gem is genuinely
  # unloadable there — no stubbing, and no skip on hosts where landlock is
  # bundled for SandboxIntegrationTest.
  class SandboxEnforcementTest < TestCase
    SCRIPT = <<~'RUBY'
      require "safe_image"
      abort "landlock unexpectedly loadable in the child" if SafeImage.sandbox_available?

      begin
        SafeImage.thumbnail(input: ARGV[0], output: ARGV[1], width: 10, height: 10, execution: :sandbox)
        print "no error"
      rescue SafeImage::Error => e
        print e.message
      end
    RUBY

    def test_strict_execution_does_not_fall_back_to_inline
      # Bundler's RUBYOPT would re-add the full bundle (landlock included) to
      # the child's load path, so scrub it alongside disabling RubyGems.
      env = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil }
      command = [RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__)]
      # rexml is a bundled gem; expose its load path to the gem-less child.
      rexml_lib = $LOAD_PATH.find { |path| path.include?("rexml") }
      command += ["-I", rexml_lib] if rexml_lib

      stdout, stderr, status = Open3.capture3(env, *command, "-e", SCRIPT, JPG, tmp_path("never-written.jpg"))

      assert status.success?, "sandbox-less child process failed:\n#{stderr}"
      assert_includes stdout, "sandbox execution requested"
      refute_path_exists tmp_path("never-written.jpg"), "strict sandbox mode fell back to inline execution"
    end
  end
end
