# Safe Image

Safe Image is a small Ruby image-processing boundary for untrusted uploads.

It gives an application one narrow API for probing, thumbnailing, resizing,
cropping, converting, optimising, SVG sanitising, animation checks, favicon
conversion, and letter-avatar generation. The default fast path uses a tiny
native extension that calls `libvips` directly. Compatibility paths use
ImageMagick, but with shell-free command execution and a restrictive bundled
policy.

Safe Image started as a Discourse extraction: the public surface intentionally
covers the image operations Discourse performs today. The useful part is more
general: hostile image bytes are a lousy thing to spread across model callbacks,
upload helpers, optimizer wrappers, and hand-built command strings.

## Security model

Safe Image is not magic pixie dust. It is a deliberately small choke point.

What it does:

- uses explicit argv arrays for external commands, never shell strings
- starts external commands with an allowlisted environment, private temp/home/cache
  directories, bounded stdout/stderr, and process-group timeout cleanup
- uses explicit libvips loaders selected from allowlisted extensions
- enables libvips' untrusted-operation block in-process
- blocks libvips ImageMagick loader classes in the native extension
- disables libvips cache by default in-process
- strips metadata on generated images where applicable
- enforces optional `max_pixels` guards before expensive work
- ships a restrictive ImageMagick `policy.xml`
- denies Ghostscript-backed formats and dangerous ImageMagick features:
  - `PS`, `PS2`, `PS3`, `EPS`, `EPSF`, `PDF`, `XPS`, `PCL`
  - `MSL`, `MVG`
  - `HTTP`, `HTTPS`, `URL`
  - delegates, filters, and `@file` indirection
- supports optional Landlock subprocess sandboxing on Linux

The ImageMagick backend is explicit. Safe Image will not silently fall from the
libvips path into generic ImageMagick decoding.

## Install

System dependency:

- `libvips` headers and library, discoverable through `pkg-config vips`

Optional command dependencies:

- `magick` / `convert` and `identify` for ImageMagick compatibility operations
- `jpegoptim` for JPEG optimisation
- `oxipng` for PNG lossless optimisation
- `pngquant` for optional lossy PNG optimisation

Ruby runtime dependency:

- `rexml` for SVG sanitising

Optional Ruby dependency:

- `landlock` for Linux subprocess sandboxing

`landlock` is intentionally **not** a gem dependency. Install it in the host
application if you want sandboxing.

```bash
gem build safe_image.gemspec
gem install ./safe_image-0.1.0.gem
```

```ruby
require "safe_image"
```

## Return values

Image-producing operations return `SafeImage::Result`:

```ruby
SafeImage::Result[
  input:,          # source path or "generated"
  output:,         # output path, nil for probe
  input_format:,   # "jpg", "png", "webp", "heic", "avif", etc.
  output_format:,  # output format, nil for probe
  width:,
  height:,
  filesize:,
  backend:,        # "libvips-direct" or "imagemagick"
  duration_ms:,
  optimizer:       # optimizer tool list for thumbnail path, otherwise nil
]
```

Optimizer operations return a hash:

```ruby
{
  format: "jpg",
  before_bytes: 123_456,
  after_bytes: 120_000,
  saved_bytes: 3_456,
  tools: ["jpegoptim"]
}
```

## Core API

### `SafeImage.probe(path, max_pixels: nil)`

Reads image metadata through the direct libvips backend.

Supported inputs:

- `jpg` / `jpeg`
- `png`
- `webp`
- `heic` / `heif`
- `avif`

```ruby
info = SafeImage.probe("upload.jpg", max_pixels: 40_000_000)
puts "#{info.width}x#{info.height} #{info.input_format}"
```

Raises `SafeImage::LimitError` if `width * height > max_pixels`.

### `SafeImage.thumbnail(...)`

Creates a center-cropped thumbnail.

```ruby
result = SafeImage.thumbnail(
  input: "upload.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  format: nil,              # inferred from output extension when nil
  quality: 85,
  max_pixels: 40_000_000,
  backend: :vips,           # :vips or :imagemagick
  optimize: true,
  optimize_mode: :lossless, # :lossless or :lossy for PNG optimisation
  execution: :inline        # :inline, :sandbox, :sandbox_if_available
)
```

Supported outputs for the direct libvips backend:

- `jpg` / `jpeg`
- `png`
- `webp`
- `avif`

`execution: :sandbox` is fail-closed: it raises if Landlock is unavailable.
`execution: :sandbox_if_available` uses the sandbox only when available.

## Local metadata helpers

These helpers are intended to cover the local-file parts of APIs like
`FastImage.type`, `FastImage.size`, and `FastImage#orientation` without adding a
Ruby dependency. They do not fetch remote URLs.

### `SafeImage.type(path, max_pixels: nil)`

Returns a FastImage-style symbol for a local file:

```ruby
SafeImage.type("upload.jpg") # => :jpeg
SafeImage.type("upload.png") # => :png
SafeImage.type("icon.svg")   # => :svg
```

JPEG is returned as `:jpeg`, not `:jpg`, to match common Ruby image-probing
conventions.

### `SafeImage.size(path, max_pixels: nil)` / `SafeImage.dimensions(path, max_pixels: nil)`

Returns `[width, height]` for a local file:

```ruby
SafeImage.size("upload.jpg")       # => [1600, 1200]
SafeImage.dimensions("upload.png") # => [800, 600]
SafeImage.size("icon.svg")         # => [120, 80]
```

SVG metadata is handled by a dedicated parser, not ImageMagick or libvips. It is
limited to local `.svg` files, caps input size/tree depth/element/attribute
counts, rejects `DOCTYPE` and non-XML processing instructions, requires an `<svg>`
root, and derives dimensions from numeric `width`/`height` or `viewBox`.

### `SafeImage.orientation(path, max_pixels: nil)`

Returns the EXIF orientation integer for a local file, defaulting to `1` when no
orientation is present or when ImageMagick cannot report it.

```ruby
SafeImage.orientation("upload.jpg") # => 1
```

### `SafeImage.info(path, max_pixels: nil, animated: false, orientation: false)`

Returns a `SafeImage::Info` object for a local file:

```ruby
info = SafeImage.info("upload.jpg", animated: true, orientation: true)
info.type        # => :jpeg
info.width       # => 1600
info.height      # => 1200
info.size        # => [1600, 1200]
info.animated    # => false
info.orientation # => 1
```

`animated:` and `orientation:` default to `false` because they may require extra
ImageMagick work. When disabled, those fields are `nil`.

## Remote metadata helpers

These helpers are intended to cover `FastImage.size(url)` / `FastImage.type(url)`
style use cases without another Ruby dependency. They use only Ruby stdlib
`Net::HTTP`, download to a tempfile with a byte cap, then run the normal Safe
Image local metadata path on that tempfile.

Remote fetching is deliberately conservative:

- only `http` and `https` URLs are accepted
- redirects are capped
- open/read timeouts and an overall `total_timeout` are capped
- response size is capped by `max_bytes`
- public remote fetches are limited to ports 80 and 443 by default
- `Net::HTTP` environment proxies are disabled; proxy environment variables cannot
  route around IP validation
- DNS answers are checked against a special-use address blocklist and the
  connection is pinned to a vetted IP address to avoid DNS-rebinding/TOCTOU
  bypasses
- HTTPS-to-HTTP redirects are rejected
- same-origin redirects keep caller headers; cross-origin redirects use a small
  header allowlist (`Accept`, `Accept-Encoding`, `User-Agent`) rather than a
  blacklist
- hop-by-hop/proxy/`Host` request headers are rejected before any request
- private, loopback, link-local, multicast, documentation, benchmarking,
  carrier-grade NAT, IPv4-mapped IPv6, NAT64, 6to4/Teredo, and other
  special-use resolved addresses are rejected by default
- no image decoding happens directly from the socket
- SVG remote metadata uses the same bounded SVG metadata parser after download;
  SVG is not handed to ImageMagick for probing

Set `allow_private: true` only when the caller has already made an SSRF decision
or is intentionally probing a trusted internal URL. Passing `allow_private: true`
also permits non-standard ports; for public fetches, pass `allowed_ports:` if you
really need to allow a different port.

### `SafeImage.remote_size(url, ...)` / `SafeImage.remote_dimensions(url, ...)`

```ruby
SafeImage.remote_size(
  "https://example.com/image.jpg",
  max_bytes: 10.megabytes,
  total_timeout: 30,
  max_pixels: 40_000_000
)
# => [1600, 1200]
```

### `SafeImage.remote_type(url, ...)`

```ruby
SafeImage.remote_type("https://example.com/image.png", max_bytes: 10.megabytes)
# => :png
```

### `SafeImage.remote_info(url, ...)`

```ruby
info = SafeImage.remote_info(
  "https://example.com/image.gif",
  max_bytes: 10.megabytes,
  animated: true
)
info.type     # => :gif
info.size     # => [640, 480]
info.animated # => true
```

### `SafeImage.remote_animated?(url, ...)`

```ruby
SafeImage.remote_animated?("https://example.com/image.webp", max_bytes: 10.megabytes)
# => true / false
```

### `SafeImage.fetch_remote(url, ...) { |path| ... }`

Downloads a remote image to a tempfile and yields the local path:

```ruby
SafeImage.fetch_remote("https://example.com/image.jpg", max_bytes: 10.megabytes) do |path|
  SafeImage.probe(path)
end
```

When global Landlock is enabled, the network fetch itself is not put inside the
Landlock worker because the worker denies network access. The downloaded tempfile
is then passed through the normal Safe Image local image APIs, so decoding still
uses the same sandboxed image-processing path.

## Compatibility API

These methods are shaped around the image operations Discourse currently
performs. They are useful outside Discourse too, but the names are deliberately
boring because they map to common upload-pipeline tasks.

### `SafeImage.resize(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil)`

Creates a resized thumbnail-style output.

```ruby
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400)
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400, backend: :vips, quality: 85)
```

Backends:

- `:imagemagick` default compatibility path
- `:vips` direct libvips path

### `SafeImage.crop(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil)`

Creates a north-cropped image. This matches the avatar/optimized-image crop
shape used by Discourse.

```ruby
SafeImage.crop("upload.jpg", "avatar.jpg", 240, 240)
SafeImage.crop("upload.jpg", "avatar.jpg", 240, 240, backend: :vips)
```

### `SafeImage.downsize(from, to, dimensions, backend: :imagemagick, optimize: true, max_pixels: nil, quality: 85)`

Downsizes an image using ImageMagick-style geometry strings.

```ruby
SafeImage.downsize("large.png", "small.png", "50%")
SafeImage.downsize("large.png", "small.png", "100x100>", backend: :vips)
SafeImage.downsize("large.png", "small.png", "400000@", backend: :vips)
```

The direct vips backend supports the geometry forms covered by the test suite:
percentage, bounding box with `>`, and pixel-area cap with `@`.

### `SafeImage.convert_to_jpeg(from, to, quality: nil, optimize: true, max_pixels: nil)`

Converts an input image to JPEG through the hardened ImageMagick compatibility
backend.

```ruby
SafeImage.convert_to_jpeg("upload.png", "upload.jpg", quality: 85)
SafeImage.convert_to_jpeg("upload.heic", "upload.jpg", quality: 85)
```

### `SafeImage.fix_orientation(from, to = from, max_pixels: nil)`

Applies EXIF orientation through ImageMagick. If `to` is omitted, the file is
rewritten in place.

```ruby
SafeImage.fix_orientation("upload.jpg")
SafeImage.fix_orientation("upload.jpg", "oriented.jpg")
```

### `SafeImage.convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)`

Extracts the largest ICO frame and writes PNG.

```ruby
SafeImage.convert_favicon_to_png("favicon.ico", "favicon.png")
```

### `SafeImage.frame_count(path, max_pixels: nil)`

Returns the frame count using the hardened ImageMagick identify path.

```ruby
frames = SafeImage.frame_count("animated.gif")
```

### `SafeImage.animated?(path, max_pixels: nil)`

Returns `true` when `frame_count(path) > 1`.

```ruby
SafeImage.animated?("animated.webp")
```

### `SafeImage.letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "NimbusSans-Regular")`

Generates a square letter avatar PNG.

```ruby
SafeImage.letter_avatar(
  output: "avatar.png",
  size: 360,
  background_rgb: [1, 2, 3],
  letter: "S",
  font: "Adwaita-Sans"
)
```

### `SafeImage.optimize(path, mode: :lossless, strip_metadata: true, quality: nil, strict: true)`

Optimises an existing JPEG or PNG in place.

```ruby
SafeImage.optimize("image.jpg", quality: 85)
SafeImage.optimize("image.png")
SafeImage.optimize("image.png", mode: :lossy, quality: "65-90")
```

JPEG path:

- uses `jpegoptim`
- `quality:` maps to `jpegoptim --max`
- metadata is stripped unless `strip_metadata: false`

PNG path:

- uses `oxipng` for lossless optimisation
- when `mode: :lossy`, uses `pngquant` first for PNGs smaller than 500 KB,
  then `oxipng`

When `strict: true`, missing optimizer tools raise. When `strict: false`, missing
optimizer tools are tolerated.

### `SafeImage.optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil, strict: true)`

Compatibility wrapper around `SafeImage.optimize`.

```ruby
SafeImage.optimize_image!("image.jpg")
SafeImage.optimize_image!("image.png", allow_lossy_png: true)
```

### `SafeImage.sanitize_svg!(path)`

Sanitises an SVG in place using a small REXML allowlist.

```ruby
result = SafeImage.sanitize_svg!("icon.svg")
puts result[:sanitized]
```

The sanitizer removes unsafe elements/attributes such as scripts and event
handlers. It is intentionally conservative rather than a full browser-grade SVG
implementation.

## Security posture without Landlock

Without Landlock, Safe Image still hardens the ImageMagick path substantially:

- delegates are disabled
- filters are disabled
- `@file` indirection is disabled
- remote URL coders are disabled
- Ghostscript/document/vector formats are denied
- coders are deny-by-default with a small raster allowlist
- commands are executed with argv arrays, not shell strings
- command environment and ImageMagick policy path are controlled
- ImageMagick resource limits are set in the bundled policy

That does **not** make hostile files benign. Raster decoders still parse attacker
controlled bytes: libjpeg, libpng, libwebp, libheif/HEIC/AVIF, ImageMagick's
raster decoders, and libvips loaders. If one of those decoders has a memory
corruption bug or pathological resource-consumption bug, policy alone is not a
sandbox.

So the intended posture is:

- without Landlock: hardened, centralized image processing with the major
  ImageMagick delegate/pseudo-protocol foot-guns removed
- with Landlock: the same hardening plus a real containment boundary around all
  public operations

Do not describe non-sandboxed operation as making hostile images safe. The honest
claim is defense-in-depth, not immunity.

## Atomic Landlock sandboxing

Landlock support is optional, but atomic once enabled.

```ruby
SafeImage.sandbox_available? # => true/false
SafeImage.enable_sandbox!    # raises if unavailable
SafeImage.sandbox_enabled?   # => true
```

After `SafeImage.enable_sandbox!`, every public operation routes through the
sandbox worker:

- `probe`
- `type`
- `size`
- `dimensions`
- `info`
- `orientation`
- `thumbnail`
- `optimize`
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

There is no silent fallback after global sandbox enablement. If sandbox setup or
a sandboxed command fails, the operation fails.

The sandbox grants read/write access only to the paths inferred from the
operation arguments, plus runtime/library paths and temporary directories needed
by Ruby, libvips, ImageMagick, and optimizer tools. Network syscalls are denied
through the Landlock helper's seccomp layer.

## Discourse parity

Safe Image currently covers the image-operation surface Discourse performs in:

- optimized image generation
- upload preprocessing
- thumbnail generation
- avatar cropping / letter avatars
- favicon conversion
- HEIC/PNG-to-JPEG conversion
- orientation fixing
- animated image detection
- JPEG/PNG optimisation
- SVG sanitising

The claim is operation parity, not byte-for-byte output identity across all
ImageMagick/libvips versions. The test suite includes golden compatibility
checks, ImageMagick parity checks, policy-denial checks, and a real-image atomic
sandbox sweep over the full public operation list.

## Development

```bash
bundle install
bundle exec rake
```

`bundle exec rake` builds the native extension and runs:

- smoke tests
- compatibility smoke tests
- golden operation tests
- ImageMagick parity tests
- ImageMagick safety-policy tests
- atomic Landlock all-operation tests when Landlock is available

The atomic sandbox suite skips when `landlock` is not installed or unavailable on
the host kernel.

## License

MIT. `libvips` itself is LGPL-2.1-or-later and is dynamically linked.
