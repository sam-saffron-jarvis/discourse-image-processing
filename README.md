# Safe Image

Safe Image is a small Ruby image-processing boundary for untrusted uploads.

It gives an application one narrow API for probing, thumbnailing, resizing,
cropping, converting, optimising, SVG sanitising, animation checks, dominant
colour extraction, favicon conversion, and letter-avatar generation.
Everything that varies by host is decided once, at boot, with a single
mandatory call:

```ruby
SafeImage.configure!(backend: :vips, landlock: true)
```

The `:vips` backend uses a tiny Fiddle binding that drives `libvips` directly
— pure Ruby, nothing compiles at install time. The `:imagemagick` backend
runs ImageMagick with shell-free command execution and a restrictive bundled
policy. There are no per-call backend choices and no silent fallback from one
backend to the other: you pick the decoder for untrusted bytes in one place
and every operation uses it.

The premise is that hostile image bytes are a lousy thing to spread across
model callbacks, upload helpers, optimizer wrappers, and hand-built command
strings. Safe Image puts the risky operations behind one small, hardened
choke point instead.

## Install

Nothing compiles at install time: libvips is bound at runtime through Fiddle
(`libvips.so.42` is dlopened when `configure!(backend: :vips)` runs;
`SAFE_IMAGE_LIBVIPS` overrides the library name authoritatively). libvips'
GLib warnings about rejected input (e.g. "Not a PNG file") are silenced —
failures surface as exceptions instead; set `SAFE_IMAGE_VIPS_WARNINGS=1` to
restore them for debugging. Install the runtime
[dependencies](#dependencies) below.

```bash
gem build safe_image.gemspec
gem install ./safe_image-0.1.0.gem
```

```ruby
require "safe_image"

SafeImage.configure!(backend: :vips, landlock: false)

result = SafeImage.thumbnail(
  input: "upload.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  max_pixels: 40_000_000
)

puts "#{result.backend}: #{result.width}x#{result.height} #{result.filesize} bytes"

SafeImage.convert(
  "upload.png",
  "upload.jpg",
  format: "jpg",
  quality: 85,
  max_pixels: 40_000_000
)
```

## Configuration

`SafeImage.configure!` must be called before any operation — typically from a
boot-time initializer. Any operation before it (including the pure-Ruby SVG
and remote helpers) raises `SafeImage::NotConfiguredError`.

```ruby
SafeImage.configure!(
  backend: :vips,    # required: :vips or :imagemagick — decodes all untrusted bytes
  landlock: true,    # required: route every operation through the Landlock sandbox
  max_pixels: SafeImage::DEFAULT_MAX_PIXELS # optional: default decompression-bomb ceiling (128MP)
)
```

Validation is eager, so a misconfigured host fails at boot rather than on the
first request:

- `backend: :vips` dlopens libvips and raises if it is unavailable
- `backend: :imagemagick` raises if no `magick`/`convert` executable is found
- `landlock: true` raises if the Landlock sandbox is unavailable
  (`SafeImage.sandbox_available?` works before `configure!`, so a host can
  probe first)
- unknown values raise `ArgumentError`

Calling `configure!` again replaces the configuration atomically (last call
wins), so reloading initializers in development is safe. `SafeImage.config`
returns the current frozen configuration and `SafeImage.configured?` reports
whether one is set.

Per-call `max_pixels:` still overrides the configured ceiling for an
individual operation; everything else about backend selection and sandboxing
is decided here and only here.

Choosing a backend:

- `:vips` — the recommended fast path: explicit native loaders, in-process
  hardening, no subprocess per operation
- `:imagemagick` — matches classic ImageMagick `convert` pipelines; also the
  option for hosts without libvips. Formats are decoded by ImageMagick under
  the bundled restrictive policy.

A format the configured backend cannot decode fails closed — e.g. ICO
transform inputs need `:imagemagick` (ICO *metadata* is parsed in pure Ruby on
either backend), and HEIC needs a libvips build with libheif on `:vips`.

## Dependencies

### Quick install

Debian / Ubuntu:

```bash
sudo apt-get install --no-install-recommends \
  libvips42 imagemagick jpegoptim pngquant oxipng libjpeg-turbo-progs
```

`oxipng` is packaged from Debian 13 / Ubuntu 24.04; on older releases install
it with `cargo install oxipng`. For `cjpegli`, Debian/Ubuntu package names
vary by release (`libjpegli-tools` where available); it is optional and
detected at runtime.

Arch:

```bash
sudo pacman -S --needed libvips \
  imagemagick jpegoptim pngquant oxipng libjpeg-turbo libjxl
```

(`libjpeg-turbo` provides `jpegtran`, `libjxl` provides `cjpegli`.)

### What each dependency is for

| Dependency | Kind | Needed for | Without it |
| --- | --- | --- | --- |
| `libvips` runtime library (`libvips.so.42`; Debian: `libvips42` ≥ 8.13) | required for `backend: :vips` | the fast path for every operation, bound via Fiddle | `configure!(backend: :vips)` raises at boot; configure `backend: :imagemagick` instead |
| ImageMagick (`magick`/`convert`, `identify`) | required for `backend: :imagemagick` | every operation on the `:imagemagick` backend | `configure!(backend: :imagemagick)` raises at boot |
| `jpegoptim` | required for JPEG `optimize` | lossless JPEG optimisation and metadata stripping | JPEG `optimize` raises in strict mode |
| `oxipng` | required for PNG `optimize` | lossless PNG optimisation | PNG `optimize` raises in strict mode |
| `pngquant` | optional | lossy PNG quantisation (`optimize_mode: :lossy`, files < 500KB) | lossy mode silently skips the quantisation pass |
| `jpegtran` (libjpeg-turbo) | optional | lossless tier of `fix_orientation`; uprighting EXIF-oriented JPEGs in `optimize` | `fix_orientation` falls back to the libvips re-encode tier; `optimize` of an oriented JPEG raises in strict mode (left untouched otherwise) |
| `cjpegli` (libjxl) | optional | higher-quality encoding of generated JPEGs on the `:vips` backend — used automatically when installed | generated JPEGs use the backend's own encoder |
| `landlock` gem (Linux kernel ≥ 5.13) | required for `landlock: true` | the atomic sandbox around every operation | `configure!(landlock: true)` raises at boot; `sandbox_available?` is false |
| `rexml` gem | automatic | SVG sanitising and SVG metadata | installed as a gem dependency |

The `landlock` gem is intentionally **not** a gem dependency; add it to the
host application's Gemfile if you want sandboxing.

### libvips build capabilities

Some features depend on how the host's libvips was built (all present in
stock Debian, Ubuntu and Arch packages):

- **libheif** — HEIC/AVIF decode (`probe`, `convert`, thumbnails)
- **Pango text** (`VipsText`) — `letter_avatar`; without it the operation
  raises `UnsupportedFormatError` (configure `backend: :imagemagick` if you
  need letter avatars on such a build)
- **cgif** (`gifsave`) — GIF *output* from the vips backend; GIF *decode*
  (libnsgif) is always built in
- **libjxl** (`jxlload`/`jxlsave`) — JPEG XL decode and encode

Check a host with:

```bash
vips -l | grep -cE "VipsForeignSaveCgif|VipsText|VipsForeignLoadHeif|VipsForeignLoadJxl" # expect 4+
```

### Fonts

Letter avatars need **no font packages** with the default `DejaVu-Sans`
token: the gem bundles DejaVu Sans and pins it via fontconfig's app-font API.
The other allowlisted tokens (`NimbusSans-Regular`, `Liberation-Sans`,
`Arial`, `Helvetica`, `Adwaita-Sans`) resolve through system fontconfig —
install e.g. `fonts-liberation` (Debian/Ubuntu) or `ttf-liberation` (Arch) if
you select them. Glyphs outside DejaVu's coverage (CJK, Hangul, ...) fall
back per-glyph to whatever system fonts exist.

### Checking a host

These probes work before `configure!`, so an application can inspect the host
and then make its configuration decision:

```ruby
require "safe_image"

%w[magick identify jpegoptim oxipng pngquant jpegtran cjpegli].each do |tool|
  puts format("%-10s %s", tool, SafeImage::Runner.available?(tool) ? "ok" : "missing")
end
puts format("%-10s %s", "libvips", SafeImage::VipsGlue.available? ? "ok" : "unavailable")
puts format("%-10s %s", "sandbox", SafeImage.sandbox_available? ? "ok" : "unavailable")
```

## API

All operations are module functions on `SafeImage` and run on the configured
backend. Operations that decode an image accept `max_pixels:` to override the
configured decompression-bomb ceiling for that one call.

### Return values

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
  backend:,        # e.g. "libvips-direct", "imagemagick", "cjpegli",
                   #      "libvips-direct+cjpegli"
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
  tools: ["jpegoptim"],
  rotated_from: nil,  # the EXIF orientation baked into the pixels, when one was set
  trimmed: false      # true when uprighting dropped partial edge blocks (see optimize)
}
```

### Probing and metadata

Metadata operations for local files. `type`, `size`/`dimensions`,
`orientation`, and `info` are intended to cover the local-file parts of APIs
like `FastImage.type`, `FastImage.size`, and `FastImage#orientation` without
adding a Ruby dependency. None of these fetch remote URLs — see
[Remote URLs](#remote-urls) for that.

#### `SafeImage.probe(path, max_pixels: nil)`

Reads image metadata through the configured backend.

Supported inputs on the `:vips` backend:

- `jpg` / `jpeg`
- `png`
- `gif` (first frame, via libvips' bundled libnsgif loader)
- `webp`
- `heic` / `heif`
- `avif`
- `jxl` (requires a libvips build with libjxl support)
- `ico` (pure-Ruby directory parse on either backend; reports the largest
  entry's dimensions)

```ruby
info = SafeImage.probe("upload.jpg", max_pixels: 40_000_000)
puts "#{info.width}x#{info.height} #{info.input_format}"
```

Raises `SafeImage::LimitError` if `width * height > max_pixels`.

#### `SafeImage.type(path, max_pixels: nil)`

Returns a FastImage-style symbol for a local file:

```ruby
SafeImage.type("upload.jpg") # => :jpeg
SafeImage.type("upload.png") # => :png
SafeImage.type("icon.svg")   # => :svg
```

JPEG is returned as `:jpeg`, not `:jpg`, to match common Ruby image-probing
conventions.

#### `SafeImage.size(path, max_pixels: nil)` / `SafeImage.dimensions(path, max_pixels: nil)`

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

#### `SafeImage.orientation(path, max_pixels: nil)`

Returns the EXIF orientation integer (1-8) for a local file. On the `:vips`
backend it is read from the orientation header field the native loaders
populate during the header scan — no pixel data is decoded — and garbage tag
values clamp to `1`. On the `:imagemagick` backend it comes from `identify`.
SVG and ICO report `1` by definition.

Note one deliberate HEIC difference: libheif applies the container's
`irot`/`imir` transforms during decode, so the native path reports the
orientation of the pixels as actually decoded, rather than echoing a raw
EXIF tag that may already be baked in.

```ruby
SafeImage.orientation("upload.jpg") # => 1
```

#### `SafeImage.info(path, max_pixels: nil, animated: false, orientation: false)`

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

#### `SafeImage.frame_count(path, max_pixels: nil)`

Returns the frame count. On the `:vips` backend it comes from the n-pages
header field via the native loaders — no pixel data is decoded; on the
`:imagemagick` backend from `identify`. ICO directories are counted by the
pure-Ruby parser on either backend.

```ruby
frames = SafeImage.frame_count("animated.gif")
```

#### `SafeImage.animated?(path, max_pixels: nil)`

Returns `true` when `frame_count(path) > 1`.

```ruby
SafeImage.animated?("animated.webp")
```

#### `SafeImage.dominant_color(path, max_pixels: nil)`

Computes the image's alpha-weighted average colour (first frame for animated
formats) and returns it as an uppercase `RRGGBB` hex string.

The `:vips` backend computes the exact per-channel mean natively, with ICO
decoded by the pure-Ruby parser. The `:imagemagick` backend uses a histogram
command. The two backends agree to within a few least-significant bits per
channel (ImageMagick averages through its resize filter rather than computing
the exact mean).

The pixel cap is enforced before the full decode on either backend,
undecodable input raises `InvalidImageError`, and SVG input raises
`UnsupportedFormatError`.

```ruby
SafeImage.dominant_color("upload.png") # => "6F745E"
```

### Remote URLs

These helpers are intended to cover `FastImage.size(url)` / `FastImage.type(url)`
style use cases without another Ruby dependency. They use only Ruby stdlib
`Net::HTTP` and stream to a tempfile with a byte cap.

Like FastImage, the metadata helpers (`remote_size`, `remote_type`,
`remote_info`, `remote_animated?`) download as little as possible: the normal
Safe Image local metadata path probes the partially-downloaded tempfile as
bytes arrive (first at 64KB, then at growing thresholds) and the transfer is
aborted as soon as the answer is final — typically after the first 64KB.
Early answers are only trusted when more data cannot change them:

- "not animated" is reported only from the complete file, because a truncated
  animation undercounts frames; "animated" is final as soon as a second frame
  is seen
- SVG metadata always downloads the whole document, so the SVG parser's total
  size cap keeps its meaning
- a probe failure on a prefix just means the download continues; a file that
  never yields an early answer is downloaded and validated exactly like a
  `fetch_remote` download

`fetch_remote` and `remote_dominant_color` need the complete body and always
download it (up to `max_bytes`).

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
- initial caller-supplied request headers use the same small allowlist; cookies,
  authorization headers, and custom auth headers are not forwarded by default
- hop-by-hop/proxy/`Host` request headers are rejected before any request
- private, loopback, link-local, multicast, documentation, benchmarking,
  carrier-grade NAT, IPv4-mapped IPv6, NAT64, 6to4/Teredo, and other
  special-use resolved addresses are rejected by default
- no image decoding happens directly from the socket; probes only ever see the
  on-disk tempfile
- the final response `Content-Type` must be an allowed image type and must agree
  with an image-looking URL extension when one is present — both are enforced
  from the response headers, before any body bytes are downloaded
- the first bytes of the body must be compatible with the claimed format's
  magic bytes (SVG, which has no signature, is exempt); an obviously mislabeled
  body is dropped after the first chunk instead of being downloaded to the cap
- downloaded content is probed before `fetch_remote` yields the tempfile, so the
  raw downloader cannot be used as a blind extension-based file saver
- SVG remote metadata uses the same bounded SVG metadata parser after download;
  SVG is not handed to ImageMagick for probing

Set `allow_private: true` only when the caller has already made an SSRF decision
or is intentionally probing a trusted internal URL. Passing `allow_private: true`
also permits non-standard ports; for public fetches, pass `allowed_ports:` if you
really need to allow a different port.

#### `SafeImage.remote_size(url, ...)` / `SafeImage.remote_dimensions(url, ...)`

```ruby
SafeImage.remote_size(
  "https://example.com/image.jpg",
  max_bytes: 10.megabytes,
  total_timeout: 30,
  max_pixels: 40_000_000
)
# => [1600, 1200]
```

#### `SafeImage.remote_type(url, ...)`

```ruby
SafeImage.remote_type("https://example.com/image.png", max_bytes: 10.megabytes)
# => :png
```

#### `SafeImage.remote_info(url, ...)`

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

#### `SafeImage.remote_animated?(url, ...)`

```ruby
SafeImage.remote_animated?("https://example.com/image.webp", max_bytes: 10.megabytes)
# => true / false
```

#### `SafeImage.remote_dominant_color(url, ...)`

```ruby
SafeImage.remote_dominant_color("https://example.com/image.png", max_bytes: 10.megabytes)
# => "6F745E"
```

#### `SafeImage.fetch_remote(url, ...) { |path| ... }`

Downloads a remote image to a tempfile and yields the local path:

```ruby
SafeImage.fetch_remote("https://example.com/image.jpg", max_bytes: 10.megabytes) do |path|
  SafeImage.probe(path)
end
```

With `landlock: true` configured, the network fetch itself is not put inside
the Landlock worker because the worker denies network access. The downloaded
tempfile is then passed through the normal Safe Image local image APIs, so
decoding still uses the same sandboxed image-processing path.

### Generating images

Operations that write a new image. All of them run on the configured backend
and return [`SafeImage::Result`](#return-values).

#### `SafeImage.thumbnail(...)`

Creates a center-cropped thumbnail.

```ruby
result = SafeImage.thumbnail(
  input: "upload.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  format: nil,              # inferred from output extension when nil
  quality: 85,
  max_pixels: 40_000_000,   # overrides the configured ceiling for this call
  optimize: true,
  optimize_mode: :lossless, # :lossless or :lossy for PNG optimisation
  chroma_subsampling: :auto # :auto, "420", "422", "444" for JPEG output
)
```

Supported outputs on the `:vips` backend:

- `jpg` / `jpeg`
- `png`
- `gif` (requires a libvips build with cgif support; raises `UnsupportedFormatError` otherwise)
- `webp`
- `avif`
- `jxl` (requires a libvips build with libjxl support)

#### `SafeImage.resize(from, to, width, height, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)`

Creates a resized thumbnail-style output.

```ruby
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400)
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400, quality: 85)
```

`resize`, `crop` and `downsize` run on the configured backend:

- `:vips` — the direct libvips path; formats outside the native loader
  allowlist (ICO input) fail closed
- `:imagemagick` — matches classic `convert` thumbnail pipelines
  (`-thumbnail`, catrom interpolation, unsharp, sRGB profile); configure this
  if byte-similar output with previously generated thumbnails matters

#### `SafeImage.crop(from, to, width, height, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)`

Creates a north-cropped image — the shape typically used for square avatar
crops.

```ruby
SafeImage.crop("upload.jpg", "avatar.jpg", 240, 240)
```

#### `SafeImage.downsize(from, to, dimensions, optimize: true, max_pixels: nil, quality: 85, chroma_subsampling: :auto)`

Downsizes an image using ImageMagick-style geometry strings.

```ruby
SafeImage.downsize("large.png", "small.png", "50%")
SafeImage.downsize("large.png", "small.png", "100x100>")
SafeImage.downsize("large.png", "small.png", "400000@")
```

The vips backend supports the geometry forms covered by the test suite:
percentage, bounding box with `>`, and pixel-area cap with `@`.

#### `SafeImage.convert(from, to, format:, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)`

Converts an input image to an explicit output `format:`. Unsupported formats
raise `SafeImage::UnsupportedFormatError`.

On the `:vips` backend this decodes through the native libvips loaders,
auto-orients, flattens transparency onto white for JPEG targets (matching the
ImageMagick path's `-background white -flatten`), and re-encodes. When no
`quality:` is given, native JPEG output uses quality 92 — what ImageMagick
uses for sources without quality tables — rather than libvips' default 75.
ICO input/output is outside the native loaders and fails closed (use
`convert_favicon_to_png` for favicons, or the `:imagemagick` backend).

For PNG-to-JPEG on the `:vips` backend, `cjpegli` is used automatically when
installed (see [JPEG encoding of generated images](#jpeg-encoding-of-generated-images)).

```ruby
SafeImage.convert("upload.png", "upload.jpg", format: "jpg", quality: 85)
SafeImage.convert("upload.heic", "upload.jpg", format: "jpg", quality: 85)
SafeImage.convert("upload.jpg", "upload.webp", format: "webp", quality: 85)
```

#### `SafeImage.fix_orientation(from, to = from, max_pixels: nil, quality: nil)`

Bakes the EXIF orientation into the pixels and clears the tag. The `:vips`
backend tries tiers in order:

1. **jpegtran (lossless)** — for JPEGs with `jpegtran` installed, the
   transform happens on the DCT coefficients with zero generation loss.
   `-perfect` refuses non-MCU-aligned dimensions, in which case:
2. **libvips re-encode** — autorotate and re-encode, stripping metadata.
   JPEG output uses `quality:` (default 95).

The `:imagemagick` backend uses the previous `-auto-orient` behaviour and
re-encodes at the input's estimated quality.

If `to` is omitted, the file is rewritten in place.

```ruby
SafeImage.fix_orientation("upload.jpg")
SafeImage.fix_orientation("upload.jpg", "oriented.jpg")
```

#### `SafeImage.convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)`

Extracts the largest ICO entry and writes PNG. On the `:vips` backend no
ImageMagick is involved: the container and legacy DIB payloads (1/4/8/24/32bpp
BI_RGB plus the AND mask) are parsed in pure Ruby with explicit bounds checks,
and pixels are encoded through the hardened native libvips path. Embedded PNG
payloads are re-encoded — never copied through verbatim — and their pixel cap
is enforced from the IHDR before any decoder runs. On the `:imagemagick`
backend the conversion runs through ImageMagick's ico decoder under the
bundled policy.

```ruby
SafeImage.convert_favicon_to_png("favicon.ico", "favicon.png")
```

#### `SafeImage.letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "DejaVu-Sans")`

Generates a square letter avatar PNG: one grapheme blended in white at 80%
opacity over a solid background.

The `:vips` backend renders natively through libvips' Pango text support (the
glyph is markup-escaped before rendering) and fails closed on builds without
a text renderer; the `:imagemagick` backend uses ImageMagick's annotation
path.

The default `DejaVu-Sans` font uses the DejaVu Sans file bundled with the gem
(see `lib/safe_image/fonts/DEJAVU-LICENSE`), so rendering does not depend on
which fonts the host has installed. The other allowlisted tokens
(`NimbusSans-Regular`, `Liberation-Sans`, `Arial`, `Helvetica`,
`Adwaita-Sans`) resolve through fontconfig.

The native path centres the glyph's ink box optically, which differs from the
ImageMagick path's baseline placement (where descenders could clip at the
canvas edge). Treat switching backends as a visual change: regenerate cached
avatars.

```ruby
SafeImage.letter_avatar(
  output: "avatar.png",
  size: 360,
  background_rgb: [1, 2, 3],
  letter: "S"
)
```

#### JPEG encoding of generated images

Safe Image separates **encoding generated JPEGs** from **optimising existing
JPEGs**. This avoids hiding a lossy re-encode behind a method named `optimize`.

Like the optimizer tools, the optional `cjpegli` encoder is availability
driven: installed means used, absent means the configured backend encodes.
There is no encoder knob. Even when cjpegli is used, untrusted inputs are first
decoded by the configured Safe Image backend with the normal pixel cap; cjpegli
only receives a PNG generated by Safe Image, so it is not an additional
untrusted-input decoder.

| Operation | Behavior |
| --- | --- |
| `thumbnail` / `resize` / `crop` / `downsize` to JPEG on the `:vips` backend | decode through libvips first, then use `cjpegli` when installed; otherwise normal libvips JPEG output |
| `convert("input.png", "output.jpg", format: "jpg")` on the `:vips` backend | decode the PNG through libvips into a generated PNG first, then use `cjpegli` when installed; otherwise libvips |
| `convert` from HEIC/WebP/AVIF/GIF/JPEG/JXL to JPEG | decode through the native libvips loaders and encode with libvips; `cjpegli` is not treated as a universal decoder |
| any operation on the `:imagemagick` backend | ImageMagick encodes; `cjpegli` is never used |
| `optimize("existing.jpg")` | use `jpegoptim`; never `cjpegli` |

`cjpegli` output is ordinary browser-compatible JPEG. It is optional because it
is a system binary, not a Ruby dependency. Safe Image detects it at runtime.

`chroma_subsampling: :auto` uses `4:4:4` for PNG-sourced JPEG conversion and
`4:2:0` otherwise. Pass `"420"`, `"422"`, or `"444"` to force a value.

### Optimising in place

#### `SafeImage.optimize(path, mode: :lossless, strip_metadata: true, quality: nil, strict: true)`

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
- an EXIF-oriented JPEG is uprighted first with jpegtran's lossless
  transforms, because stripping would otherwise delete the orientation tag
  without applying the rotation and ship the image sideways. MCU-aligned
  images rotate exactly (`-perfect`); others drop the partial edge blocks
  (`-trim`, under one MCU — at most 15px), reported as `trimmed: true` in
  the result rather than re-encoding behind a method named `optimize`.
  Without `jpegtran`, an oriented JPEG raises in strict mode and is left
  untouched otherwise — never stripped sideways.

PNG path:

- uses `oxipng` for lossless optimisation
- when `mode: :lossy`, uses `pngquant` first for PNGs smaller than 500 KB,
  then `oxipng`

When `strict: true`, missing optimizer tools raise. When `strict: false`, missing
optimizer tools are tolerated.

### SVG sanitising

#### `SafeImage.sanitize_svg!(path, max_pixels: nil, id_namespace:)`

Sanitises an SVG in place using a small XML allowlist. Like other image
operations, `max_pixels:` defaults to the value configured with
`SafeImage.configure!` and rejects oversized SVG viewports before rewriting.
`id_namespace:` is
**required** — it forces a deliberate choice of where the output may be used,
so there is no silently-wrong default (see "Inlining" below):

```ruby
# served as an <img src>/CSS-url/file and never spliced into a page's DOM:
result = SafeImage.sanitize_svg!("icon.svg", id_namespace: :standalone)

# spliced inline into an HTML DOM (pass a stable, per-document token):
result = SafeImage.sanitize_svg!("icon.svg", id_namespace: "u#{upload.sha1}")

puts result[:sanitized]
```

Omitting `id_namespace:` (or passing `nil`/`""`) raises `ArgumentError`.

The sanitizer removes unsafe elements/attributes such as scripts and event
handlers. It is intentionally conservative rather than a full browser-grade SVG
implementation.

CSS is reduced to a constructed allowlist subset rather than stripped: `style`
attributes (as written by Inkscape) and `<style>` elements (as written by
Illustrator) survive when they parse against a small grammar — allowlisted
properties, type/class/id selectors, numeric/keyword/color values, and
`url(#fragment)` references only. The output is reassembled from validated
tokens, never echoed from the input; escapes, quotes, at-rules (`@import`,
`@font-face`, `@media`), comments, strings, and unknown
properties/functions/selectors drop the declaration, rule, or whole stylesheet
rather than being interpreted.

Two behaviours are worth knowing before relying on this:

- **The CSS property allowlist mirrors the presentation attributes that have
  CSS-property twins** — `SvgCss::ALLOWED_PROPERTIES` is a subset of
  `SvgSanitizer::ALLOWED_ATTRIBUTES` (asserted by a test), so a `fill:`
  declaration and a `fill=""` attribute are treated identically and a property
  the sanitizer would strip as an attribute is also dropped in CSS. (The
  reverse does not hold: geometry/XML attributes like `width`, `href`, and
  `xmlns` are not CSS properties.) The set covers the common paint, stroke
  (including `stroke-dasharray` and `vector-effect`), marker, text, and
  visibility properties that Inkscape and Illustrator emit; it is deliberately
  narrower than a browser. Filters (`filter`, `fe*`) are not yet included.
- **A `<style>` element fails closed as a whole** on anything outside a flat
  list of `selector { declarations }` rules. Any at-rule (e.g. one stray
  `@import`), a nested block, or an unbalanced brace discards every rule in that
  element, not just the offending one. Within a well-formed stylesheet,
  individual selectors and declarations still drop independently.

SVG sanitising is defense-in-depth for stored bytes. Applications that serve
user-supplied SVGs directly should still use response-level controls such as a
restrictive `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, and/or
attachment/sandbox handling for direct-open routes. Browsers restrict script
execution when an SVG is embedded as `<img>`, but a top-level SVG document is a
different sink.

#### Inlining sanitized SVG into an HTML page

The `id_namespace:` argument forces this decision at every call site — there is
no default to get wrong.

Pass `:standalone` when the output is only ever served as an external resource —
`<img src>`, `background-image`, an `<object>`/`<iframe>`, or its own file. This
is the document-safe form. It is **not** safe to splice directly into an HTML
DOM: a preserved `<style>` rule like `*{visibility:hidden}` or
`#header{display:none}` would join the host document's cascade, and the SVG's
`id`s could clobber host ids — both CSS-injection / UI-redress vectors.

Pass a **stable, per-document** String (e.g. the upload's sha) to make the output
safe to inline:

```ruby
SafeImage.sanitize_svg!("icon.svg", id_namespace: "u#{upload.sha1}")
```

With a namespace, the sanitizer:

- prefixes every `id` and every reference to it — `href`/`xlink:href` fragments,
  `url(#…)` in attributes and CSS, and ARIA IDREF attributes (`aria-labelledby`,
  `aria-describedby`, `aria-controls`, …) — then drops any reference that does
  not resolve inside the sanitized SVG, so internal references stay intact but
  cannot collide with or bind to host ids; and
- prefixes every `class` token (and the `.class` selectors that match them), so
  an attacker can't invoke the host page's framework CSS — a bare
  `class="modal fixed"` would otherwise pick up Bootstrap/Tailwind/app styles and
  become an overlay. Internal class styling still matches because attribute and
  selector are prefixed together; and
- scopes every `<style>` selector under a `<ns>-scope` class it adds to the root
  `<svg>`, so `*` and type selectors only match that document's own content and
  can never reach the host page; and
- rejects `var()`, `env()`, and `attr()` in presentation attributes — they
  resolve against the host page (custom properties, environment) and could pull
  in values, including a `url()`, the sanitizer never saw; and
- drops `overflow` from the root `<svg>` so it clips to its declared viewport — a
  tiny `width`/`height` with `overflow:visible` and oversized content would
  otherwise paint a full-page overlay. Inner elements keep `overflow` (markers
  need it); the root clip bounds them.

Because every `<style>` selector is anchored *under* the scope class, a rule
targeting the root itself — `svg { … }`, `* { … }` intended to include the root,
or a class on the root such as `.icon { … }` for `<svg class="icon">` — matches
the root's descendants but not the root element. Root-level styling from a
`<style>` block therefore does not survive; style the root via attributes if you
need it. (This is rare in editor exports, which style the root with attributes
and inner elements with classes.)

`style=""` attributes never need selector scoping — a declaration list only
styles its own element — so they are not a cascade risk in either mode. They can
still carry `url(#…)` references, though, which are only namespaced when you pass
a String; so `:standalone` output (bare ids and references) is still not for
inline use. The transform is idempotent for a given namespace, so re-sanitising
is a no-op. Use a per-document value so two inlined SVGs on one page don't share
a namespace.

### Compatibility aliases

Two thin wrappers kept for callers migrating from existing upload pipelines:

```ruby
SafeImage.optimize_image!("image.jpg")
SafeImage.optimize_image!("image.png", allow_lossy_png: true)
SafeImage.convert_to_jpeg("upload.heic", "upload.jpg", quality: 85)
```

`optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil, strict: true)`
forwards to `optimize`, with `allow_lossy_png:` mapping to `mode:`.
`convert_to_jpeg(from, to, ...)` forwards to `convert` with `format: "jpg"`
and accepts the same keywords.

## Security

Safe Image is not magic pixie dust. It is a deliberately small choke point:
the goal is to centralize risky operations, make the safe path boring, and
remove common image-processing foot-guns.

What it does:

- forces one explicit, eagerly validated `configure!` decision — which backend
  decodes untrusted bytes, whether the Landlock sandbox is on — before any
  operation runs; everything else raises `NotConfiguredError`
- uses explicit argv arrays for external commands, never shell strings
- starts external commands with an allowlisted environment, private temp/home/cache
  directories, bounded stdout/stderr, and process-group timeout cleanup
- uses explicit libvips loaders selected from allowlisted extensions
- enables libvips' untrusted-operation block in-process (deliberately
  re-enabling only the libjxl loader/saver, which libvips tags untrusted,
  because JPEG XL is part of the supported input surface)
- blocks libvips ImageMagick loader classes in the libvips binding, which
  itself exposes only the operations the gem invokes
- disables libvips cache by default in-process
- strips metadata on generated images where applicable
- rejects symlinked local input/output paths and symlinked path components for
  untrusted file-processing paths
- caps decoded pixels before expensive work: the libvips path enforces a
  default `SafeImage::DEFAULT_MAX_PIXELS` (128MP) ceiling even when no
  `max_pixels` is given, and callers can raise or lower it per call
- ships a restrictive ImageMagick `policy.xml`
- denies Ghostscript-backed formats and dangerous ImageMagick features:
  - `PS`, `PS2`, `PS3`, `EPS`, `EPSF`, `PDF`, `XPS`, `PCL`
  - `MSL`, `MVG`
  - `HTTP`, `HTTPS`, `URL`
  - delegates, filters, and `@file` indirection
- hardens remote fetch against SSRF: scheme/port restrictions, special-use IP
  blocking, DNS pinning, redirect limits, HTTPS-to-HTTP rejection, proxy-env
  bypass prevention, request-header allowlists, content-type/extension
  agreement, and probe-before-yield (details under [Remote URLs](#remote-urls))
- parses SVG metadata with a bounded pure-Ruby parser; SVG is never handed to
  ImageMagick for probing
- sanitises SVG conservatively, allowlist based: rejects `DOCTYPE` and XML
  processing instructions, removes comments and disallowed elements, converts
  CDATA to escaped text, and blocks event handlers, external URLs, and
  `javascript:` / `data:` URL values
- supports optional Landlock subprocess sandboxing on Linux

The backend is a configuration decision, not a per-call option. Safe Image
will never silently fall from the libvips path into generic ImageMagick
decoding — a format the configured backend cannot decode fails closed with
`SafeImage::UnsupportedFormatError`.

### Security posture without Landlock

Without Landlock, everything above still applies; in particular the
ImageMagick path runs with:

- delegates disabled
- filters disabled
- `@file` indirection disabled
- remote URL coders disabled
- Ghostscript/document/vector formats denied
- coders deny-by-default with a small raster allowlist
- ImageMagick resource limits set in the bundled policy

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

### Atomic Landlock sandboxing

Landlock support is optional, but atomic once configured.

```ruby
SafeImage.sandbox_available?                       # => true/false, works before configure!
SafeImage.configure!(backend: :vips, landlock: true) # raises if unavailable
SafeImage.config.landlock                          # => true
```

With `landlock: true`, every public operation routes through the sandbox
worker:

- `probe`
- `type`
- `size`
- `dimensions`
- `info`
- `orientation`
- `dominant_color`
- `thumbnail`
- `optimize`
- `resize`
- `crop`
- `downsize`
- `convert`
- `convert_to_jpeg` compatibility alias
- `fix_orientation`
- `convert_favicon_to_png`
- `frame_count`
- `animated?`
- `letter_avatar`
- `optimize_image!`
- `sanitize_svg!`

There is no silent fallback once landlock is configured. If sandbox setup or
a sandboxed command fails, the operation fails.

The sandbox grants read/write access only to the paths inferred from the
operation arguments, plus runtime/library paths and temporary directories needed
by Ruby, libvips, ImageMagick, and optimizer tools. Worker processes inherit the
parent's backend and pixel-ceiling configuration; landlock is forced off
inside the worker so sandboxed operations never nest.

Operations are served by a pool of resident **zygote** workers: each is a
fresh Ruby process that boots the gem once and then forks a child per
operation, so the ~85ms boot cost (Ruby + requires + libvips init) is paid
once per burst instead of per call — a warm sandboxed operation costs ~3–8ms
over the unsandboxed one. The pool grows on demand to
`SAFE_IMAGE_ZYGOTE_WORKERS` (default 8), so N threads run N sandboxed
operations concurrently (throughput scales near-linearly with cores until the
work itself saturates the CPU); offered concurrency past the cap blocks until
a worker frees, which also bounds how many libvips decodes run at once.
Idling is cheap (~16MB private memory per worker, zero CPU), so a worker
lingers for `Zygote::IDLE_SECONDS` (300) without work before exiting on its
own; the next operation boots a new one. Workers also exit immediately when
their parent process does, and `configure!` always retires the pool.

A zygote itself never touches untrusted bytes: each forked child first
applies rlimits, its per-operation Landlock policy (filesystem allowlist, all
TCP denied on Landlock ABI ≥ 4, abstract-unix-socket/signal scopes on
ABI ≥ 6), and — when the installed `landlock` gem exposes
`seccomp_deny_network!` — the helper's deny-all-network seccomp filter (which
blocks sockets of every family, closing the non-TCP/UDP gap the in-process
Landlock policy alone leaves open), and only then runs the operation. Forking
is sound because the zygote never runs operations itself — libvips is
initialised but quiescent (no native threads) at every fork.

`SAFE_IMAGE_ZYGOTE=0` falls back to the exec-per-operation worker (a fresh
sandboxed Ruby per call through the Landlock helper binary, whose seccomp
filter denies sockets of every family, no pool); `SAFE_IMAGE_ZYGOTE_WORKERS`
and `SAFE_IMAGE_ZYGOTE_IDLE_SECONDS` tune the pool cap and idle window.

## Development

```bash
bundle install
bundle exec rake          # run the tests (nothing compiles)
docker/run.sh             # run the suite on Debian bookworm's packaged libvips 8.14
bundle exec rubocop       # lint
```

The minitest suite lives in `test/*_test.rb`; individual files run standalone
(`bundle exec ruby test/operations_test.rb`). Tests that depend on optional
host support — cjpegli, HEIC delegates, the Landlock sandbox — skip with an
explanation when that support is missing.

The suite includes golden-output checks, cross-backend parity checks (the
claim is operation parity, not byte-for-byte output identity across
ImageMagick/libvips versions), policy-denial checks, and a real-image atomic
sandbox sweep over the full public operation list.

Gem packaging uses the standard Bundler tasks (`rake build`, `rake install`).
Releases: bump `SafeImage::VERSION`, merge to `main`, and CI publishes the
gem to RubyGems once the test matrix is green.

## Security reporting

Please report suspected security issues privately to `sam@discourse.org`.

See [`SECURITY.md`](SECURITY.md) for the threat model, non-goals, and reporting
checklist.

## License

Safe Image is MIT licensed.

The gem dynamically links to system `libvips`; `libvips` is
LGPL-2.1-or-later. Safe Image does not vendor `libvips`.

The gem bundles the DejaVu Sans font for deterministic letter-avatar
rendering; its license (Bitstream Vera derivative, freely redistributable)
ships alongside the font at `lib/safe_image/fonts/DEJAVU-LICENSE`.

Optional command-line tools are discovered at runtime and executed as external
programs; they are not bundled into the gem. Typical licenses for those optional
tools are:

| Tool | Purpose | Typical license |
| --- | --- | --- |
| ImageMagick `magick` / `convert` / `identify` | `:imagemagick` backend operations | ImageMagick license |
| `jpegoptim` | JPEG lossless optimisation / metadata stripping | GPL-2.0-or-later |
| `oxipng` | PNG lossless optimisation | MIT |
| `pngquant` | optional lossy PNG quantisation | GPL-3.0-or-later / ISC / BSD-2-Clause components |
| `cjpegli` / `djpegli` / `cjxl` | optional JPEG/JPEG XL tooling when installed | BSD-3-Clause via libjxl |
| `heif-enc` / libheif tools | optional HEIC/AVIF tooling when installed | LGPL-3.0-or-later |

Deployment packages may vary; check your distribution's package metadata if
license compliance depends on the exact binary build.
