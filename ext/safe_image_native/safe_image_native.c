#include <ruby.h>
#include <vips/vips.h>
#include <sys/stat.h>
#include <string.h>
#include <time.h>
#include <math.h>

static VALUE mSafeImage;
static VALUE mNative;
static VALUE eError;
static VALUE eUnsupported;
static VALUE eInvalid;
static VALUE eLimit;

/* Default decompression-bomb ceiling applied when the caller does not pass an
 * explicit max_pixels. Mirrors SafeImage::DEFAULT_MAX_PIXELS and the 128MP area
 * limit used on the ImageMagick path, so the libvips fast path is not unbounded
 * by default. Callers that legitimately need larger images pass max_pixels. */
#define SAFE_IMAGE_DEFAULT_MAX_PIXELS (128LL * 1024 * 1024)

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static const char *extname(const char *path) {
  const char *dot = strrchr(path, '.');
  return dot ? dot + 1 : "";
}

static int streq_ci(const char *a, const char *b) {
#ifdef _WIN32
  return _stricmp(a, b) == 0;
#else
  return strcasecmp(a, b) == 0;
#endif
}

static const char *normalized_format(const char *fmt) {
  if (streq_ci(fmt, "jpg") || streq_ci(fmt, "jpeg")) return "jpg";
  if (streq_ci(fmt, "png")) return "png";
  if (streq_ci(fmt, "webp")) return "webp";
  if (streq_ci(fmt, "gif")) return "gif";
  if (streq_ci(fmt, "heic") || streq_ci(fmt, "heif")) return "heic";
  if (streq_ci(fmt, "avif")) return "avif";
  return NULL;
}

static void raise_vips(void) {
  const char *msg = vips_error_buffer();
  VALUE rb_msg = rb_str_new_cstr(msg && *msg ? msg : "libvips error");
  vips_error_clear();
  rb_exc_raise(rb_exc_new3(eInvalid, rb_msg));
}

static void init_vips_once(void) {
  static int initialized = 0;
  if (initialized) return;
  if (VIPS_INIT("safe_image") != 0) raise_vips();

  /* Avoid libvips operations that are explicitly tagged as unsafe for
   * untrusted input. Also block ImageMagick-backed loaders by class name;
   * this gem uses explicit native libvips loaders and should never fall back
   * to ImageMagick delegates. */
  vips_block_untrusted_set(TRUE);
  vips_operation_block_set("VipsForeignLoadMagick", TRUE);
  vips_operation_block_set("VipsForeignLoadMagick6", TRUE);
  vips_operation_block_set("VipsForeignLoadMagick7", TRUE);

  /* Keep the embedded path predictable and bounded. Callers that want harder
   * isolation should run this gem inside a sandboxed worker process. */
  vips_concurrency_set(1);
  vips_cache_set_max(0);
  vips_cache_set_max_mem(0);
  vips_cache_set_max_files(0);
  initialized = 1;
}

static VipsImage *load_explicit(const char *path, const char **fmt_out) {
  init_vips_once();
  const char *fmt = normalized_format(extname(path));
  if (!fmt) rb_raise(eUnsupported, "unsupported input format");

  VipsImage *image = NULL;
  int rc = -1;
  if (strcmp(fmt, "jpg") == 0) {
    rc = vips_jpegload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "png") == 0) {
    rc = vips_pngload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "webp") == 0) {
    rc = vips_webpload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "gif") == 0) {
    /* libnsgif-backed loader: ships inside libvips and stays within the
     * untrusted-input block, unlike the Magick loaders. Loads the first
     * frame only (the n=1 default), matching the [0] semantics of the
     * ImageMagick compatibility backend. */
    if (!vips_type_find("VipsOperation", "gifload"))
      rb_raise(eUnsupported, "this libvips build has no GIF loader");
    rc = vips_gifload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "heic") == 0 || strcmp(fmt, "avif") == 0) {
    rc = vips_heifload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  }

  if (rc != 0 || image == NULL) raise_vips();
  *fmt_out = fmt;
  return image;
}

static void validate_quality_or_raise(int quality) {
  if (quality < 1 || quality > 100) rb_raise(rb_eArgError, "quality must be 1..100");
}

static void validate_dimensions_or_raise(int width, int height) {
  if (width <= 0 || height <= 0) rb_raise(rb_eArgError, "width and height must be positive");
}

static void validate_scale_or_raise(double scale) {
  if (!isfinite(scale) || scale <= 0.0 || scale > 100.0) rb_raise(rb_eArgError, "scale must be finite and in 0..100");
}

static int pixels_exceed_limit(VipsImage *image, VALUE max_pixels_val, long long *pixels_out, long long *max_out) {
  long long max_pixels;
  if (NIL_P(max_pixels_val)) {
    max_pixels = SAFE_IMAGE_DEFAULT_MAX_PIXELS;
  } else {
    max_pixels = NUM2LL(max_pixels_val);
    if (max_pixels <= 0) rb_raise(rb_eArgError, "max_pixels must be positive");
  }
  if (image->Xsize <= 0 || image->Ysize <= 0) rb_raise(eInvalid, "image dimensions are invalid");
  long long pixels = (long long)image->Xsize * (long long)image->Ysize;
  if (pixels_out) *pixels_out = pixels;
  if (max_out) *max_out = max_pixels;
  return pixels > max_pixels;
}

static void raise_pixels_limit(long long pixels, long long max_pixels) {
  rb_raise(eLimit, "image has %lld pixels, exceeds %lld", pixels, max_pixels);
}

static int save_explicit(VipsImage *image, const char *path, const char *fmt, int quality) {
  if (strcmp(fmt, "jpg") == 0) {
    return vips_jpegsave(image, path,
      "Q", quality,
      "interlace", FALSE,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "png") == 0) {
    return vips_pngsave(image, path,
      "compression", 6,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "webp") == 0) {
    return vips_webpsave(image, path,
      "Q", quality,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "avif") == 0) {
    return vips_heifsave(image, path,
      "Q", quality,
      "compression", VIPS_FOREIGN_HEIF_COMPRESSION_AV1,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "gif") == 0) {
    /* cgif-backed saver; optional at libvips build time, so probe for it.
     * GIF output is palette-quantised and has no quality parameter. */
    if (!vips_type_find("VipsOperation", "gifsave"))
      rb_raise(eUnsupported, "this libvips build cannot save GIF (cgif support missing)");
    return vips_gifsave(image, path,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  }
  rb_raise(eUnsupported, "unsupported output format");
}

static VALUE rb_probe(VALUE self, VALUE path_val) {
  Check_Type(path_val, T_STRING);
  double start = now_ms();
  const char *fmt = NULL;
  VipsImage *image = load_explicit(StringValueCStr(path_val), &fmt);
  int width = image->Xsize;
  int height = image->Ysize;
  double duration_ms = now_ms() - start;
  g_object_unref(image);

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("format")), rb_str_new_cstr(fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(width));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(height));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(duration_ms));
  return hash;
}

static VALUE rb_thumbnail(VALUE self, VALUE input_val, VALUE output_val, VALUE width_val, VALUE height_val, VALUE format_val, VALUE quality_val, VALUE max_pixels_val) {
  Check_Type(input_val, T_STRING);
  Check_Type(output_val, T_STRING);
  Check_Type(format_val, T_STRING);
  int width = NUM2INT(width_val);
  int height = NUM2INT(height_val);
  int quality = NUM2INT(quality_val);
  validate_dimensions_or_raise(width, height);
  validate_quality_or_raise(quality);
  const char *out_fmt = normalized_format(StringValueCStr(format_val));
  if (!out_fmt || strcmp(out_fmt, "heic") == 0) rb_raise(eUnsupported, "unsupported output format");

  const char *input_path = StringValueCStr(input_val);
  double start = now_ms();

  /* Read the header through an explicit allowlisted loader. This validates the
   * input format (the loader fails on mismatched bytes) and lets us enforce the
   * pixel-count limit before any full decode happens. */
  const char *input_fmt = NULL;
  VipsImage *header = load_explicit(input_path, &input_fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(header, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(header);
    raise_pixels_limit(pixels, max_pixels);
  }
  g_object_unref(header);

  /* Thumbnail straight from the file so libvips can shrink on load (e.g.
   * libjpeg DCT downscaling) instead of decoding the source at full
   * resolution. vips_thumbnail auto-rotates from the orientation tag by
   * default. ImageMagick loader classes are blocked globally in
   * init_vips_once, so this still cannot reach an ImageMagick delegate. */
  VipsImage *thumb = NULL;
  if (vips_thumbnail(input_path, &thumb, width,
      "height", height,
      "size", VIPS_SIZE_BOTH,
      "crop", VIPS_INTERESTING_CENTRE,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL) != 0) {
    raise_vips();
  }

  if (save_explicit(thumb, StringValueCStr(output_val), out_fmt, quality) != 0) {
    g_object_unref(thumb);
    raise_vips();
  }

  int out_width = thumb->Xsize;
  int out_height = thumb->Ysize;
  double duration_ms = now_ms() - start;
  g_object_unref(thumb);

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("input_format")), rb_str_new_cstr(input_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("output_format")), rb_str_new_cstr(out_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(out_width));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(out_height));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(duration_ms));
  return hash;
}

static VALUE rb_resize(VALUE self, VALUE input_val, VALUE output_val, VALUE scale_val, VALUE format_val, VALUE quality_val, VALUE max_pixels_val) {
  Check_Type(input_val, T_STRING);
  Check_Type(output_val, T_STRING);
  Check_Type(format_val, T_STRING);
  double scale = NUM2DBL(scale_val);
  int quality = NUM2INT(quality_val);
  validate_scale_or_raise(scale);
  validate_quality_or_raise(quality);
  const char *out_fmt = normalized_format(StringValueCStr(format_val));
  if (!out_fmt || strcmp(out_fmt, "heic") == 0) rb_raise(eUnsupported, "unsupported output format");

  double start = now_ms();
  const char *input_fmt = NULL;
  VipsImage *in = load_explicit(StringValueCStr(input_val), &input_fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(in, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(in);
    raise_pixels_limit(pixels, max_pixels);
  }

  VipsImage *rot = NULL;
  if (vips_autorot(in, &rot, NULL) != 0) {
    g_object_unref(in);
    raise_vips();
  }

  VipsImage *out = NULL;
  if (vips_resize(rot, &out, scale, NULL) != 0) {
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  if (save_explicit(out, StringValueCStr(output_val), out_fmt, quality) != 0) {
    g_object_unref(out);
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  int out_width = out->Xsize;
  int out_height = out->Ysize;
  double duration_ms = now_ms() - start;
  g_object_unref(out);
  g_object_unref(rot);
  g_object_unref(in);

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("input_format")), rb_str_new_cstr(input_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("output_format")), rb_str_new_cstr(out_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(out_width));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(out_height));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(duration_ms));
  return hash;
}

static VALUE rb_crop_north(VALUE self, VALUE input_val, VALUE output_val, VALUE width_val, VALUE height_val, VALUE format_val, VALUE quality_val, VALUE max_pixels_val) {
  Check_Type(input_val, T_STRING);
  Check_Type(output_val, T_STRING);
  Check_Type(format_val, T_STRING);
  int width = NUM2INT(width_val);
  int height = NUM2INT(height_val);
  int quality = NUM2INT(quality_val);
  validate_dimensions_or_raise(width, height);
  validate_quality_or_raise(quality);
  const char *out_fmt = normalized_format(StringValueCStr(format_val));
  if (!out_fmt || strcmp(out_fmt, "heic") == 0) rb_raise(eUnsupported, "unsupported output format");

  double start = now_ms();
  const char *input_fmt = NULL;
  VipsImage *in = load_explicit(StringValueCStr(input_val), &input_fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(in, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(in);
    raise_pixels_limit(pixels, max_pixels);
  }

  VipsImage *rot = NULL;
  if (vips_autorot(in, &rot, NULL) != 0) {
    g_object_unref(in);
    raise_vips();
  }

  double sx = (double)width / (double)rot->Xsize;
  double sy = (double)height / (double)rot->Ysize;
  double scale = sx > sy ? sx : sy;
  scale *= 1.0000001;

  VipsImage *resized = NULL;
  if (vips_resize(rot, &resized, scale, NULL) != 0) {
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  int left = (resized->Xsize - width) / 2;
  if (left < 0) left = 0;

  VipsImage *crop = NULL;
  if (vips_extract_area(resized, &crop, left, 0, width, height, NULL) != 0) {
    g_object_unref(resized);
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  if (save_explicit(crop, StringValueCStr(output_val), out_fmt, quality) != 0) {
    g_object_unref(crop);
    g_object_unref(resized);
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  int out_width = crop->Xsize;
  int out_height = crop->Ysize;
  double duration_ms = now_ms() - start;
  g_object_unref(crop);
  g_object_unref(resized);
  g_object_unref(rot);
  g_object_unref(in);

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("input_format")), rb_str_new_cstr(input_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("output_format")), rb_str_new_cstr(out_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(out_width));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(out_height));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(duration_ms));
  return hash;
}

static VALUE rb_orientation(VALUE self, VALUE path_val, VALUE max_pixels_val) {
  Check_Type(path_val, T_STRING);
  const char *fmt = NULL;
  VipsImage *image = load_explicit(StringValueCStr(path_val), &fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(image, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(image);
    raise_pixels_limit(pixels, max_pixels);
  }

  /* Loaders set the orientation header from EXIF during the header scan, so
   * no pixel data is decoded here. Clamp garbage tag values to the EXIF
   * range; absent means upright. */
  int orientation = vips_image_get_orientation(image);
  g_object_unref(image);
  if (orientation < 1 || orientation > 8) orientation = 1;
  return INT2NUM(orientation);
}

/* Render a letter avatar: a Pango-rendered glyph blended in white at 80%
 * opacity over a solid background. The blend bg*(1-0.8*m/255) + 255*(0.8*m/255)
 * rearranges to a*mask + b per channel, so the whole composite is one
 * vips_linear over the text coverage mask. The markup string is escaped by the
 * Ruby caller; font and fontfile come from an allowlist. */
static VALUE rb_letter_avatar(VALUE self, VALUE output_val, VALUE size_val, VALUE r_val, VALUE g_val, VALUE b_val, VALUE markup_val, VALUE font_val, VALUE fontfile_val) {
  Check_Type(output_val, T_STRING);
  Check_Type(markup_val, T_STRING);
  Check_Type(font_val, T_STRING);
  Check_Type(fontfile_val, T_STRING);
  int size = NUM2INT(size_val);
  int red = NUM2INT(r_val);
  int green = NUM2INT(g_val);
  int blue = NUM2INT(b_val);
  if (size < 1 || size > 4096) rb_raise(rb_eArgError, "size must be 1..4096");
  if (red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255)
    rb_raise(rb_eArgError, "background channels must be 0..255");

  init_vips_once();
  if (!vips_type_find("VipsOperation", "text"))
    rb_raise(eUnsupported, "this libvips build has no text renderer (Pango support missing)");

  const char *markup = StringValueCStr(markup_val);
  const char *fontfile = StringValueCStr(fontfile_val);

  VipsImage *mask = NULL;
  if (markup[0] == '\0') {
    /* Blank letter: solid background only. */
    if (vips_black(&mask, size, size, NULL) != 0) raise_vips();
  } else {
    VipsImage *text = NULL;
    int rc;
    if (fontfile[0] != '\0') {
      rc = vips_text(&text, markup, "font", StringValueCStr(font_val), "dpi", 72, "fontfile", fontfile, NULL);
    } else {
      rc = vips_text(&text, markup, "font", StringValueCStr(font_val), "dpi", 72, NULL);
    }
    if (rc != 0 || text == NULL) raise_vips();

    /* vips_text returns the tight ink box; crop to the canvas when the
     * pointsize overflows it, then centre the ink optically. */
    if (text->Xsize > size || text->Ysize > size) {
      VipsImage *cropped = NULL;
      int crop_w = text->Xsize < size ? text->Xsize : size;
      int crop_h = text->Ysize < size ? text->Ysize : size;
      if (vips_extract_area(text, &cropped, (text->Xsize - crop_w) / 2, (text->Ysize - crop_h) / 2, crop_w, crop_h, NULL) != 0) {
        g_object_unref(text);
        raise_vips();
      }
      g_object_unref(text);
      text = cropped;
    }

    if (vips_embed(text, &mask, (size - text->Xsize) / 2, (size - text->Ysize) / 2, size, size, NULL) != 0) {
      g_object_unref(text);
      raise_vips();
    }
    g_object_unref(text);
  }

  double opacity = 204.0 / 255.0; /* #FFFFFFCC */
  double a[3] = {
    (255.0 - red) * opacity / 255.0,
    (255.0 - green) * opacity / 255.0,
    (255.0 - blue) * opacity / 255.0
  };
  double b[3] = { (double)red, (double)green, (double)blue };

  VipsImage *blended = NULL;
  if (vips_linear(mask, &blended, a, b, 3, NULL) != 0) {
    g_object_unref(mask);
    raise_vips();
  }
  g_object_unref(mask);

  VipsImage *out = NULL;
  if (vips_cast(blended, &out, VIPS_FORMAT_UCHAR, NULL) != 0) {
    g_object_unref(blended);
    raise_vips();
  }
  g_object_unref(blended);
  out->Type = VIPS_INTERPRETATION_sRGB;

  if (vips_pngsave(out, StringValueCStr(output_val),
      "compression", 6,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL) != 0) {
    g_object_unref(out);
    raise_vips();
  }
  g_object_unref(out);
  return Qtrue;
}

/* Encode a raw RGBA buffer (top-down rows) as PNG. Used by the pure-Ruby ICO
 * decoder so legacy DIB favicon payloads never touch ImageMagick. */
static VALUE rb_png_from_rgba(VALUE self, VALUE bytes_val, VALUE width_val, VALUE height_val, VALUE output_val) {
  Check_Type(bytes_val, T_STRING);
  Check_Type(output_val, T_STRING);
  int width = NUM2INT(width_val);
  int height = NUM2INT(height_val);
  validate_dimensions_or_raise(width, height);
  if (width > 4096 || height > 4096) rb_raise(eLimit, "rgba buffer dimensions exceed 4096x4096");
  long expected = (long)width * (long)height * 4;
  if (RSTRING_LEN(bytes_val) != expected) rb_raise(rb_eArgError, "rgba buffer must be width*height*4 bytes");

  init_vips_once();
  VipsImage *image = vips_image_new_from_memory_copy(RSTRING_PTR(bytes_val), (size_t)expected, width, height, 4, VIPS_FORMAT_UCHAR);
  if (image == NULL) raise_vips();
  image->Type = VIPS_INTERPRETATION_sRGB;

  if (vips_pngsave(image, StringValueCStr(output_val),
      "compression", 6,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL) != 0) {
    g_object_unref(image);
    raise_vips();
  }
  g_object_unref(image);
  return Qtrue;
}

static VALUE rb_pages(VALUE self, VALUE path_val, VALUE max_pixels_val) {
  Check_Type(path_val, T_STRING);
  const char *fmt = NULL;
  VipsImage *image = load_explicit(StringValueCStr(path_val), &fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(image, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(image);
    raise_pixels_limit(pixels, max_pixels);
  }

  /* Loaders fill the n-pages header from the container directory during the
   * header scan, so no pixel data is decoded here. Formats without the field
   * report one page. */
  int pages = vips_image_get_n_pages(image);
  g_object_unref(image);
  return INT2NUM(pages);
}

static VALUE rb_dominant_color(VALUE self, VALUE path_val, VALUE max_pixels_val) {
  Check_Type(path_val, T_STRING);
  const char *input_fmt = NULL;
  VipsImage *in = load_explicit(StringValueCStr(path_val), &input_fmt);
  long long pixels = 0, max_pixels = 0;
  if (pixels_exceed_limit(in, max_pixels_val, &pixels, &max_pixels)) {
    g_object_unref(in);
    raise_pixels_limit(pixels, max_pixels);
  }

  /* Normalise to 8-bit sRGB so per-band means are comparable across source
   * colourspaces and bit depths (CMYK JPEG, 16-bit PNG, grayscale). Any alpha
   * band passes through unaltered and is ignored below: the result is the
   * unweighted RGB mean, the same statistic the ImageMagick histogram path
   * reports. */
  VipsImage *srgb = NULL;
  if (vips_colourspace_issupported(in)) {
    if (vips_colourspace(in, &srgb, VIPS_INTERPRETATION_sRGB, NULL) != 0) {
      g_object_unref(in);
      raise_vips();
    }
  } else {
    srgb = in;
    g_object_ref(srgb);
  }

  /* Premultiply so transparent pixels contribute in proportion to their
   * alpha. ImageMagick's resize filters work on premultiplied data, so this
   * keeps the two backends in agreement; it is also what a human calls the
   * image's average colour. */
  int has_alpha = vips_image_hasalpha(srgb);
  VipsImage *work = NULL;
  if (has_alpha) {
    if (vips_premultiply(srgb, &work, NULL) != 0) {
      g_object_unref(srgb);
      g_object_unref(in);
      raise_vips();
    }
  } else {
    work = srgb;
    g_object_ref(work);
  }

  VipsImage *stats = NULL;
  if (vips_stats(work, &stats, NULL) != 0) {
    g_object_unref(work);
    g_object_unref(srgb);
    g_object_unref(in);
    raise_vips();
  }

  /* vips_stats returns a one-band double image: row 0 holds whole-image
   * statistics, row b+1 the statistics for band b; column 4 is the mean.
   * Grayscale sources replicate their single band across R, G and B. */
  int bands = work->Bands;
  int colour_bands = has_alpha ? bands - 1 : bands;
  if (colour_bands > 3) colour_bands = 3;
  if (colour_bands < 1) {
    g_object_unref(stats);
    g_object_unref(work);
    g_object_unref(srgb);
    g_object_unref(in);
    rb_raise(eInvalid, "image has no colour bands");
  }

  double band_mean[4] = { 0.0, 0.0, 0.0, 0.0 };
  int rows_needed = has_alpha ? colour_bands + 1 : colour_bands;
  for (int band = 0; band < rows_needed; band++) {
    /* The alpha band is always the image's last band, even when more than
     * three colour bands were clamped away above. */
    int image_band = (has_alpha && band == colour_bands) ? bands - 1 : band;
    double *vec = NULL;
    int n = 0;
    if (vips_getpoint(stats, &vec, &n, 4, image_band + 1, NULL) != 0) {
      g_object_unref(stats);
      g_object_unref(work);
      g_object_unref(srgb);
      g_object_unref(in);
      raise_vips();
    }
    band_mean[band] = n > 0 ? vec[0] : 0.0;
    g_free(vec);
  }

  g_object_unref(stats);
  g_object_unref(work);
  g_object_unref(srgb);
  g_object_unref(in);

  /* Premultiplied band means are E[c * a / 255]; dividing by the mean alpha
   * recovers the alpha-weighted colour average E[c * a] / E[a]. A fully
   * transparent image has no visible colour and reports black. */
  double means[3] = { 0.0, 0.0, 0.0 };
  double alpha_mean = has_alpha ? band_mean[colour_bands] : 255.0;
  for (int band = 0; band < 3; band++) {
    double value = band_mean[band < colour_bands ? band : colour_bands - 1];
    if (has_alpha) value = alpha_mean > 0.0 ? value * 255.0 / alpha_mean : 0.0;
    means[band] = value;
  }

  VALUE rgb = rb_ary_new_capa(3);
  for (int band = 0; band < 3; band++) {
    long rounded = lround(means[band]);
    if (rounded < 0) rounded = 0;
    if (rounded > 255) rounded = 255;
    rb_ary_push(rgb, LONG2NUM(rounded));
  }
  return rgb;
}

void Init_safe_image_native(void) {
  mSafeImage = rb_define_module("SafeImage");
  eError = rb_const_get(mSafeImage, rb_intern("Error"));
  eUnsupported = rb_const_get(mSafeImage, rb_intern("UnsupportedFormatError"));
  eInvalid = rb_const_get(mSafeImage, rb_intern("InvalidImageError"));
  eLimit = rb_const_get(mSafeImage, rb_intern("LimitError"));
  mNative = rb_define_module_under(mSafeImage, "Native");
  rb_define_singleton_method(mNative, "probe", rb_probe, 1);
  rb_define_singleton_method(mNative, "thumbnail", rb_thumbnail, 7);
  rb_define_singleton_method(mNative, "resize", rb_resize, 6);
  rb_define_singleton_method(mNative, "crop_north", rb_crop_north, 7);
  rb_define_singleton_method(mNative, "dominant_color", rb_dominant_color, 2);
  rb_define_singleton_method(mNative, "pages", rb_pages, 2);
  rb_define_singleton_method(mNative, "png_from_rgba", rb_png_from_rgba, 4);
  rb_define_singleton_method(mNative, "letter_avatar", rb_letter_avatar, 8);
  rb_define_singleton_method(mNative, "orientation", rb_orientation, 2);
}
