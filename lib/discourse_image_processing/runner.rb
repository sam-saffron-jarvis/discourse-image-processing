# frozen_string_literal: true

require "open3"
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
    SAFE_ENV = {
      "PATH" => "/usr/local/bin:/usr/bin:/bin",
      "MAGICK_CONFIGURE_PATH" => "/dev/null",
      "VIPS_BLOCK_UNTRUSTED" => "1"
    }.freeze

    def run!(argv, timeout: DEFAULT_TIMEOUT, env: {})
      raise ArgumentError, "empty command" if argv.nil? || argv.empty?
      argv = argv.map(&:to_s)

      stdout = stderr = status = nil
      begin
        Timeout.timeout(timeout) do
          stdout, stderr, status = Open3.capture3(SAFE_ENV.merge(env), *argv, unsetenv_others: true)
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
      ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, name)
        File.file?(path) && File.executable?(path)
      end
    end
  end
end
