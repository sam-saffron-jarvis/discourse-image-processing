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
  - `convert_favicon_to_png`
  - `frame_count`
  - `animated?`
  - `letter_avatar`
  - `optimize_image!`
  - `sanitize_svg!`
- SVG sanitisation via stdlib REXML allowlist
- ICO largest-frame extraction via explicit ImageMagick compatibility backend
- libvips `VIPS_BLOCK_UNTRUSTED` equivalent enabled in-process
- ImageMagick/Magick loaders blocked by libvips operation class
- libvips cache disabled by default in-process
- command execution uses argv arrays, not shell strings

Not implemented yet:

- Nothing currently known that blocks Discourse integration; Landlock is optional, but when explicitly enabled it applies atomically to all public operations.

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
ImageMagick pseudo-filename option parsing surprises. The gem ships a restrictive
ImageMagick `policy.xml` and sets `MAGICK_CONFIGURE_PATH` for child commands:
Ghostscript-backed formats (`PS`, `EPS`, `PDF`, `XPS`, `PCL`, etc.), delegates,
remote URL coders, filters, and `@file` indirection are denied.

## Install

System dependency: `libvips` headers and library.

Optional command dependencies for compatibility/optimisation paths:

- `magick` for ImageMagick compatibility operations
- `jpegoptim` for JPEG optimisation
- `oxipng` for PNG lossless optimisation
- `pngquant` for optional lossy PNG optimisation

Ruby runtime dependencies:

- `rexml` for SVG sanitising

Optional Ruby dependency:

- `landlock` for Linux subprocess sandboxing. It is not a gem dependency;
  install it in the host application if you want sandboxing.

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
DiscourseImageProcessing.convert_favicon_to_png("favicon.ico", "favicon.png")
DiscourseImageProcessing.frame_count("maybe-animated.gif")
DiscourseImageProcessing.animated?("maybe-animated.gif")
DiscourseImageProcessing.letter_avatar(output: "avatar.png", size: 360, background_rgb: [1, 2, 3], letter: "S")
DiscourseImageProcessing.optimize_image!("out.jpg")
DiscourseImageProcessing.optimize_image!("out.png", allow_lossy_png: true)
DiscourseImageProcessing.sanitize_svg!("icon.svg")

# Enable Landlock globally. This is atomic: after this point every public
# operation is executed through the sandbox worker. If Landlock is unavailable,
# this raises instead of silently degrading.
DiscourseImageProcessing.enable_sandbox!
DiscourseImageProcessing.sandbox_enabled?
DiscourseImageProcessing.sandbox_available?
```

## License

MIT. `libvips` itself is LGPL-2.1-or-later and is dynamically linked.
