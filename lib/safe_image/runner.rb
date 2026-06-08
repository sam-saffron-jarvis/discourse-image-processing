# frozen_string_literal: true

require "open3"
require "tmpdir"
require "timeout"

module SafeImage
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
    MAX_OUTPUT_BYTES = 512 * 1024
    TRUSTED_PATH = "/usr/bin:/bin:/usr/local/bin".freeze
    ALLOWED_ENV_KEYS = %w[LANG LC_ALL LC_CTYPE TZ].freeze
    IMAGEMAGICK_POLICY_PATH = File.expand_path("imagemagick_policy", __dir__)
    IMAGEMAGICK_POLICY_FILE = File.join(IMAGEMAGICK_POLICY_PATH, "policy.xml").freeze
    BASE_ENV = {
      "PATH" => TRUSTED_PATH,
      "VIPS_BLOCK_UNTRUSTED" => "1"
    }.freeze

    def run!(argv, timeout: DEFAULT_TIMEOUT, env: {}, sandbox: false, read: [], write: [])
      raise ArgumentError, "empty command" if argv.nil? || argv.empty?
      argv = argv.map(&:to_s)
      argv[0] = resolve_executable!(argv[0])
      ensure_imagemagick_policy! if imagemagick_command?(File.basename(argv[0]))

      Dir.mktmpdir("safe-image-command-") do |tmpdir|
        child_env = command_env(tmpdir, env)

        if sandbox || SafeImage.sandbox_enabled?
          return Sandbox.capture_command!(argv, read: read, write: [*write, tmpdir], timeout: timeout, env: child_env)
        end

        return run_process!(argv, child_env, timeout: timeout)
      end
    end

    def run_process!(argv, child_env, timeout:)
      stdout = +"".b
      stderr = +"".b
      status = nil

      Open3.popen3(child_env, *argv, unsetenv_others: true, pgroup: true) do |stdin, out, err, wait_thr|
        stdin.close
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        streams = { out => stdout, err => stderr }

        until streams.empty?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            kill_process_group(wait_thr.pid)
            raise CommandError.new("command timed out after #{timeout}s", command: argv, stdout: stdout, stderr: stderr)
          end

          readable, = IO.select(streams.keys, nil, nil, remaining)
          next unless readable

          readable.each do |io|
            begin
              chunk = io.read_nonblock(16 * 1024)
              buffer = streams.fetch(io)
              buffer << chunk
              if buffer.bytesize > MAX_OUTPUT_BYTES
                kill_process_group(wait_thr.pid)
                raise CommandError.new("command output exceeded #{MAX_OUTPUT_BYTES} bytes", command: argv, stdout: stdout, stderr: stderr)
              end
            rescue IO::WaitReadable
              next
            rescue EOFError
              streams.delete(io)
              io.close
            end
          end
        end

        status = wait_thr.value
      rescue CommandError
        raise
      rescue Exception
        kill_process_group(wait_thr.pid) if wait_thr
        raise
      end

      return [stdout, stderr] if status&.success?

      raise CommandError.new(
        "command failed: #{argv.first} exited #{status&.exitstatus}",
        command: argv,
        status: status&.exitstatus,
        stdout: stdout,
        stderr: stderr
      )
    end

    def kill_process_group(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH, Errno::EPERM
    ensure
      begin
        sleep 0.2
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
      end
    end

    def command_env(tmpdir, env = {})
      allowed = env.each_with_object({}) do |(key, value), hash|
        key = key.to_s
        hash[key] = value.to_s if ALLOWED_ENV_KEYS.include?(key)
      end

      BASE_ENV.merge(
        "MAGICK_CONFIGURE_PATH" => IMAGEMAGICK_POLICY_PATH,
        "MAGICK_TEMPORARY_PATH" => tmpdir,
        "HOME" => tmpdir,
        "XDG_CACHE_HOME" => tmpdir,
        "TMPDIR" => tmpdir
      ).merge(allowed)
    end

    def ensure_imagemagick_policy!
      raise Error, "missing ImageMagick policy: #{IMAGEMAGICK_POLICY_FILE}" unless File.file?(IMAGEMAGICK_POLICY_FILE)
    end

    def imagemagick_command?(name)
      %w[magick convert identify compare].include?(name.to_s)
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
