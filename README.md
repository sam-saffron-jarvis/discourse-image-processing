# discourse_image_processing

A first-cut, security-oriented image processing boundary for Discourse.

This gem intentionally does **not** depend on `ruby-vips`. It uses a tiny Ruby
native extension that calls `libvips` directly, so Discourse has one small API
surface for untrusted image bytes instead of scattered ImageMagick command
construction.

## Current scope

Implemented:

- explicit-format probe for JPEG, PNG, WebP, HEIF/HEIC and AVIF
- centre-cropped thumbnail generation with direct libvips backend
- optional ImageMagick compatibility backend for Discourse-exact resize/crop/downsize/convert/orient semantics
- explicit savers for JPEG, PNG, WebP and AVIF
- metadata stripping on save
- max-pixel guard
- optimisation stage:
  - `jpegoptim` for JPEG metadata stripping / optional quality cap
  - `oxipng` for PNG lossless optimisation
  - optional `pngquant` lossy PNG quantisation before `oxipng`
- Discourse compatibility facade for current call sites:
  - `resize`
  - `crop`
  - `downsize`
  - `convert_to_jpeg`
  - `fix_orientation`
  - `optimize_image!`
- libvips `VIPS_BLOCK_UNTRUSTED` equivalent enabled in-process
- ImageMagick/Magick loaders blocked by libvips operation class
- libvips cache disabled by default in-process
- command execution uses argv arrays, not shell strings

Not implemented yet:

- subprocess/Landlock execution mode
- SVG sanitisation
- ICO frame extraction
- native-vips implementation of ImageMagick's full resize mini-language (`50%`, `100x100>`, `4000000@`)
- full golden-image parity suite against Discourse fixtures

## Why this exists

Discourse image processing is currently spread through models, helpers, upload
code, ImageMagick command builders and optimiser wrappers. This gem is intended
to become the single choke point for image decode/transform/optimise/validate.

ImageMagick delegates are deliberately avoided in the default libvips path. Loading is
by explicit libvips loader selected from an allowlisted extension, not generic
sniffing/fallback. At initialisation the native extension enables libvips'
untrusted-operation block and blocks known Magick loader classes
(`VipsForeignLoadMagick*`).

ImageMagick is available as an explicit compatibility backend only. It is never
selected implicitly, it is called with argv arrays rather than shell strings, and
its paths are restricted to a conservative absolute-path character set to avoid
ImageMagick pseudo-filename option parsing surprises.

## Install

System dependency: `libvips` headers and library.

```bash
gem build discourse_image_processing.gemspec
gem install ./discourse_image_processing-0.1.0.gem
```

## Usage

```ruby
require "discourse_image_processing"

info = DiscourseImageProcessing.probe("input.jpg", max_pixels: 40_000_000)

result = DiscourseImageProcessing.thumbnail(
  input: "input.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  quality: 85,
  max_pixels: 40_000_000
)

puts result.width
puts result.height
puts result.filesize

# Compatibility-shaped methods for Discourse integration:
DiscourseImageProcessing.resize("in.jpg", "thumb.jpg", 600, 400, backend: :vips)
DiscourseImageProcessing.crop("in.jpg", "avatar.jpg", 240, 240, backend: :imagemagick)
DiscourseImageProcessing.downsize("in.png", "smaller.png", "50%")
DiscourseImageProcessing.convert_to_jpeg("in.png", "out.jpg", quality: 85)
DiscourseImageProcessing.fix_orientation("in.jpg")
DiscourseImageProcessing.optimize_image!("out.jpg")
DiscourseImageProcessing.optimize_image!("out.png", allow_lossy_png: true)
```

## License

MIT. `libvips` itself is LGPL-2.1-or-later and is dynamically linked.
