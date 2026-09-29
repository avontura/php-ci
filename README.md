# avontura/php-ci

The build environment Bitbucket Pipelines runs the suite in — PHP, Node and the
binaries the gate shells out to, in one image.

    image:
      name: ghcr.io/avontura/php-ci:8.5

## What it is

Derived from [`laravel/sail`](https://github.com/laravel/sail)'s
`runtimes/8.5/Dockerfile`, so the toolchain a pipeline runs is the toolchain a
developer runs. Dropped from it: supervisor and `start-container`, the
`EXPOSE`/`ENTRYPOINT` pair, the `sail` user and its `setcap`, and
`playwright install-deps` — the parts that make Sail a dev server rather than a
build environment. Bitbucket overrides `ENTRYPOINT` anyway, so an image that
configures itself there configures nothing.

Added: `git config --global --add safe.directory '*'`, since Bitbucket clones
as root, and the two packages imagick needs and does not pull —
`libmagickcore-7.q16-10-extra` and `ghostscript`, covered below. The
ImageMagick soname is in the first package's name, so a base bump that moves it
fails this build rather than a project's.

The shared Dockerfile publishes three variants:

| Tag | Build target | Use |
|---|---|---|
| `8.5` | `thin` (default) | Global pipeline image: dependency installation, formatting, static analysis, type coverage and frontend builds |
| `8.5-ffmpeg` | `ffmpeg` | Pest steps only; adds Ubuntu's `ffmpeg` package, including `ffprobe`, with `--no-install-recommends` |
| `8.5-vips` | `vips` | Pest steps only; adds libvips for FFI (`jcupitt/vips`) with `libvips-tools`, `libjxl-tools`, `libavif-bin` and the libheif plugins that read HEIC and AVIF and write HEIC |

Keep the global image thin and override the image on the Pest step:

    - step:
        name: Pest
        image:
          name: ghcr.io/avontura/php-ci:8.5-ffmpeg
        script:
          - composer run test:pest

`8.5-vips` is overridden the same way, for a project that processes images
with libvips. These are the explicit Pest-only exceptions to using one global
pipeline image. Do not install FFmpeg, libvips or its tools at runtime in
consumer pipelines. FFI itself is in the base: PHP's default
`ffi.enable=preload` allows it on the CLI, so `composer install` of
`jcupitt/vips` passes on the thin image. Roll out the override
only after the variant has been published, passed its published-digest smoke
test and been signed; other steps retain `:8.5`. Neither variant adds a database
client.

The larger FFmpeg and libvips dependency trees belong only in the variants that
need them.
What that separation does *not* reach is a format imagick cannot read. The
extension is in the shared base, so the delegates are too —
`libmagickcore-…-extra` for SVG, ghostscript for PDF — because an extension that
cannot read half the formats it advertises is this image's gap rather than a
project's.

Both failures are worth recognising, because neither looks like a missing
dependency. Without the delegates, `Imagick::queryFormats()` answers without
`SVG`, `MSVG` and `SVGZ`, and `readImage()` fails on a temp file it never
wrote:

    unable to open file '/tmp/magick-…': No such file or directory

Ghostscript hides better still: `queryFormats('PDF')` returns a match either
way — the format stays registered, since it is registered *via* the gs
delegate — and the failure arrives only when something reads a PDF:

    FailedToExecuteCommand `'gs' -sstdout=%stderr -dQUIET -dSAFER ...`

| | |
|---|---|
| Base | Ubuntu 26.04 LTS (resolute) |
| PHP | 8.5.x from `packages.sury.org`, pinned above the distro's own |
| Coverage | **pcov enabled, xdebug installed but disabled** |
| Assertions | `zend.assertions = 1`, as on a development machine — the distro's production ini compiles `assert()` out, which leaves the line uncovered |
| Node | 24, with pnpm 12 from its own standalone installer — a native binary, so pnpm does not depend on the Node install |
| Also | composer, git, imagick with its SVG and PDF delegates, and the usual PHP extensions |
| User | root, `COMPOSER_ALLOW_SUPERUSER=1` baked in |

## Why xdebug is off

A loaded Xdebug is pure overhead on four of the five checks and a hazard on the
fifth: the type-coverage plugin forks with pokio, whose fork guard takes every
`xdebug.mode` but `debug` for fork-safe. With Xdebug loaded that step took 273s
and died with `zend_mm_heap corrupted`; with it off, 18s.

So no step has to remember `XDEBUG_MODE=off` — nothing loads it. A step that
wants a debugger turns it on deliberately:

    - phpenmod -v 8.5 xdebug && XDEBUG_MODE=debug ...

## One branch per PHP version

The branch **is** the version: `8.5` builds and publishes `:8.5`, `:8.5-ffmpeg`
and `:8.5-vips`, and a future `8.4` branch would publish the corresponding tags
from the same file with its `ARG PHP_VERSION` changed. A fix that applies to
both PHP versions is a cherry-pick. A prerequisite job builds the shared `base`
once, then a matrix builds `thin`, `ffmpeg` and `vips` independently. Each
variant has its own smoke test, publication and signing.

## Tags

| Thin | FFmpeg | libvips | Meaning |
|---|---|---|---|
| `8.5` | `8.5-ffmpeg` | `8.5-vips` | Moving PHP branch tags, refreshed on pushes and nightly schedules |
| `sha-<full sha>` | `sha-<full sha>-ffmpeg` | `sha-<full sha>-vips` | Source revision tags published on pushes |
| `YYYYMMDD` | `YYYYMMDD-ffmpeg` | `YYYYMMDD-vips` | Nightly builds, dated in UTC |

Pull requests build all three targets without publishing; their metadata uses
`pr-<number>`, `pr-<number>-ffmpeg` and `pr-<number>-vips`. Variant cache
scopes are separate.

The prerequisite exports the base as an OCI image-layout artifact. Each matrix
job downloads that exact artifact by ID and supplies its manifest digest as a
named `base` build context, replacing the Dockerfile's base stage rather than
rebuilding it. This also works on fork pull requests without registry write
access. The artifact expires after one day; only the final variants are published.
For strictly reproducible pulls, pin a digest: rebuilding the same source
revision can resolve newer apt packages, so a SHA tag is not an immutable
package snapshot.

All variants rebuild nightly: the prerequisite bypasses cache and pulls the
base once, while the matrix jobs refresh only their selected variant stage.
Ordinary base builds retain the original `buildkit` cache scope; matrix caches
are separate. Sharing an exact base avoids relying on cache hits for correctness
and avoids installing the shared toolchain more than once.
Dependabot raises the base-image and action bumps that change a file; apt-level
patches change no source file.

Build-time checks and published-digest smoke tests preserve the shared PHP,
Typst, coverage-driver, assertions, ImageMagick and toolchain invariants. They
also check that the thin image has neither video binary and that the FFmpeg
variant can generate an H.264 video, probe its codec and dimensions, extract a
PNG thumbnail and probe that thumbnail. Temporary media is removed.

Every successfully smoke-tested published digest is signed with
[cosign](https://github.com/sigstore/cosign):

    cosign verify ghcr.io/avontura/php-ci:8.5 \
      --certificate-identity-regexp '^https://github.com/avontura/php-ci/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com

## Building locally

    docker build --platform linux/amd64 -t php-ci:8.5 .
    docker build --platform linux/amd64 --target thin -t php-ci:8.5 .
    docker build --platform linux/amd64 --target ffmpeg -t php-ci:8.5-ffmpeg .
    docker build --platform linux/amd64 --target vips -t php-ci:8.5-vips .

The first two commands produce the same thin image. Every final target inherits
the shared `base` stage; a default build installs neither FFmpeg nor libvips.

`--platform linux/amd64` matters on Apple Silicon: Bitbucket runs amd64, and the
image is published for that architecture alone. The pinned Typst binary is
amd64 too, so an arm64 build is not an equivalent check. On a Mac using Rosetta
for amd64, the pnpm installer can fail with `tar: Cannot open: Function not
implemented` — an emulation limit, not the recipe. Use
`orb config set rosetta false` to build the published architecture.
