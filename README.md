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

Added: `git config --system --add safe.directory '*'`, since Bitbucket clones
as root, and the two packages imagick needs and does not pull —
`libmagickcore-7.q16-10-extra` and `ghostscript`, covered below. The
ImageMagick soname is in the first package's name, so a base bump that moves it
fails this build rather than a project's.

The shared Dockerfile publishes five variants:

| Tag | Build target | Use |
|---|---|---|
| `8.5` | `thin` (default) | Global pipeline image: dependency installation, formatting, static analysis, type coverage and frontend builds |
| `8.5-ffmpeg` | `ffmpeg` | Pest steps only; adds Ubuntu's `ffmpeg` package, including `ffprobe`, with `--no-install-recommends` |
| `8.5-vips` | `vips` | Pest steps only; adds libvips for FFI (`jcupitt/vips`) with `libvips-tools`, `libjxl-tools`, `libavif-bin` and the libheif plugins that read HEIC and AVIF and write HEIC |
| `8.5-vips-hunspell` | `vips-hunspell` | Pest steps only; `8.5-vips` plus `hunspell` and OpenTaal's Dutch dictionary (`hunspell-nl`, `-d nl_NL`), for a project that also asks Hunspell for the base forms of Dutch words |
| `8.5-playwright` | `playwright` | Browser-test step only; carries Chromium's OS libraries, the step downloads the browser with `pnpm exec playwright install chromium` |

Keep the global image thin and override the image on the Pest step:

    - step:
        name: Pest
        image:
          name: ghcr.io/avontura/php-ci:8.5-ffmpeg
        script:
          - composer run test:pest

`8.5-vips` is overridden the same way, for a project that processes images
with libvips, and `8.5-vips-hunspell` for one that also stems Dutch words with
Hunspell. These are the explicit Pest-only exceptions to using one global
pipeline image. Do not install FFmpeg, libvips or its tools at runtime in
consumer pipelines. FFI itself is in the base: PHP's default
`ffi.enable=preload` allows it on the CLI, so `composer install` of
`jcupitt/vips` passes on the thin image. Roll out the override
only after the variant has been published, passed its published-digest smoke
test and been signed; other steps retain `:8.5`. No variant adds a database
client.

`8.5-playwright` is for the browser-test step (`pestphp/pest-plugin-browser`,
which drives Playwright). It carries only the OS libraries Chromium links
against, installed with `playwright install-deps chromium` for the Playwright
version pinned in the Dockerfile, and no browser. The step downloads Chromium
itself, so the browser always matches the project's own Playwright version, and
caches the download keyed on the lockfile:

    - step:
        name: Browser tests
        image:
          name: ghcr.io/avontura/php-ci:8.5-playwright
        caches:
          - pnpm
          - playwright
        script:
          - pnpm install --frozen-lockfile --store-dir=/tmp/pnpm-store
          - pnpm exec playwright install chromium
          - composer run test:pest -- --ci --testsuite=Browser

Key the cache on `pnpm-lock.yaml`, so a Playwright bump fetches the new browser
and an unchanged lockfile reuses the old one:

    playwright:
      key:
        files:
          - pnpm-lock.yaml
      path: ~/.cache/ms-playwright

Do not pass `--with-deps`: the libraries are already in the image, and the
install would need root and apt at runtime.

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
| PHP | 8.5.x from `packages.sury.org`, pinned above the distro's own; one image per version in the workflow's `php` matrix |
| Coverage | **pcov enabled, xdebug installed but disabled** |
| Assertions | `zend.assertions = 1`, as on a development machine — the distro's production ini compiles `assert()` out, which leaves the line uncovered |
| Node | 24, with pnpm pinned to an exact 12.x (`PNPM_VERSION`) from its GitHub release — a native binary, so pnpm does not depend on the Node install. Dependabot does not track it: bump `PNPM_VERSION` and `PNPM_SHA256` together |
| Composer | Pinned to an exact 2.x (`COMPOSER_VERSION`), checksum-verified. Like pnpm, Dependabot does not track it: bump `COMPOSER_VERSION` and `COMPOSER_SHA256` together |
| Also | git, imagick with its SVG and PDF delegates, and the usual PHP extensions |
| User | root, `COMPOSER_ALLOW_SUPERUSER=1` baked in |

## Why xdebug is off

A loaded Xdebug is pure overhead on four of the five checks and a hazard on the
fifth: the type-coverage plugin forks with pokio, whose fork guard takes every
`xdebug.mode` but `debug` for fork-safe. With Xdebug loaded that step took 273s
and died with `zend_mm_heap corrupted`; with it off, 18s.

So no step has to remember `XDEBUG_MODE=off` — nothing loads it. A step that
wants a debugger turns it on deliberately:

    - phpenmod -v 8.5 xdebug && XDEBUG_MODE=debug ...

## One branch, every PHP version

`main` builds every published PHP version from the same Dockerfile. The `php`
matrix in `.github/workflows/docker-publish.yml` is the list of versions; each
build passes its entry as `PHP_VERSION`, and its tags are named after the entry,
so `8.5` publishes `:8.5`, `:8.5-ffmpeg`, `:8.5-vips`, `:8.5-vips-hunspell` and `:8.5-playwright`. A
fix applies to every version at once, with nothing to cherry-pick.

Per PHP version, a prerequisite job builds the shared `base` once, then a matrix
builds `thin`, `ffmpeg`, `vips`, `vips-hunspell` and `playwright` independently. Each variant has its own
smoke test, publication and signing, and `php-ci-check` fails a build whose PHP
is not the version its tags name.

To add a version, for example 8.6:

1. Check that Sury ships every `php8.6-*` package the Dockerfile installs: the
   PECL extensions (pcov, xdebug, imagick, redis, igbinary, msgpack) usually
   follow a PHP release by a few weeks.
2. Check that ext-typst publishes a `php8.6-x86_64-linux-glibc` archive, and add
   a `typst-8.6` stage with its checksum next to `typst-8.5` in the Dockerfile.
3. Add `"8.6"` to both `php` matrices in the workflow (the `base` and `build`
   jobs).

Typst and every PHP extension are installed in `base`, which all five variants
build on, so a version ships all five or none: until its extensions and Typst
exist, there is no `8.6` and no `8.6-ffmpeg` either. Waiting is deliberate. A
version published with fewer extensions would let `:8.6` quietly mean less than
`:8.5`: without pcov there is no coverage and a coverage gate fails, and a
project using imagick or redis breaks at runtime rather than at build time.
Nothing has to remember this: a missing `php8.6-*` package fails the base build
at `apt-get install`, and a missing Typst archive fails it at `typst-8.6`.

Dropping a version is the reverse; its tags stay in the registry, unrefreshed.

## Tags

| Thin | FFmpeg | libvips | libvips + Hunspell | Playwright | Meaning |
|---|---|---|---|---|---|
| `8.5` | `8.5-ffmpeg` | `8.5-vips` | `8.5-vips-hunspell` | `8.5-playwright` | Moving PHP version tags, refreshed on pushes and nightly schedules |
| `8.5-sha-<full sha>` | `8.5-sha-<full sha>-ffmpeg` | `8.5-sha-<full sha>-vips` | `8.5-sha-<full sha>-vips-hunspell` | `8.5-sha-<full sha>-playwright` | Source revision tags published on pushes |
| `8.5-YYYYMMDD` | `8.5-YYYYMMDD-ffmpeg` | `8.5-YYYYMMDD-vips` | `8.5-YYYYMMDD-vips-hunspell` | `8.5-YYYYMMDD-playwright` | Nightly builds, dated in UTC |

Every tag starts with its PHP version, so versions built from one commit or on
one night never share a tag. Revision and nightly tags published before the
version matrix have no PHP prefix (`sha-<full sha>`, `YYYYMMDD`); they are 8.5
builds and stay in the registry.

Pull requests build all five targets for every version without publishing;
their metadata uses `8.5-pr-<number>`, `8.5-pr-<number>-ffmpeg` and so on. Base
and variant cache scopes are separate per PHP version.

The prerequisite exports the base as an OCI image-layout artifact, named after
its PHP version and run. Each matrix job downloads the artifact for its version
and supplies its manifest digest as a
named `base` build context, replacing the Dockerfile's base stage rather than
rebuilding it. This also works on fork pull requests without registry write
access. The artifact expires after one day; only the final variants are published.
A run that succeeds deletes it at once; a failed run keeps it, so "Re-run failed
jobs" rebuilds only the failed variants, from the same base, within that day.
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

The image's invariants live in one script, [`checks/php-ci-check`](checks/php-ci-check),
installed in the image as `php-ci-check`. Every stage of the build ends on it, and
the publish workflow runs it again against the pushed digest. It checks the
shared PHP, Typst, coverage-driver, assertions, ImageMagick and toolchain
invariants, that the thin image has no video or image tools, that the FFmpeg
variant can encode an H.264 video and extract a PNG thumbnail, and that the vips
variant reaches libvips through FFI and round-trips JPEG XL, AVIF and HEIC, and
that the vips-hunspell variant does all that and stems a Dutch plural. Only
that variant may carry hunspell.
Temporary media is removed. Only the Playwright variant's browser check stays in
the workflow: it downloads Chromium the way a pipeline does, checks it for
unresolved libraries and launches it headless.

Every successfully smoke-tested published digest is signed with
[cosign](https://github.com/sigstore/cosign):

    cosign verify ghcr.io/avontura/php-ci:8.5 \
      --certificate-identity-regexp '^https://github.com/avontura/php-ci/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com

## Building locally

The Dockerfile needs BuildKit (`ADD --checksum`, `RUN --mount`), which is the
default builder from Docker 23 and in OrbStack. It builds PHP 8.5 by default;
another version from the matrix takes `--build-arg PHP_VERSION=<version>`.

    docker build --platform linux/amd64 -t php-ci:8.5 .
    docker build --platform linux/amd64 --target thin -t php-ci:8.5 .
    docker build --platform linux/amd64 --target ffmpeg -t php-ci:8.5-ffmpeg .
    docker build --platform linux/amd64 --target vips -t php-ci:8.5-vips .
    docker build --platform linux/amd64 --target vips-hunspell -t php-ci:8.5-vips-hunspell .
    docker build --platform linux/amd64 --target playwright -t php-ci:8.5-playwright .

The first two commands produce the same thin image. Every final target inherits
the shared `base` stage; a default build installs neither FFmpeg, libvips nor Chromium's libraries.

`--platform linux/amd64` matters on Apple Silicon: Bitbucket runs amd64, and the
image is published for that architecture alone. The pinned Typst binary is
amd64 too, so an arm64 build is not an equivalent check. On a Mac using Rosetta
for amd64, unpacking pnpm can fail with `tar: Cannot open: Function not
implemented` — an emulation limit, not the recipe. Use
`orb config set rosetta false` to build the published architecture.
