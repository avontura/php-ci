# CI image for Vontura Laravel projects.
#
# Derived from laravel/sail's runtimes/<version>/Dockerfile, so the toolchain a
# pipeline runs is the toolchain a developer runs. What is dropped is the part
# that makes Sail a dev server rather than a build environment: supervisor and
# start-container, the EXPOSE/ENTRYPOINT pair, the sail user and its setcap, and
# `playwright install-deps`, which only the playwright target carries. The default
# target stays thin; the ffmpeg and vips targets add the video and image tools a
# Pest step needs, the playwright target the libraries a downloaded Chromium
# needs. What is added to every target is xdebug installed but switched off, and
# what imagick needs to be the whole extension: the delegates below, and
# ghostscript.
#
# Needs BuildKit (ADD --checksum, RUN --mount): docker buildx, or Docker 23 and
# later, where it is the default builder.

# The default for a local build. The publish workflow builds every version in
# its php matrix by passing PHP_VERSION; a version needs a typst-<version> stage
# below before it can be added there.
ARG PHP_VERSION=8.5

# Typst, pnpm and Composer are pinned release files, each verified by BuildKit
# against the checksum declared next to its version: a bump changes both lines
# together. Dependabot tracks none of them. Declared before the first FROM,
# since the download stages below need them too; a stage only sees the ones it
# declares again.
ARG TYPST_VERSION=0.5.0
ARG PNPM_VERSION=12.22.0
ARG PNPM_SHA256=07ee196f91af1e21edb0c794401f4152932c74b0dba5d415dc4dbd5783f3c7af
ARG COMPOSER_VERSION=2.11.2
ARG COMPOSER_SHA256=dd158c0afd41d15fac89e1b4e47b5d42911fe316c3687cd5edac98319b25d028

# The archives are fetched in stages of their own and bind-mounted into the RUN
# that unpacks them, so no archive lands in a layer of the image. BuildKit also
# fetches them while the apt layer is still building.
#
# Typst publishes one archive per PHP version, so each version has a stage of
# its own with its own checksum, and typst-download picks the one for
# PHP_VERSION. BuildKit builds only the stage picked. A version without a stage
# fails here, as `typst-<version>` not found: Typst has to ship for a PHP
# version before this image can.
FROM scratch AS typst-8.5
ARG TYPST_VERSION
ADD --checksum=sha256:137e541d5751576c9cb9f7c72203dec316b7039533ca6b86dbaa9cd0759cea13 \
    https://github.com/carthage-software/ext-typst/releases/download/${TYPST_VERSION}/php_typst-${TYPST_VERSION}_php8.5-x86_64-linux-glibc.zip \
    /typst.zip

FROM scratch AS typst-8.6
ARG TYPST_VERSION
ADD --checksum=sha256:1cf2943bd370c1b6c640ccb59efbd6e9f68c48acc9b44ea5afe5ffa73780f5c6 \
    https://github.com/carthage-software/ext-typst/releases/download/${TYPST_VERSION}/php_typst-${TYPST_VERSION}_php8.6-x86_64-linux-glibc.zip \
    /typst.zip

FROM typst-${PHP_VERSION} AS typst-download

FROM scratch AS pnpm-download
ARG PNPM_VERSION
ARG PNPM_SHA256
ADD --checksum=sha256:${PNPM_SHA256} \
    https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-x64.tar.gz \
    /pnpm.tar.gz

FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS base

# Every RUN in every stage stops at its first failing command, including one on
# the left of a pipe: /bin/sh has no pipefail, so in `curl ... | gpg` a failed
# fetch would become an empty keyring and fail a step later, on NO_PUBKEY. -x
# puts each command in the build log. The stages built from base inherit it.
# checks/php-ci-check keeps its own #!/bin/sh: a `| grep -q` there is safe
# without pipefail, and would fail at random with it.
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# Only what the apt layer needs is declared here. Every RUN after an ARG sees it,
# so a version declared here would rebuild the apt layer on every bump; the
# pinned downloads declare theirs just above their own step instead.
ARG PHP_VERSION
ARG NODE_VERSION=24
# One retry and timeout policy for the two keys the apt layer fetches. Unquoted
# where it is used, so the shell splits it into separate flags. -f makes an HTTP
# error a curl error instead of a saved error page.
ARG CURL_OPTS="-fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120"

# Typst and pnpm are fetched as x86_64 binaries, and Bitbucket runs amd64 only.
# A plain `docker build .` on Apple Silicon builds arm64 and would otherwise fail
# much later, on an ELF error from typst.so or an exec format error from pnpm.
# dpkg answers for the image actually being built.
RUN arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != amd64 ]; then echo "this image is amd64 only, not $arch: build with --platform linux/amd64"; exit 1; fi

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
# Read by composer in every step; the image runs as root, and without it each
# composer call ends on a warning about plugins being disabled that is never the
# cause of the failure above it.
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV PNPM_HOME=/usr/local/pnpm
ENV PATH=$PNPM_HOME:$PNPM_HOME/bin:$PATH

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
# Both extra repositories are set up before a single shared index fetch, rather
# than one fetch each.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i '/^URIs:/ s|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get full-upgrade -y \
    && apt-get install -y --no-install-recommends \
        curl git gnupg unzip zip xz-utils \
        sqlite3 \
    && curl $CURL_OPTS -o /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/debsuryorg-archive-keyring.deb \
    && echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/php.list \
    && printf 'Package: php*\nPin: origin packages.sury.org\nPin-Priority: 1001\n' > /etc/apt/preferences.d/sury \
    && curl $CURL_OPTS https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_VERSION.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    # Without a pin, apt takes whichever nodejs has the higher version string,
    # and Ubuntu's own comes without npm and npx. NodeSource's setup script
    # writes the same preference.
    && printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/nodesource \
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
        libmagickcore-7.q16-10-extra \
        nodejs \
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
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    # Node ships its C++ headers for node-gyp, and there is no compiler here for
    # node-gyp to call - a project needing native modules needs build-essential
    # and python3-dev, which is a different image rather than a bigger one.
    && rm -rf /usr/include/node /usr/share/doc /usr/share/man /usr/share/info

# The upstream amd64 glibc/NTS binary for the distro PHP, without a Rust
# toolchain. The compile check proves the extension loads; the checksum already
# proves it is the pinned version.
RUN --mount=type=bind,from=typst-download,source=/typst.zip,target=/tmp/typst.zip \
    unzip -j /tmp/typst.zip '*.so' -d /tmp/typst; \
    install -m 644 /tmp/typst/typst.so "$(php -r 'echo ini_get("extension_dir");')/typst.so"; \
    printf 'extension=typst.so\n' > /etc/php/${PHP_VERSION}/mods-available/typst.ini; \
    phpenmod -v ${PHP_VERSION} -s ALL typst; \
    php -r 'exit(str_starts_with((new Typst\Compiler(new Typst\World()))->compileString("Hello from Typst")->toPdf()->bytes(), "%PDF-") ? 0 : 1);'; \
    rm -rf /tmp/typst

# pnpm's native binary, so pnpm does not depend on the Node install. The archive
# carries the executable and the dist/ tree it expects next to it; `pnpm pm
# setup` lays both out in PNPM_HOME, as get.pnpm.io's installer does, without
# the installer's shell-profile edits.
RUN --mount=type=bind,from=pnpm-download,source=/pnpm.tar.gz,target=/tmp/pnpm.tar.gz \
    mkdir /tmp/pnpm; \
    tar -xzf /tmp/pnpm.tar.gz -C /tmp/pnpm; \
    /tmp/pnpm/pnpm pm setup --force --no-modify-path; \
    rm -rf /tmp/pnpm

# composer.phar itself rather than the installer: the installer is unversioned
# code run as root, and installs whichever Composer is current on the day. The
# phar is the installed file, so it is added straight to its place.
ARG COMPOSER_VERSION
ARG COMPOSER_SHA256
ADD --chmod=755 --checksum=sha256:${COMPOSER_SHA256} \
    https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar \
    /usr/bin/composer

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
# Every stage ends on checks/php-ci-check, which holds the image's invariants
# in one place; the publish workflow runs the same script against the pushed
# digest. A check writes nothing, so it costs no image size, and it runs during
# the build, so a pull request that bumps the base image fails here rather than
# after the branch has published.
COPY checks/php-ci-check /usr/local/bin/php-ci-check
# The check compares pnpm against the pinned version.
ARG PNPM_VERSION

RUN phpdismod -v ${PHP_VERSION} -s ALL xdebug; \
    phpenmod -v ${PHP_VERSION} -s ALL pcov; \
    printf 'memory_limit = -1\nzend.assertions = 1\n' > /etc/php/${PHP_VERSION}/cli/conf.d/99-ci.ini; \
    php-ci-check base

# Bitbucket clones into the working directory as root; without this, git refuses
# to read a repository it does not consider its own. --system rather than
# --global: /root/.gitconfig is only read while HOME=/root, and a step or runner
# that sets another HOME would lose it.
RUN git config --system --add safe.directory '*'

WORKDIR /app

# Pest's video conversions need both binaries; Ubuntu's ffmpeg package supplies
# them together. The check encodes an H.264 video and extracts a thumbnail.
FROM base AS ffmpeg

RUN apt-get update; \
    apt-get install -y --no-install-recommends ffmpeg; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    php-ci-check ffmpeg

# Pest's image processing runs libvips in-process through FFI, inspects uploads
# with vipsheader and jxlinfo, and reads and writes AVIF, HEIC and JPEG XL with
# the reference tools. libheif needs a plugin per codec: libde265 and dav1d
# decode HEIC and AVIF, x265 lets a suite write the HEIC it reads. The check
# proves FFI reaches libvips from the CLI and round-trips each format.
FROM base AS vips

RUN apt-get update; \
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
    php-ci-check vips

# The vips variant plus hunspell with OpenTaal's Dutch dictionary, for a Pest
# step that both processes images and stems Dutch words (`hunspell -d nl_NL
# -s`). On top of vips rather than beside it, so one step has both. The check
# runs the vips checks and stems a Dutch plural.
FROM vips AS vips-hunspell

RUN apt-get update; \
    apt-get install -y --no-install-recommends hunspell hunspell-nl; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    php-ci-check vips-hunspell

# Pest's browser tests drive Chromium through Playwright. The image carries only
# the OS libraries Chromium links against, not a browser: the pipeline step runs
# `pnpm exec playwright install chromium` (no --with-deps), so the browser always
# matches the project's own Playwright version instead of whichever one was
# current when this image was built. install-deps is Playwright's own list for
# this Ubuntu, which is why it is used rather than a hand-kept package list that
# drifts; it installs with --no-install-recommends. npx leaves its cache behind,
# and nothing in it is needed afterwards.
FROM base AS playwright

# Only selects the dependency list install-deps installs; the browser a pipeline
# downloads comes from the project's own Playwright, not from this version.
ARG PLAYWRIGHT_VERSION=1.65.1

RUN npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium; \
    apt-get -y autoremove; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /root/.npm /tmp/* /var/tmp/*; \
    php-ci-check playwright

# The last stage is the default for a plain `docker build`; it must stay thin,
# which `php-ci-check base` already guarantees.
FROM base AS thin
