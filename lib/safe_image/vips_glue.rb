# frozen_string_literal: true

require "fiddle"

module SafeImage
  # Minimal Fiddle binding for libvips. Instead of libvips' variadic C
  # convenience API, operations are invoked through the fixed-signature
  # GObject layer: vips_operation_new -> set properties as GValues ->
  # vips_cache_operation_build -> read outputs -> unref. The invocation
  # pattern is modelled on ruby-vips (MIT, Copyright (c) 2016 John Cupitt,
  # https://github.com/libvips/ruby-vips), trimmed to exactly the operations
  # SafeImage::Native performs — the function table below doubles as an
  # operation allowlist.
  module VipsGlue
    GVALUE_SIZE = 24
    GVALUE_ZERO = ("\0" * GVALUE_SIZE).freeze
    # Public, decades-stable GParamSpec ABI: GTypeInstance(8) + name(8) +
    # flags(4 + padding) puts value_type at byte 24.
    PSPEC_VALUE_TYPE_OFFSET = 24

    LIBRARY_CANDIDATES = %w[libvips.so.42 libvips.42.dylib libvips.dylib libvips.so].freeze

    TYPE = {
      void: Fiddle::TYPE_VOID,
      int: Fiddle::TYPE_INT,
      double: Fiddle::TYPE_DOUBLE,
      size_t: Fiddle::TYPE_SIZE_T,
      ptr: Fiddle::TYPE_VOIDP
    }.freeze

    # Fixed-signature entry points only; no varargs anywhere. The g_*
    # symbols resolve through the libvips handle via its GLib dependency.
    SIGNATURES = {
      vips_init: [%i[ptr], :int],
      vips_version: [%i[int], :int],
      vips_error_buffer: [[], :ptr],
      vips_error_clear: [[], :void],
      vips_block_untrusted_set: [%i[int], :void],
      vips_operation_block_set: [%i[ptr int], :void],
      vips_concurrency_set: [%i[int], :void],
      vips_cache_set_max: [%i[int], :void],
      vips_cache_set_max_mem: [%i[size_t], :void],
      vips_cache_set_max_files: [%i[int], :void],
      vips_type_find: [%i[ptr ptr], :size_t],
      vips_enum_from_nick: [%i[ptr size_t ptr], :int],
      vips_operation_new: [%i[ptr], :ptr],
      vips_cache_operation_build: [%i[ptr], :ptr],
      vips_object_unref_outputs: [%i[ptr], :void],
      vips_value_set_array_double: [%i[ptr ptr int], :void],
      vips_image_get_width: [%i[ptr], :int],
      vips_image_get_height: [%i[ptr], :int],
      vips_image_get_bands: [%i[ptr], :int],
      vips_image_get_n_pages: [%i[ptr], :int],
      vips_image_get_orientation: [%i[ptr], :int],
      vips_image_hasalpha: [%i[ptr], :int],
      vips_colourspace_issupported: [%i[ptr], :int],
      vips_image_new_from_memory_copy: [%i[ptr size_t int int int int], :ptr],
      vips_image_write_to_memory: [%i[ptr ptr], :ptr],
      g_object_ref: [%i[ptr], :ptr],
      g_object_unref: [%i[ptr], :void],
      g_object_set_property: [%i[ptr ptr ptr], :void],
      g_object_get_property: [%i[ptr ptr ptr], :void],
      g_object_class_find_property: [%i[ptr ptr], :ptr],
      g_value_init: [%i[ptr size_t], :ptr],
      g_value_unset: [%i[ptr], :void],
      g_value_set_boolean: [%i[ptr int], :void],
      g_value_set_int: [%i[ptr int], :void],
      g_value_set_double: [%i[ptr double], :void],
      g_value_set_string: [%i[ptr ptr], :void],
      g_value_set_enum: [%i[ptr int], :void],
      g_value_set_flags: [%i[ptr int], :void],
      g_value_set_object: [%i[ptr ptr], :void],
      g_value_get_object: [%i[ptr], :ptr],
      g_type_fundamental: [%i[size_t], :size_t],
      g_type_from_name: [%i[ptr], :size_t],
      g_free: [%i[ptr], :void]
    }.freeze

    @initialized = false
    @load_error = nil
    @init_mutex = Mutex.new

    class << self
      def init!
        return if @initialized
        raise @load_error if @load_error

        @init_mutex.synchronize do
          next if @initialized
          raise @load_error if @load_error

          handle = open_library
          @functions = SIGNATURES.to_h do |name, (args, ret)|
            address = handle[name.to_s]
            [name, Fiddle::Function.new(address, args.map { |t| TYPE.fetch(t) }, TYPE.fetch(ret))]
          end

          silence_vips_log!
          raise Error, "vips_init failed: #{error_message}" if c(:vips_init, "safe_image") != 0

          major = c(:vips_version, 0)
          minor = c(:vips_version, 1)
          @version = [major, minor]
          raise Error, "libvips >= 8.13 is required (found #{major}.#{minor})" if (@version <=> [8, 13]).negative?

          harden!
          resolve_gtypes!
          @initialized = true
        end
      end

      def version
        init!
        @version
      end

      # True when libvips loaded (or loads) successfully. A load failure is
      # memoized; the gem keeps working through the ImageMagick paths.
      def available?
        init!
        true
      rescue VipsUnavailableError
        false
      end

      # Calls a bound C function by name.
      def c(name, *args)
        @functions.fetch(name).call(*args)
      end

      def error!
        message = error_message
        c(:vips_error_clear)
        raise InvalidImageError, message
      end

      def error_message
        ptr = c(:vips_error_buffer)
        message = ptr.null? ? "" : ptr.to_s
        message.empty? ? "libvips error" : message.strip
      end

      def type_find?(nickname)
        init!
        !c(:vips_type_find, "VipsOperation", nickname).zero?
      end

      def unref(image_ptr)
        c(:g_object_unref, image_ptr) if image_ptr && !image_ptr.null?
      end

      # Tracks every acquired VipsImage pointer and releases all of them when
      # the block exits, success or failure. Pipelines are strictly linear,
      # so deterministic unref in reverse order is sufficient.
      def with_images
        acquired = []
        track = lambda do |ptr|
          acquired << ptr
          ptr
        end
        init!
        yield track
      ensure
        acquired.reverse_each { |ptr| unref(ptr) }
      end

      # Invokes one vips operation. Property values are converted according
      # to the property's GType: booleans, ints, doubles, strings, enums
      # (given as nick strings), flags, double arrays and VipsImage pointers.
      # Returns the named output image pointer (caller owns one reference),
      # or nil when output is nil (savers).
      def operation(nickname, inputs, output: "out")
        op = c(:vips_operation_new, nickname)
        raise UnsupportedFormatError, "unknown vips operation: #{nickname}" if op.null?

        begin
          inputs.each { |name, value| set_property(op, name.to_s, value) }

          built = c(:vips_cache_operation_build, op)
          if built.null?
            c(:vips_object_unref_outputs, op)
            error!
          end

          begin
            output ? image_output(built, output) : nil
          ensure
            c(:vips_object_unref_outputs, built)
            c(:g_object_unref, built)
          end
        ensure
          c(:g_object_unref, op)
        end
      end

      def width(image_ptr) = c(:vips_image_get_width, image_ptr)
      def height(image_ptr) = c(:vips_image_get_height, image_ptr)
      def bands(image_ptr) = c(:vips_image_get_bands, image_ptr)
      def pages(image_ptr) = c(:vips_image_get_n_pages, image_ptr)
      def orientation(image_ptr) = c(:vips_image_get_orientation, image_ptr)
      def alpha?(image_ptr) = !c(:vips_image_hasalpha, image_ptr).zero?
      def colourspace_supported?(image_ptr) = !c(:vips_colourspace_issupported, image_ptr).zero?

      def image_from_memory(bytes, width, height, bands, format_number)
        init!
        ptr = c(:vips_image_new_from_memory_copy, bytes, bytes.bytesize, width, height, bands, format_number)
        error! if ptr.null?
        ptr
      end

      # Copies the image's pixel data out as a binary string (used to read
      # the tiny vips_stats matrix without binding the variadic getpoint).
      def image_bytes(image_ptr)
        size_out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T, Fiddle::RUBY_FREE)
        buffer = c(:vips_image_write_to_memory, image_ptr, size_out)
        error! if buffer.null?
        begin
          buffer[0, size_out[0, Fiddle::SIZEOF_SIZE_T].unpack1("J")]
        ensure
          c(:g_free, buffer)
        end
      end

      private

      def open_library
        errors = []
        override = ENV["SAFE_IMAGE_LIBVIPS"]
        # An explicit override is authoritative: no fallback to the default
        # names (this also lets tests simulate a vips-less host).
        candidates = override && !override.empty? ? [override] : LIBRARY_CANDIDATES
        candidates.each do |name|
          return Fiddle.dlopen(name)
        rescue Fiddle::DLError => e
          errors << e.message
        end
        @load_error = VipsUnavailableError.new(
          "could not load libvips (install the libvips runtime package, e.g. libvips42 on Debian): #{errors.join("; ")}"
        )
        raise @load_error
      end

      def harden!
        # Block operations libvips tags unsafe for untrusted input, plus the
        # ImageMagick loader classes by name. The libjxl loader/saver are
        # deliberately re-enabled: JPEG XL is part of the supported input
        # surface and inputs still pass extension routing and pixel caps.
        c(:vips_block_untrusted_set, 1)
        c(:vips_operation_block_set, "VipsForeignLoadMagick", 1)
        c(:vips_operation_block_set, "VipsForeignLoadMagick6", 1)
        c(:vips_operation_block_set, "VipsForeignLoadMagick7", 1)
        c(:vips_operation_block_set, "VipsForeignLoadJxl", 0)
        c(:vips_operation_block_set, "VipsForeignSaveJxl", 0)

        # Keep the embedded path predictable and bounded.
        c(:vips_concurrency_set, 1)
        c(:vips_cache_set_max, 0)
        c(:vips_cache_set_max_mem, 0)
        c(:vips_cache_set_max_files, 0)
      end

      # Hostile input is expected here; libvips' GLib warnings about it (for
      # example "Not a PNG file") would otherwise litter stderr on every
      # rejected upload. Failures still surface as exceptions with the same
      # detail. Setting VIPS_WARNING makes vips_init install its own C-level
      # no-op log handler — this must NOT be done with a Ruby callback, which
      # libvips may invoke from non-Ruby threads and crash the VM. Set
      # SAFE_IMAGE_VIPS_WARNINGS=1 to keep the warnings.
      def silence_vips_log!
        if ENV["SAFE_IMAGE_VIPS_WARNINGS"] == "1"
          # VIPS_WARNING may be inherited from a parent process where this
          # gem set it; the explicit opt-in to warnings wins.
          ENV.delete("VIPS_WARNING")
        else
          ENV["VIPS_WARNING"] ||= "1"
        end
      end

      def resolve_gtypes!
        @gtype = {}
        {
          boolean: "gboolean",
          int: "gint",
          uint64: "guint64",
          double: "gdouble",
          string: "gchararray",
          enum: "GEnum",
          flags: "GFlags",
          boxed: "GBoxed",
          object: "GObject",
          image: "VipsImage",
          array_double: "VipsArrayDouble"
        }.each do |key, name|
          gtype = c(:g_type_from_name, name)
          raise Error, "GType #{name} is not registered" if gtype.zero?
          @gtype[key] = gtype
        end
      end

      def with_gvalue(gtype)
        buffer = Fiddle::Pointer.malloc(GVALUE_SIZE, Fiddle::RUBY_FREE)
        buffer[0, GVALUE_SIZE] = GVALUE_ZERO
        c(:g_value_init, buffer, gtype)
        begin
          yield buffer
        ensure
          c(:g_value_unset, buffer)
        end
      end

      def set_property(object_ptr, name, value)
        name = name.tr("_", "-")
        klass = object_ptr[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
        pspec = c(:g_object_class_find_property, klass, name)
        raise Error, "vips operation has no argument #{name.inspect}" if pspec.null?

        value_type = pspec[PSPEC_VALUE_TYPE_OFFSET, Fiddle::SIZEOF_VOIDP].unpack1("J")
        with_gvalue(value_type) do |gvalue|
          write_gvalue(gvalue, value_type, name, value)
          c(:g_object_set_property, object_ptr, name, gvalue)
        end
      end

      def write_gvalue(gvalue, value_type, name, value)
        case c(:g_type_fundamental, value_type)
        when @gtype[:boolean] then c(:g_value_set_boolean, gvalue, value ? 1 : 0)
        when @gtype[:int] then c(:g_value_set_int, gvalue, Integer(value))
        when @gtype[:double] then c(:g_value_set_double, gvalue, Float(value))
        when @gtype[:string] then c(:g_value_set_string, gvalue, value.to_s)
        when @gtype[:enum] then c(:g_value_set_enum, gvalue, enum_value(value_type, value))
        when @gtype[:flags] then c(:g_value_set_flags, gvalue, Integer(value))
        when @gtype[:object] then c(:g_value_set_object, gvalue, value)
        when @gtype[:boxed]
          raise Error, "unsupported boxed type for #{name.inspect}" unless value_type == @gtype[:array_double]
          doubles = Array(value).map { |v| Float(v) }
          c(:vips_value_set_array_double, gvalue, doubles.pack("d*"), doubles.length)
        else
          raise Error, "unsupported GType for vips argument #{name.inspect}"
        end
      end

      def enum_value(value_type, value)
        return Integer(value) if value.is_a?(Integer)

        number = c(:vips_enum_from_nick, "safe_image", value_type, value.to_s)
        error! if number.negative?
        number
      end

      def image_output(op_ptr, name)
        with_gvalue(@gtype[:image]) do |gvalue|
          c(:g_object_get_property, op_ptr, name, gvalue)
          ptr = c(:g_value_get_object, gvalue)
          raise InvalidImageError, "vips operation produced no output" if ptr.null?
          c(:g_object_ref, ptr)
          ptr
        end
      end
    end
  end
end
