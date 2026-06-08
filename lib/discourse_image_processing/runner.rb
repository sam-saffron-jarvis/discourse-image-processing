# frozen_string_literal: true

require "open3"
require "tmpdir"
require "timeout"

module DiscourseImageProcessing
  class CommandError < Error
    attr_reader :command, :status, :stdout, :stderr

    def initialize(message, command:, status: nil, stdout: "", stderr: "")
      super(message)
      @command = command
      @status = status
      @stdout = stdout
      @stderr = stderr
    end
  end

  module Runner
    module_function

    DEFAULT_TIMEOUT = 20
    TRUSTED_PATH = "/usr/bin:/bin:/usr/local/bin".freeze
    PROTECTED_ENV_KEYS = %w[PATH MAGICK_CONFIGURE_PATH MAGICK_TEMPORARY_PATH].freeze
    IMAGEMAGICK_POLICY_PATH = File.expand_path("imagemagick_policy", __dir__)
    SAFE_ENV = {
      "PATH" => TRUSTED_PATH,
      "MAGICK_CONFIGURE_PATH" => IMAGEMAGICK_POLICY_PATH,
      "MAGICK_TEMPORARY_PATH" => Dir.tmpdir,
      "VIPS_BLOCK_UNTRUSTED" => "1"
    }.freeze

    def run!(argv, timeout: DEFAULT_TIMEOUT, env: {}, sandbox: false, read: [], write: [])
      raise ArgumentError, "empty command" if argv.nil? || argv.empty?
      argv = argv.map(&:to_s)
      argv[0] = resolve_executable!(argv[0])
      child_env = SAFE_ENV.merge(env.reject { |key, _| PROTECTED_ENV_KEYS.include?(key.to_s) })

      if sandbox || DiscourseImageProcessing.sandbox_enabled?
        return Sandbox.capture_command!(argv, read: read, write: write, timeout: timeout, env: child_env)
      end

      stdout = stderr = status = nil
      begin
        Timeout.timeout(timeout) do
          stdout, stderr, status = Open3.capture3(child_env, *argv, unsetenv_others: true)
        end
      rescue Timeout::Error
        raise CommandError.new("command timed out after #{timeout}s", command: argv)
      end

      return [stdout, stderr] if status.success?

      raise CommandError.new(
        "command failed: #{argv.first} exited #{status.exitstatus}",
        command: argv,
        status: status.exitstatus,
        stdout: stdout,
        stderr: stderr
      )
    end

    def available?(name)
      !!resolve_executable(name)
    end

    def resolve_executable!(name)
      resolve_executable(name) || raise(UnsupportedFormatError, "missing executable: #{name}")
    end

    def resolve_executable(name)
      name = name.to_s
      return name if name.include?(File::SEPARATOR) && File.file?(name) && File.executable?(name)

      TRUSTED_PATH.split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end

      nil
    end
  end
end
