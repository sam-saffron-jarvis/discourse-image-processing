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
      probe thumbnail type size dimensions info orientation dominant_color optimize resize crop downsize convert convert_to_jpeg fix_orientation
      convert_favicon_to_png frame_count animated? letter_avatar optimize_image!
      sanitize_svg!
    ].freeze

    def available?
      require "landlock"
      Landlock::SafeExec.supported?
    rescue LoadError
      false
    end

    def capture_command!(argv, read:, write:, timeout: Runner::DEFAULT_TIMEOUT, env: nil, rlimits: DEFAULT_RLIMITS)
      require "landlock"
      env ||= Runner.command_env(Dir.tmpdir)

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
        "sandboxed command failed: #{failure_detail(e)}",
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

    def run_worker!(operation, request)
      operation = operation.to_s
      raise ArgumentError, "unsupported sandbox operation: #{operation}" unless OPERATIONS.include?(operation)

      require "landlock"
      config = SafeImage.config
      payload = JSON.dump(
        {
          operation: operation,
          # JSON has no symbol type; wrap symbol values so the worker can restore
          # them (e.g. id_namespace: :standalone must not arrive as the string
          # "standalone", which resolve_namespace would treat as a real namespace).
          request: deep_encode_symbols(request),
          # The worker is a fresh process and must be configured like the
          # parent — minus landlock, since it already runs inside the sandbox.
          config: { backend: config.backend, max_pixels: config.max_pixels }
        }
      )
      code = <<~'RUBY'
        require "json"
        require "safe_image"

        def deep_symbolize(value)
          case value
          when Hash
            # {"__sym__" => "x"} is a symbol value the parent wrapped for transport.
            return value[:__sym__].to_sym if value.size == 1 && value[:__sym__].is_a?(String)
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
          probe thumbnail type size dimensions info orientation dominant_color optimize resize crop downsize convert convert_to_jpeg fix_orientation
          convert_favicon_to_png frame_count animated? letter_avatar optimize_image! sanitize_svg!
        ]
        raise ArgumentError, "unsupported sandbox operation: #{operation}" unless allowed_operations.include?(operation)

        request = deep_symbolize(payload.fetch(:request))
        args = request[:args] || []
        kwargs = request[:kwargs] || {}

        config = payload.fetch(:config)
        SafeImage.configure!(
          backend: config.fetch(:backend).to_sym,
          landlock: false,
          max_pixels: config.fetch(:max_pixels)
        )

        result = SafeImage.__send__(operation, *args, **kwargs)

        if defined?(SafeImage::Result) && result.is_a?(SafeImage::Result)
          puts JSON.dump({ __type: "Result", data: result.to_h })
        elsif defined?(SafeImage::Info) && result.is_a?(SafeImage::Info)
          puts JSON.dump({ __type: "Info", data: result.to_h })
        else
          puts JSON.dump({ __type: "Value", data: result })
        end
      RUBY

      paths = sandbox_paths(request, operation)
      Dir.mktmpdir("safe-image-worker-") do |tmpdir|
        worker_env = Runner.command_env(tmpdir).merge(
          "SAFE_IMAGE_SANDBOX_CHILD" => "1",
          "GEM_HOME" => ENV["GEM_HOME"].to_s,
          "GEM_PATH" => ENV["GEM_PATH"].to_s,
          "RUBYLIB" => $LOAD_PATH.select { |p| p && File.directory?(p) }.join(File::PATH_SEPARATOR)
        )

        stdout, = Landlock::SafeExec.capture!(
          RbConfig.ruby,
          "-I#{File.expand_path("../../", __dir__)}",
          "-rjson",
          "-e",
          code,
          payload,
          read: existing_paths([*Landlock::SafeExec.default_read_paths, *runtime_read_paths, *paths.fetch(:read), tmpdir]),
          write: existing_paths([*paths.fetch(:write), tmpdir]),
          execute: existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
          env: worker_env,
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
      end
    rescue LoadError
      raise Error, "landlock sandbox requested but the landlock gem is unavailable"
    rescue Landlock::SafeExec::CommandError => e
      raise CommandError.new(
        "sandboxed worker failed: #{failure_detail(e)}",
        command: [RbConfig.ruby, "-e", "..."],
        status: e.status&.exitstatus,
        stdout: e.stdout,
        stderr: e.stderr
      )
    end

    # JSON cannot represent symbols, so wrap symbol values as {"__sym__" => name}
    # for the worker's deep_symbolize to restore. Mirrors that decoder.
    def deep_encode_symbols(value)
      case value
      when Symbol
        { "__sym__" => value.to_s }
      when Hash
        value.transform_values { |v| deep_encode_symbols(v) }
      when Array
        value.map { |v| deep_encode_symbols(v) }
      else
        value
      end
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
        if first.is_a?(String) && File.exist?(first)
          expanded = File.expand_path(first)
          write << expanded
          write << File.dirname(expanded)
        end
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
      # An --enable-shared Ruby installed outside the default read roots
      # (e.g. GitHub Actions' /opt/hostedtoolcache builds) keeps libruby in
      # libdir; without read access the worker dies at dynamic-link time
      # before any Ruby code runs.
      paths << RbConfig::CONFIG["libdir"]
      paths << File.dirname(RbConfig.ruby)
      # Pango/fontconfig need the font directories and configs for the native
      # letter_avatar text rendering inside the worker.
      paths << "/etc/fonts"
      paths << "/usr/share/fonts"
      paths << "/usr/local/share/fonts"
      paths << "/var/cache/fontconfig"
      paths
    end

    def existing_paths(paths)
      paths.flatten.compact.map(&:to_s).reject(&:empty?).select { |path| File.exist?(path) }.uniq
    end

    # Sandbox failures often happen before the child can run any Ruby (e.g. a
    # denied shared-library read kills it at dynamic-link time); without the
    # child's stderr in the message they are undiagnosable from a CI log.
    def failure_detail(error)
      detail = error.stderr.to_s.strip
      detail = "exit status #{error.status&.exitstatus.inspect}" if detail.empty?
      detail[0, 2000]
    end

    def symbolize(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end
