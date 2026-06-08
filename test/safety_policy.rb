# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/safe_image"

Dir.mktmpdir do |dir|
  ps = File.join(dir, "ghostscript.ps")
  File.write(ps, "%!PS\n/Times-Roman findfont 12 scalefont setfont\n100 700 moveto (x) show\nshowpage\n")

  command = SafeImage::ImageMagickBackend.convert_command

  begin
    SafeImage::Runner.run!([command, ps, File.join(dir, "out.png")])
    abort "ImageMagick unexpectedly processed PostScript"
  rescue SafeImage::CommandError => e
    unless e.stderr.match?(/not authorized|security policy|no decode delegate/i)
      abort "unexpected ImageMagick denial message: #{e.stderr}"
    end
  end

  pdf = File.join(dir, "ghostscript.pdf")
  File.write(pdf, "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")

  begin
    SafeImage::Runner.run!([command, pdf, File.join(dir, "out2.png")])
    abort "ImageMagick unexpectedly processed PDF"
  rescue SafeImage::CommandError => e
    unless e.stderr.match?(/not authorized|security policy|no decode delegate/i)
      abort "unexpected ImageMagick denial message: #{e.stderr}"
    end
  end

  puts "OK ImageMagick policy denies Ghostscript-backed formats"

  fake_dir = File.join(dir, "fake-bin")
  Dir.mkdir(fake_dir)
  fake_marker = File.join(dir, "fake-ran")
  fake_command = File.join(fake_dir, command)
  File.write(fake_command, "#!/bin/sh\ntouch #{fake_marker}\nexit 0\n")
  File.chmod(0o755, fake_command)

  begin
    SafeImage::Runner.run!(
      [command, ps, File.join(dir, "out3.png")],
      env: {
        "PATH" => fake_dir,
        "MAGICK_CONFIGURE_PATH" => "/tmp",
        "HOME" => fake_dir,
        "XDG_CACHE_HOME" => fake_dir,
        "VIPS_BLOCK_UNTRUSTED" => "0"
      }
    )
    abort "ImageMagick unexpectedly processed PostScript with env override"
  rescue SafeImage::CommandError
  end
  abort "Runner used caller-controlled PATH" if File.exist?(fake_marker)
  begin
    txt = File.join(dir, "not-image.txt")
    File.write(txt, "not an image")
    SafeImage.convert_to_jpeg(txt, File.join(dir, "sniffed.jpg"))
    abort "convert_to_jpeg unexpectedly allowed decoder-less ImageMagick sniffing"
  rescue SafeImage::UnsupportedFormatError
  end

  puts "OK Runner ignores protected env overrides"
end

begin
  original = SafeImage::Sandbox.method(:available?)
  SafeImage::Sandbox.define_singleton_method(:available?) { false }
  Dir.mktmpdir do |dir|
    begin
      SafeImage.thumbnail(
        input: File.expand_path("fixtures/images/huge.jpg", __dir__),
        output: File.join(dir, "x.jpg"),
        width: 10,
        height: 10,
        execution: :sandbox
      )
      abort "strict sandbox unexpectedly fell back to inline"
    rescue SafeImage::Error => e
      abort "wrong sandbox error: #{e.message}" unless e.message.include?("sandbox execution requested")
    end
  end
ensure
  SafeImage::Sandbox.define_singleton_method(:available?, original) if original
end

puts "OK strict sandbox does not silently degrade"