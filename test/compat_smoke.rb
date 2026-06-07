# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/discourse_image_processing"

FIXTURES = "/home/agent/source/discourse/spec/fixtures/images"
JPG = File.join(FIXTURES, "huge.jpg")
PNG = File.join(FIXTURES, "large_and_unoptimized.png")
HEIC = File.join(FIXTURES, "should_be_jpeg.heic")
WEBP = File.join(FIXTURES, "animated.webp")

Dir.mktmpdir do |dir|
  vips_thumb = File.join(dir, "vips-thumb.jpg")
  im_thumb = File.join(dir, "im-thumb.jpg")
  crop = File.join(dir, "crop.jpg")
  down = File.join(dir, "down.png")
  conv = File.join(dir, "conv.jpg")
  heic = File.join(dir, "heic.jpg")
  webp = File.join(dir, "webp.jpg")

  results = []
  results << DiscourseImageProcessing.thumbnail(input: JPG, output: vips_thumb, width: 600, height: 400, backend: :vips, optimize: true, max_pixels: 100_000_000)
  results << DiscourseImageProcessing.thumbnail(input: JPG, output: im_thumb, width: 600, height: 400, backend: :imagemagick, optimize: true, max_pixels: 100_000_000)
  results << DiscourseImageProcessing.crop(JPG, crop, 400, 400, backend: :imagemagick, max_pixels: 100_000_000)
  results << DiscourseImageProcessing.downsize(PNG, down, "50%", max_pixels: 10_000_000)
  results << DiscourseImageProcessing.convert_to_jpeg(PNG, conv, quality: 85, max_pixels: 10_000_000)
  results << DiscourseImageProcessing.convert_to_jpeg(HEIC, heic, quality: 85, max_pixels: 10_000_000)
  results << DiscourseImageProcessing.thumbnail(input: WEBP, output: webp, width: 120, height: 120, backend: :vips, optimize: true, max_pixels: 10_000_000)

  raise "bad dimensions" unless results[0].width == 600 && results[0].height == 400
  raise "bad dimensions" unless results[1].width == 600 && results[1].height == 400
  raise "bad dimensions" unless results[2].width == 400 && results[2].height == 400
  raise "missing outputs" unless [vips_thumb, im_thumb, crop, down, conv, heic, webp].all? { |f| File.file?(f) && File.size(f).positive? }

  jpeg_opt = DiscourseImageProcessing.optimize_image!(conv)
  raise "jpegoptim missing" unless jpeg_opt.fetch(:tools).include?("jpegoptim")

  png_opt = DiscourseImageProcessing.optimize_image!(down, allow_lossy_png: true)
  raise "oxipng missing" unless png_opt.fetch(:tools).include?("oxipng")

  puts "OK compat smoke: #{results.map { |r| "#{r.output_format}:#{r.width}x#{r.height}:#{r.filesize}" }.join(" ")}"
end
