# CI image for Vontura Laravel projects.
#
# Derived from laravel/sail's runtimes/<version>/Dockerfile, so the toolchain a
# pipeline runs is the toolchain a developer runs. What is dropped is the part
# that makes Sail a dev server rather than a build environment: supervisor and
# start-container, the EXPOSE/ENTRYPOINT pair, the sail user and its setcap, and
# `playwright install-deps`. The default target stays thin; the ffmpeg and vips
# targets add the video and image tools a Pest step needs. What is added to both is xdebug
# installed but switched off, and what imagick needs to be the whole extension:
# the delegates below, and ghostscript.
FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7 AS base

ARG PHP_VERSION=8.5
ARG TYPST_VERSION=0.2.0
ARG NODE_VERSION=24
ARG PNPM_VERSION=next-12
ARG PNPM_MAJOR=12

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
# Read by composer in every step; the image runs as root, and without it each
# composer call ends on a warning about plugins being disabled that is never the
# cause of the failure above it.
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV PNPM_HOME=/usr/local/pnpm
ENV PATH=$PNPM_HOME:$PNPM_HOME/bin:$PATH

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# A failed index fetch is a warning to apt, so an unreachable mirror does not
# stop the build - it lets it run on until `apt-get install` reports the package
# as missing, several stages away from the cause. Error-Mode any turns that back
# into a failure at the fetch, and the retries absorb the flakiness that is
# merely transient.
RUN printf 'Acquire::Retries "3";\nAPT::Update::Error-Mode "any";\n' \
        > /etc/apt/apt.conf.d/99-vontura-strict

# Bootstrap CA trust from the signed http metadata, then take the same archives
# over HTTPS. Ubuntu's own hosts, not a third-party mirror: mirrors.edge.kernel.org
# timed out from the GitHub runners and took the ffmpeg variant down with it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i '/^URIs:/ s|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get full-upgrade -y \
    && mkdir -p /etc/apt/keyrings \
    && apt-get install -y --no-install-recommends \
        curl git gnupg unzip zip xz-utils \
        libcap2-bin \
        sqlite3 \
    && curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/debsuryorg-archive-keyring.deb \
    && echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/php.list \
    && printf 'Package: php*\nPin: origin packages.sury.org\nPin-Priority: 1001\n' > /etc/apt/preferences.d/sury \
    && apt-get update \
    # Two packages imagick needs and does not pull. libmagickcore-...-extra
    # carries the delegates it leaves out: without them ImageMagick has no SVG
    # at all - queryFormats() answers without SVG, MSVG and SVGZ - and a
    # conversion fails on `unable to open file /tmp/magick-...`, which reads
    # like a missing temp file and is a missing renderer. ghostscript is the
    # PDF delegate, and its absence hides better still, since queryFormats()
    # keeps answering PDF - the format is registered *via* gs - and the failure
    # arrives only when something reads one.
    #
    # Both are in the shared base, unlike ffmpeg, because imagick is here: an
    # extension that cannot read half the formats it advertises is this image's
    # gap, not a project's. The ImageMagick soname is in one package name, so a
    # base bump that moves it fails this build rather than a project's.
    && apt-get install -y --no-install-recommends \
        ghostscript \
        libgd3 \
        libmagickcore-7.q16-10-extra \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-igbinary \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-ldap \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-msgpack \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pcov \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-soap \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-xdebug \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
    && curl -sLS https://getcomposer.org/installer | php -- --install-dir=/usr/bin/ --filename=composer \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_VERSION.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=${PNPM_VERSION} ENV="$HOME/.bashrc" SHELL="$(which bash)" bash - \
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    # Node ships its C++ headers for node-gyp, and there is no compiler here for
    # node-gyp to call - a project needing native modules needs build-essential
    # and python3-dev, which is a different image rather than a bigger one.
    && rm -rf /usr/include/node /usr/share/doc /usr/share/man /usr/share/info

# Use the upstream amd64 glibc/NTS binary for the distro PHP, without a Rust toolchain.
# Checksum is for Typst 0.2.0 / PHP 8.5; update it with either version.
RUN set -eux; \
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 "https://github.com/carthage-software/ext-typst/releases/download/${TYPST_VERSION}/php_typst-${TYPST_VERSION}_php${PHP_VERSION}-x86_64-linux-glibc.zip" -o /tmp/typst.zip; \
    printf '%s  /tmp/typst.zip\n' 926df3d4ba0cc8e5176d956e1fb8433efe2972ed62d12278758f6a44a94b0952 | sha256sum -c -; \
    unzip -j /tmp/typst.zip '*.so' -d /tmp/typst; \
    install -m 644 /tmp/typst/typst.so "$(php -r 'echo ini_get("extension_dir");')/typst.so"; \
    printf 'extension=typst.so\n' > /etc/php/${PHP_VERSION}/mods-available/typst.ini; \
    phpenmod -v ${PHP_VERSION} -s ALL typst; \
    test "$(php -r 'echo phpversion("typst");')" = "${TYPST_VERSION}"; \
    php -r 'exit(str_starts_with((new Typst\Compiler(new Typst\World()))->compileString("Hello from Typst")->toPdf()->bytes(), "%PDF-") ? 0 : 1);'; \
    rm -rf /tmp/typst.zip /tmp/typst

# zend.assertions stays on. The distro ships php.ini-production, which sets it to
# -1: assert() is then not compiled at all, so the call never runs and the line
# never counts as covered - a suite pinned at 100% fails on a line the developer
# who wrote it sees executed, since a development ini leaves assertions on. On is
# also what makes an assert() a check rather than a comment.
#
# pcov stays on: it is the coverage driver, and it costs nothing until a run asks
# for coverage. Xdebug is installed and switched off, so a step that wants a
# debugger enables it deliberately and no other step pays for it - a loaded
# Xdebug is what turned the type-coverage step into 273s and a corrupted heap.
#
# The checks that follow run in the same layer as the switch they verify, and
# they write nothing, so the whole step costs no image size at all. They run
# during the build, so a pull request that bumps the base image fails here
# rather than after the branch has published. `! cmd` would not do: set -e is
# ignored for an inverted command, so a negative assertion has to be a branch
# that exits.
RUN set -eux; \
    phpdismod -v ${PHP_VERSION} -s ALL xdebug; \
    phpenmod -v ${PHP_VERSION} -s ALL pcov; \
    printf 'memory_limit = -1\nzend.assertions = 1\n' > /etc/php/${PHP_VERSION}/cli/conf.d/99-ci.ini; \
    php -m | grep -qx pcov; \
    if php -m | grep -qx xdebug; then echo "xdebug must not be loaded"; exit 1; fi; \
    php -r 'exit(array_diff(["SVG", "MSVG", "SVGZ"], Imagick::queryFormats()) === [] ? 0 : 1);'; \
    test "$(php -r 'echo ini_get("zend.assertions");')" = "1"; \
    test "$(pnpm -v | cut -d. -f1)" = "${PNPM_MAJOR}"; \
    for b in git composer node gs; do command -v "$b" >/dev/null; done

# Bitbucket clones into the working directory as root; without this, git refuses
# to read a repository it does not consider its own.
RUN git config --global --add safe.directory '*'

WORKDIR /app

# Pest's video conversions need both binaries; Ubuntu's ffmpeg package supplies
# them together. Keep package lists and smoke-test artifacts out of the layer.
FROM base AS ffmpeg

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ffmpeg; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    smoke_dir="$(mktemp -d)"; \
    trap 'rm -rf "$smoke_dir"' EXIT; \
    ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=160x90:r=1 \
        -t 1 -c:v libx264 -pix_fmt yuv420p "$smoke_dir/video.mp4"; \
    test "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height \
        -of csv=p=0 "$smoke_dir/video.mp4")" = "h264,160,90"; \
    ffmpeg -hide_banner -loglevel error -i "$smoke_dir/video.mp4" \
        -frames:v 1 -threads 1 "$smoke_dir/thumbnail.png"; \
    test "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height \
        -of csv=p=0 "$smoke_dir/thumbnail.png")" = "png,160,90"

# Pest's image processing runs libvips in-process through FFI, inspects uploads
# with vipsheader and jxlinfo, and reads and writes AVIF, HEIC and JPEG XL with
# the reference tools. libheif needs a plugin per codec: libde265 and dav1d
# decode HEIC and AVIF, x265 lets a suite write the HEIC it reads. The checks
# prove FFI reaches libvips from the CLI (ffi.enable defaults to preload), and
# that vipsheader still refuses JPEG XL with its untrusted loaders blocked.
FROM base AS vips

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libvips42t64 \
        libvips-tools \
        libjxl-tools \
        libavif-bin \
        libheif-plugin-libde265 \
        libheif-plugin-dav1d \
        libheif-plugin-x265; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    php -m | grep -qx FFI; \
    php -r '$vips = FFI::cdef("int vips_init(const char *argv0); const char *vips_version_string(void);", "libvips.so.42"); exit($vips->vips_init("php") === 0 && str_starts_with($vips->vips_version_string(), "8.") ? 0 : 1);'; \
    smoke_dir="$(mktemp -d)"; \
    trap 'rm -rf "$smoke_dir"' EXIT; \
    vips black "$smoke_dir/image.png" 160 90 --bands 3; \
    cjxl "$smoke_dir/image.png" "$smoke_dir/image.jxl" -p; \
    jxlinfo "$smoke_dir/image.jxl" | grep -q 'JPEG XL image, 160x90'; \
    djxl "$smoke_dir/image.jxl" "$smoke_dir/jxl.png"; \
    if VIPS_BLOCK_UNTRUSTED=1 vipsheader "$smoke_dir/image.jxl"; then echo "vipsheader must refuse JPEG XL with untrusted loaders blocked"; exit 1; fi; \
    avifenc --progressive "$smoke_dir/image.png" "$smoke_dir/image.avif"; \
    test "$(VIPS_BLOCK_UNTRUSTED=1 vipsheader -f heif-compression "$smoke_dir/image.avif")" = "av1"; \
    vips copy "$smoke_dir/image.avif" "$smoke_dir/avif.png"; \
    vips heifsave "$smoke_dir/image.png" "$smoke_dir/image.heic" --compression hevc; \
    test "$(VIPS_BLOCK_UNTRUSTED=1 vipsheader -f heif-compression "$smoke_dir/image.heic")" = "hevc"; \
    vips copy "$smoke_dir/image.heic" "$smoke_dir/heic.png"

# The last stage is the default for a plain `docker build`; it must stay thin.
FROM base AS thin

RUN set -eux; \
    for binary in ffmpeg ffprobe vips vipsheader cjxl djxl jxlinfo avifenc; do \
        if command -v "$binary"; then echo "$binary must not be installed in the thin image"; exit 1; fi; \
    done
