# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/safe_image"

Dir.mktmpdir do |dir|
  svg = File.join(dir, "icon.svg")
  File.write(svg, <<~SVG)
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
      <rect width="120" height="80" fill="#fff"/>
    </svg>
  SVG

  raise "svg type mismatch" unless SafeImage.type(svg) == :svg
  raise "svg size mismatch" unless SafeImage.size(svg) == [120, 80]
  info = SafeImage.info(svg, animated: true, orientation: true)
  raise "svg info type mismatch" unless info.type == :svg
  raise "svg info animated mismatch" unless info.animated == false
  raise "svg info orientation mismatch" unless info.orientation == 1

  viewbox = File.join(dir, "viewbox.svg")
  File.write(viewbox, <<~SVG)
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33.2 44.1"></svg>
  SVG
  raise "svg viewBox dimensions mismatch" unless SafeImage.size(viewbox) == [34, 45]

  px = File.join(dir, "px.svg")
  File.write(px, <<~SVG)
    <svg xmlns="http://www.w3.org/2000/svg" width="10px" height="20px"></svg>
  SVG
  raise "svg px dimensions mismatch" unless SafeImage.size(px) == [10, 20]

  percent = File.join(dir, "percent.svg")
  File.write(percent, <<~SVG)
    <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"></svg>
  SVG
  begin
    SafeImage.size(percent)
    abort "svg percentage dimensions unexpectedly accepted"
  rescue SafeImage::InvalidImageError
  end

  huge = File.join(dir, "huge.svg")
  File.write(huge, <<~SVG)
    <svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"></svg>
  SVG
  begin
    SafeImage.size(huge)
    abort "huge svg unexpectedly accepted"
  rescue SafeImage::LimitError
  end

  oversized = File.join(dir, "oversized.svg")
  File.write(oversized, "<svg width=\"1\" height=\"1\">" + (" " * (SafeImage::SvgMetadata::MAX_SVG_BYTES + 1)) + "</svg>")
  begin
    SafeImage.size(oversized)
    abort "oversized svg unexpectedly accepted"
  rescue SafeImage::LimitError
  end

  doctype = File.join(dir, "doctype.svg")
  File.write(doctype, <<~SVG)
    <!DOCTYPE svg [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&xxe;</svg>
  SVG
  begin
    SafeImage.size(doctype)
    abort "doctype svg unexpectedly accepted"
  rescue SafeImage::InvalidImageError
  end

  pi = File.join(dir, "stylesheet.svg")
  File.write(pi, <<~SVG)
    <?xml version="1.0"?>
    <?xml-stylesheet href="http://evil.example/x.css"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>
  SVG
  begin
    SafeImage.size(pi)
    abort "xml-stylesheet svg unexpectedly accepted"
  rescue SafeImage::InvalidImageError
  end

  deep = File.join(dir, "deep.svg")
  File.write(deep, "<svg width=\"1\" height=\"1\">" + ("<g>" * 70) + ("</g>" * 70) + "</svg>")
  begin
    SafeImage.size(deep)
    abort "deep svg unexpectedly accepted"
  rescue SafeImage::LimitError
  end

  txt = File.join(dir, "not-svg.txt")
  File.write(txt, "<svg width=\"1\" height=\"1\"></svg>")
  begin
    SafeImage.size(txt)
    abort "non-svg extension unexpectedly accepted as svg"
  rescue SafeImage::UnsupportedFormatError
  end
end

puts "OK safe SVG metadata helpers"
