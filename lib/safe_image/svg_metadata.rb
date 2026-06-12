# frozen_string_literal: true

require "pathname"

module SafeImage
  module SvgMetadata
    module_function

    MAX_SVG_BYTES = 1 * 1024 * 1024
    MAX_SVG_DEPTH = 64
    MAX_SVG_ELEMENTS = 10_000
    MAX_SVG_ATTRIBUTES = 50_000
    MAX_SVG_DIMENSION = 100_000
    MAX_SVG_PIXELS = 100_000_000
    # Upper bound on the render tree the document instantiates. The caps above
    # bound the *source* document, but several allowlisted features replicate
    # referenced content at render time, so a small source can cost a consumer
    # (browser/rasterizer) orders of magnitude more work:
    #   * <use href="#id"> deep-copies its target subtree — a chain of doubling
    #     groups fans a few dozen nodes into billions ("use bomb"), and a cyclic
    #     reference expands forever.
    #   * a <marker> is drawn once per vertex of every path/line/polyline/polygon
    #     that references it, so (vertex count) x (marker subtree size) draws — a
    #     dense `d` (~200k vertices fit in 1 MB) times a non-trivial marker is a
    #     linear-but-huge "draw bomb" no node/byte/element cap can see.
    # SvgSanitizer charges both against this single budget over the sanitized
    # tree (renderer-free static accounting) and rejects when it is exceeded.
    MAX_SVG_RENDER_UNITS = 1_000_000

    LENGTH_PATTERN = /\A\s*([+]?(?:\d+(?:\.\d+)?|\.\d+))(?:px)?\s*\z/i.freeze
    VIEWBOX_SPLIT = /[\s,]+/.freeze

    # Byte-order marks for the multi-byte encodings whose ASCII characters our
    # byte-level scans below cannot see through. XML mandates a BOM for UTF-16
    # and UTF-32, so a document in one of these encodings either carries a BOM
    # here or contains NUL bytes for its ASCII characters (caught separately).
    # Order matters: the UTF-32 LE mark begins with the UTF-16 LE mark.
    NON_UTF8_BOMS = [
      "\xFF\xFE\x00\x00".b, # UTF-32 LE
      "\x00\x00\xFE\xFF".b, # UTF-32 BE
      "\xFF\xFE".b,         # UTF-16 LE
      "\xFE\xFF".b          # UTF-16 BE
    ].freeze

    UTF8_BOM = "\xEF\xBB\xBF".b.freeze
    # Declared encodings we accept: UTF-8/ASCII plus the single-byte,
    # ASCII-transparent legacy charsets (ISO-8859-*, Windows-125x). Their bytes
    # below 0x80 decode to identical ASCII, so the byte scans below see the same
    # markup any decoder (REXML or a browser) does; and being single-byte, no
    # lead byte can swallow a following quote the way Shift-JIS, GBK, or Big5
    # can. Multi-byte (Shift-JIS, GBK, EUC-*, ISO-2022-*), transforming (UTF-7:
    # "+ADw-" decodes to "<"), and NUL-interleaved (UTF-16/32) encodings are
    # deliberately excluded — they let bytes our ASCII scans cannot see become
    # markup the parser acts on. The shape match alone is not airtight:
    # "utf8" or "windows-1259" fit the pattern yet name no real encoding, so a
    # name must also resolve via Encoding.find to pass — lookalikes fail
    # closed here instead of leaking REXML's bare ArgumentError to the caller.
    SAFE_DECLARED_ENCODING =
      /\A(?:utf-?8|us-ascii|ascii|iso-?8859-?\d{1,2}|(?:windows|cp)-?125\d)\z/i.freeze
    # ASCII-only so it matches the binary buffer; the optional BOM is stripped
    # before matching rather than embedded here (which would make this UTF-8).
    XML_DECL_ENCODING = /\A\s*<\?xml\b[^>]*?\bencoding\s*=\s*["']([^"']+)["']/i.freeze

    def probe(path, max_pixels: nil, max_bytes: MAX_SVG_BYTES)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      path = safe_svg_path(path)
      width, height = dimensions(path, max_pixels: max_pixels, max_bytes: max_bytes)
      {
        input_format: "svg",
        width: width,
        height: height,
        frames: 1,
        duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      }
    end

    def dimensions(path, max_pixels: nil, max_bytes: MAX_SVG_BYTES)
      xml = read_svg(path, max_bytes: max_bytes)
      _name, attributes = scan_svg!(xml)
      dimensions_from_attributes(attributes, max_pixels: max_pixels)
    end

    # Computes and validates the document dimensions from the already-scanned
    # root attributes, so a caller that has run scan_svg! does not re-read or
    # re-scan the file. Same width/height-then-viewBox fallback and limits as
    # dimensions above.
    def dimensions_from_attributes(attributes, max_pixels: nil)
      width = parse_length(attributes["width"])
      height = parse_length(attributes["height"])

      unless width && height
        view_box = parse_view_box(attributes["viewBox"])
        width ||= view_box&.fetch(2)
        height ||= view_box&.fetch(3)
      end

      validate_dimensions!(width, height, max_pixels: max_pixels)
    end

    def read_svg(path, max_bytes: MAX_SVG_BYTES)
      path = safe_svg_path(path)
      size = File.size(path)
      raise LimitError, "SVG exceeds #{max_bytes} bytes" if size > max_bytes

      xml = File.binread(path, max_bytes + 1) || "".b
      raise LimitError, "SVG exceeds #{max_bytes} bytes" if xml.bytesize > max_bytes
      reject_unsafe_xml!(xml)
      xml
    end

    def safe_svg_path(path)
      path = PathSafety.ensure_regular_file!(path)
      raise UnsupportedFormatError, "not an SVG file: #{path}" unless File.extname(path.to_s).downcase == ".svg"
      path.to_s
    end

    def reject_unsafe_xml!(xml)
      # The DOCTYPE/PI scans below are ASCII byte regexes; they only see what
      # they expect when the bytes we scan decode to the same markup the XML
      # parser sees. That holds for UTF-8 and single-byte ASCII-transparent
      # charsets but not for UTF-16/32 or multi-byte/transforming encodings, so
      # reject those first.
      reject_unsafe_encoding!(xml)
      raise InvalidImageError, "doctype is not allowed in SVG" if xml.match?(/<!DOCTYPE/i)
      raise InvalidImageError, "XML processing instructions are not allowed in SVG" if xml.match?(/<\?(?!xml\s)/i)
    end

    def reject_unsafe_encoding!(xml)
      bytes = xml.b
      # UTF-16/UTF-32 interleave NUL bytes between ASCII characters, hiding
      # "<!DOCTYPE" from the ASCII scans while the XML parser still decodes and
      # honours it. (NUL is invalid in XML 1.0 regardless, so this also rejects
      # garbage.)
      if NON_UTF8_BOMS.any? { |bom| bytes.start_with?(bom) } || bytes.include?("\x00".b)
        raise InvalidImageError, "SVG must use a single-byte or UTF-8 encoding"
      end

      bytes = bytes.byteslice(UTF8_BOM.bytesize..) if bytes.start_with?(UTF8_BOM)
      match = bytes.match(XML_DECL_ENCODING)
      return unless match
      return if match[1].match?(SAFE_DECLARED_ENCODING) && known_encoding?(match[1])

      raise InvalidImageError, "unsupported SVG encoding: #{match[1]}"
    end

    def known_encoding?(name)
      Encoding.find(name)
      true
    rescue ArgumentError
      false
    end

    def parse_length(value)
      value = value.to_s
      match = LENGTH_PATTERN.match(value)
      return nil unless match

      number = Float(match[1])
      return nil unless number.finite? && number.positive?

      number
    rescue ArgumentError
      nil
    end

    def parse_view_box(value)
      parts = value.to_s.strip.split(VIEWBOX_SPLIT)
      return nil unless parts.length == 4

      numbers = parts.map { |part| Float(part) }
      return nil unless numbers.all?(&:finite?) && numbers[2].positive? && numbers[3].positive?

      numbers
    rescue ArgumentError
      nil
    end

    def validate_dimensions!(width, height, max_pixels: nil)
      raise InvalidImageError, "SVG dimensions are missing or invalid" unless width&.positive? && height&.positive?
      raise LimitError, "SVG dimensions exceed #{MAX_SVG_DIMENSION}px" if width > MAX_SVG_DIMENSION || height > MAX_SVG_DIMENSION

      pixels = width * height
      limit = if max_pixels.nil?
        MAX_SVG_PIXELS
      else
        value = Integer(max_pixels)
        raise ArgumentError, "max_pixels must be positive" if value <= 0

        value
      end
      raise LimitError, "SVG has #{pixels.to_i} pixels, exceeds #{limit}" if pixels > limit

      [width.ceil, height.ceil]
    end

    # Streams the document with a SAX parser, enforcing the structural caps as
    # events arrive (see cap_scanner_class), so a hostile "millions of tiny
    # elements" document is rejected at the cap without ever retaining the
    # multi-million-object DOM a parse-then-validate approach would build.
    # Returns the root element's local name and a localname=>value hash of its
    # attributes, matching the contract dimensions_from_attributes consumes.
    #
    # SAX does NOT raise on malformed XML even with recovery disabled — it
    # reports through the error callback and keeps going — so well-formedness is
    # enforced by recording any reported error and rejecting after the parse.
    # This reproduces the old REXML pull-parser's reject set (unclosed/mismatched
    # tags, trailing junk) and is strictly stricter on multiple root elements,
    # which is a safe direction for a gate.
    def scan_svg!(xml)
      require_nokogiri
      handler = cap_scanner_class.new
      parser = Nokogiri::XML::SAX::Parser.new(handler)
      begin
        # recovery: false — do not silently repair malformed markup. Errors still
        # arrive via the error callback rather than as exceptions, so they are
        # checked explicitly below.
        parser.parse(xml) { |ctx| ctx.recovery = false }
      rescue LimitError, InvalidImageError
        raise # our own cap/validation rejections, surfaced from a callback
      rescue StandardError => e
        # Nokogiri rejects some inputs by raising rather than via the error
        # callback (e.g. empty input -> "input string cannot be empty"). Keep
        # untrusted-input failures inside our error hierarchy.
        raise InvalidImageError, "invalid SVG: #{e.message}"
      end

      raise InvalidImageError, "invalid SVG: #{handler.parse_error}" if handler.parse_error
      raise InvalidImageError, "SVG root required" unless handler.root_name == "svg"

      [handler.root_name, handler.root_attributes]
    end

    # Loaded on first SVG use, not at file load: keeping the XML library off the
    # hot path of every non-SVG operation (and every sandbox worker boot) where
    # it would otherwise be paid for nothing.
    def require_nokogiri
      require "nokogiri"
    end

    # The SAX cap-enforcement handler, built lazily and memoised the first time
    # an SVG is scanned. It subclasses Nokogiri::XML::SAX::Document, so it cannot
    # be declared at file-load time without forcing nokogiri to load eagerly and
    # defeating the lazy require above. A breached cap raises LimitError straight
    # out of a callback; libxml2 propagates it at the next event boundary, so the
    # parse aborts promptly rather than scanning to the end (verified: rejection
    # time grows far slower than input size).
    def cap_scanner_class
      @cap_scanner_class ||= Class.new(Nokogiri::XML::SAX::Document) do
        attr_reader :root_name, :root_attributes, :parse_error

        def initialize
          super
          @depth = -1
          @elements = 0
          @attributes = 0
          @root_name = nil
          @root_attributes = nil
          @parse_error = nil
        end

        # attrs: array of Nokogiri::XML::SAX::Parser::Attribute (localname/value),
        # NOT including namespace declarations; `ns` carries the xmlns decls. Both
        # count toward the attribute cap so the bound cannot be sidestepped by
        # spraying namespace declarations.
        def start_element_namespace(name, attrs = [], _prefix = nil, _uri = nil, ns = [])
          @depth += 1
          raise LimitError, "SVG nesting exceeds #{MAX_SVG_DEPTH}" if @depth > MAX_SVG_DEPTH

          @elements += 1
          raise LimitError, "SVG has too many elements" if @elements > MAX_SVG_ELEMENTS

          @attributes += attrs.length + ns.length
          raise LimitError, "SVG has too many attributes" if @attributes > MAX_SVG_ATTRIBUTES

          return unless @root_name.nil?

          @root_name = name
          @root_attributes = attrs.each_with_object({}) do |attr, hash|
            # Dimensions are security-relevant: only the actual no-namespace
            # root attributes a browser will use may feed the pixel cap. A
            # namespaced e:width/e:height must not shadow width/height here
            # and then be dropped by the sanitizer, leaving a huge output SVG
            # that metadata claimed was tiny.
            next unless attr.prefix.to_s.empty? && attr.uri.to_s.empty?

            hash[attr.localname] = attr.value
          end
        end

        def end_element_namespace(_name, _prefix = nil, _uri = nil)
          @depth -= 1
        end

        # libxml2 reports well-formedness violations here rather than raising;
        # record the first so scan_svg! can reject on it.
        def error(message)
          @parse_error ||= message.to_s.strip
        end

        def warning(_message); end
      end
    end
  end
end
