# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

module SafeImage
  module Sandbox
    module_function

    DEFAULT_RLIMITS = {
      cpu_seconds: 30,
      memory_bytes: 2 * 1024 * 1024 * 1024,
      file_size_bytes: 1024 * 1024 * 1024,
      open_files: 256
    }.freeze

    OPERATIONS = %w[
      probe thumbnail type size dimensions info orientation optimize resize crop downsize convert_to_jpeg fix_orientation
      convert_favicon_to_png frame_count animated? letter_avatar optimize_image!
      sanitize_svg!
    ].freeze

    def available?
      require "landlock"
      Landlock::SafeExec.supported?
    rescue LoadError
      false
    end

    def capture_command!(argv, read:, write:, timeout: Runner::DEFAULT_TIMEOUT, env: Runner::SAFE_ENV, rlimits: DEFAULT_RLIMITS)
      require "landlock"

      result = Landlock::SafeExec.capture!(
        *argv.map(&:to_s),
        read: existing_paths([*Landlock::SafeExec.default_read_paths, *runtime_read_paths, *read]),
        write: existing_paths(write),
        execute: existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
        env: env.merge("SAFE_IMAGE_SANDBOX_CHILD" => "1"),
        inherit_env: false,
        timeout: timeout,
        rlimits: rlimits,
        seccomp_deny_network: true,
        max_output_bytes: 512 * 1024,
        truncate_output: false
      )
      [result.stdout, result.stderr]
    rescue LoadError
      raise Error, "landlock sandbox requested but the landlock gem is unavailable"
    rescue Landlock::SafeExec::CommandError => e
      raise CommandError.new(
        "sandboxed command failed",
        command: argv,
        status: e.status&.exitstatus,
        stdout: e.stdout,
        stderr: e.stderr
      )
    end

    def public_call!(operation, args:, kwargs:)
      operation = operation.to_s
      raise ArgumentError, "unsupported sandbox operation: #{operation}" unless OPERATIONS.include?(operation)
      result = run_worker!(operation, { args: args, kwargs: kwargs })
      operation == "type" && result ? result.to_sym : result
    end

    def thumbnail(request)
      public_call!(
        :thumbnail,
        args: [],
        kwargs: request.merge(execution: :inline)
      )
    end

    def run_worker!(operation, request)
      operation = operation.to_s
      raise ArgumentError, "unsupported sandbox operation: #{operation}" unless OPERATIONS.include?(operation)

      require "landlock"
      payload = JSON.dump({ operation: operation, request: request })
      code = <<~'RUBY'
        require "json"
        require "safe_image"

        def deep_symbolize(value)
          case value
          when Hash
            value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
          when Array
            value.map { |v| deep_symbolize(v) }
          else
            value
          end
        end

        payload = JSON.parse(ARGV.fetch(0), symbolize_names: true)
        operation = payload.fetch(:operation).to_s
        allowed_operations = %w[
          probe thumbnail type size dimensions info orientation optimize resize crop downsize convert_to_jpeg fix_orientation
          convert_favicon_to_png frame_count animated? letter_avatar optimize_image! sanitize_svg!
        ]
        raise ArgumentError, "unsupported sandbox operation: #{operation}" unless allowed_operations.include?(operation)

        request = payload.fetch(:request)
        args = request[:args] || []
        kwargs = deep_symbolize(request[:kwargs] || {})

        result = SafeImage.with_sandbox_disabled do
          SafeImage.__send__(operation, *args, **kwargs)
        end

        if defined?(SafeImage::Result) && result.is_a?(SafeImage::Result)
          puts JSON.dump({ __type: "Result", data: result.to_h })
        elsif defined?(SafeImage::Info) && result.is_a?(SafeImage::Info)
          puts JSON.dump({ __type: "Info", data: result.to_h })
        else
          puts JSON.dump({ __type: "Value", data: result })
        end
      RUBY

      paths = sandbox_paths(request, operation)
      stdout, = Landlock::SafeExec.capture!(
        RbConfig.ruby,
        "-I#{File.expand_path("../../", __dir__)}",
        "-rjson",
        "-e",
        code,
        payload,
        read: existing_paths([*Landlock::SafeExec.default_read_paths, *runtime_read_paths, *paths.fetch(:read), Dir.tmpdir]),
        write: existing_paths([*paths.fetch(:write), Dir.tmpdir]),
        execute: existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
        env: Runner::SAFE_ENV.merge(
          "SAFE_IMAGE_SANDBOX_CHILD" => "1",
          "GEM_HOME" => ENV["GEM_HOME"].to_s,
          "GEM_PATH" => ENV["GEM_PATH"].to_s,
          "RUBYLIB" => $LOAD_PATH.select { |p| p && File.directory?(p) }.join(File::PATH_SEPARATOR)
        ),
        inherit_env: false,
        timeout: Runner::DEFAULT_TIMEOUT,
        rlimits: DEFAULT_RLIMITS,
        seccomp_deny_network: true,
        max_output_bytes: 512 * 1024,
        truncate_output: false
      )
      response = JSON.parse(stdout, symbolize_names: true)
      if response[:__type] == "Result"
        data = response.fetch(:data)
        Result.new(**data)
      elsif response[:__type] == "Info"
        data = response.fetch(:data)
        Info.new(**data)
      else
        response[:data]
      end
    rescue LoadError
      nil
    rescue Landlock::SafeExec::CommandError => e
      raise CommandError.new(
        "sandboxed worker failed",
        command: [RbConfig.ruby, "-e", "..."],
        status: e.status&.exitstatus,
        stdout: e.stdout,
        stderr: e.stderr
      )
    end

    def sandbox_paths(request, operation)
      read = []
      write = []

      values = []
      values.concat(Array(request[:args]))
      values.concat(Array(request.dig(:kwargs)&.values))
      values.flatten.compact.each do |value|
        next unless value.is_a?(String)
        next if value.empty? || value.include?("\0")

        expanded = File.expand_path(value) rescue next
        if File.exist?(expanded)
          read << expanded
        elsif looks_like_path?(value)
          write << File.dirname(expanded)
        end
      end

      # Common keyword names for generated outputs. Include the containing dir
      # even when a stale file already exists, because operations may replace it.
      kwargs = request[:kwargs] || {}
      %i[output to path].each do |key|
        next unless kwargs[key].is_a?(String)
        write << File.dirname(File.expand_path(kwargs[key]))
      end

      # In-place mutators need write permission for an existing input path too.
      if %w[optimize optimize_image! sanitize_svg! fix_orientation].include?(operation.to_s)
        first = Array(request[:args]).first
        write << File.expand_path(first) if first.is_a?(String) && File.exist?(first)
      end

      { read: read.uniq, write: write.uniq }
    end

    def looks_like_path?(value)
      value.start_with?("/", "./", "../") || File.extname(value) != ""
    end

    def runtime_read_paths
      paths = []
      paths.concat(Gem.path) if defined?(Gem)
      paths.concat($LOAD_PATH.select { |path| path && path != "." })
      paths << RbConfig::CONFIG["rubylibdir"]
      paths << RbConfig::CONFIG["rubyarchdir"]
      paths << RbConfig::CONFIG["sitearchdir"]
      paths << RbConfig::CONFIG["vendorarchdir"]
      paths << File.dirname(RbConfig.ruby)
      paths
    end

    def existing_paths(paths)
      paths.flatten.compact.map(&:to_s).reject(&:empty?).select { |path| File.exist?(path) }.uniq
    end

    def symbolize(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end
