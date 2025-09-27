#!/usr/bin/env bash
#
# Copyright (c) 2025, Oracle and/or its affiliates. All rights reserved.
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 only, as
# published by the Free Software Foundation.
#
# This code is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details (a copy is included in the LICENSE file that
# accompanied this code).
#
# You should have received a copy of the GNU General Public License version
# 2 along with this work; if not, write to the Free Software Foundation,
# Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
# or visit www.oracle.com if you need additional information or have any
# questions.
#
# ---------------------------------------------------------------------------
# build-complete-jdk.sh
# ---------------------------------------------------------------------------
# Convenience wrapper to produce a fully built JDK image (equivalent to
# running:  bash configure && make images ) while adding a few niceties:
# * Idempotent: only re-runs configure if build configuration missing or args change
# * Simple switches for release vs debug builds
# * Optional cleaning and incremental rebuild control
# * Pass-through of extra configure flags
# * Captures build log with timestamp
# * Prints resulting image path and java -version output
#
# This script intentionally keeps logic lightweight so that authoritative
# build functionality stays in the upstream make/autoconf system. For details
# see doc/building.md.
#
# USAGE:
#   bin/build-complete-jdk.sh [options] [-- [extra configure flags]]
#
# OPTIONS:
#   -h|--help              Show this help
#   -r|--release           Build a release (default)
#   -d|--debug             Build a fastdebug configuration
#   --variant <name>       Explicit build variant (release, fastdebug, slowdebug) overrides -r/-d
#   -j|--jobs <n>          Parallel make jobs (default: detected cores)
#   -c|--clean             Run 'make clean' before building
#   --dist-clean           Remove entire build/<conf> directory before starting
#   --configure-only       Only run configure step then exit
#   --boot-jdk <path>      Path to Boot JDK (passed as --with-boot-jdk)
#   --image-type <type>    Specific image target (default: images) e.g. jdk-image, test-image
#   --no-images            Stop after compiling (runs 'make all' instead of 'make images')
#   --conf-name <name>     Custom build configuration directory name (default derived from variant)
#   --log-dir <dir>        Directory to store build logs (default: build/logs)
#   --                           Separator; rest of args passed to 'bash configure'
#
# EXAMPLES:
#   bin/build-complete-jdk.sh                               # release images
#   bin/build-complete-jdk.sh -d                            # fastdebug images
#   bin/build-complete-jdk.sh --variant slowdebug           # slowdebug
#   bin/build-complete-jdk.sh -r --boot-jdk $HOME/jdk21     # custom boot jdk
#   bin/build-complete-jdk.sh -r -- -with-vendor-name="Acme" # extra configure flags
#   bin/build-complete-jdk.sh --no-images                   # stop after full compile
#
# EXIT CODES:
#   0 success, >0 failure at some stage
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${TOP_DIR}"

COLOR_TTY=0
if [ -t 1 ]; then COLOR_TTY=1; fi
c_green() { if [ $COLOR_TTY -eq 1 ]; then printf '\033[32m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }
c_red()   { if [ $COLOR_TTY -eq 1 ]; then printf '\033[31m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }
info()    { printf '[INFO] %s\n' "$*"; }
err()     { printf '[ERROR] %s\n' "$*" >&2; }

show_help() { awk '/^# USAGE:/,/^# EXIT CODES:/{ sub(/^# /, ""); print }' "$0"; }

variant="release" # release|fastdebug|slowdebug
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
clean_first=0
dist_clean=0
configure_only=0
boot_jdk=""
image_target="images"
run_images=1
conf_name=""
log_dir="build/logs"
extra_configure=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -r|--release) variant="release" ;;
    -d|--debug) variant="fastdebug" ;;
    --variant) shift; variant="${1:-}" || true ;;
    -j|--jobs) shift; jobs="${1:-}" ;;
    -c|--clean) clean_first=1 ;;
    --dist-clean) dist_clean=1 ;;
    --configure-only) configure_only=1 ;;
    --boot-jdk) shift; boot_jdk="${1:-}" ;;
    --image-type) shift; image_target="${1:-}" ;;
    --no-images) run_images=0 ;;
    --conf-name) shift; conf_name="${1:-}" ;;
    --log-dir) shift; log_dir="${1:-}" ;;
    --) shift; extra_configure=("${@}"); break ;;
    *) err "Unknown option: $1"; show_help; exit 2 ;;
  esac
  shift || true
done

if [ -z "${conf_name}" ]; then
  case "$variant" in
    release) conf_name="release" ;;
    fastdebug) conf_name="fastdebug" ;;
    slowdebug) conf_name="slowdebug" ;;
    *) conf_name="$variant" ;;
  esac
fi

BUILD_DIR="${TOP_DIR}/build/${conf_name}"
CONF_MARKER="${BUILD_DIR}/configure-support/config.status"

if [ $dist_clean -eq 1 ] && [ -d "${BUILD_DIR}" ]; then
  info "Removing existing build directory ${BUILD_DIR}"
  rm -rf "${BUILD_DIR}"
fi

mkdir -p "${log_dir}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${log_dir}/build-${conf_name}-${STAMP}.log"

configure_needed=0
if [ ! -f "${CONF_MARKER}" ]; then
  configure_needed=1
else
  # Try to detect changed configure args by comparing last configure invocation
  if [ -f "${BUILD_DIR}/config.summary" ] && ! grep -q "--with-conf-name=${conf_name}" "${BUILD_DIR}/config.summary" 2>/dev/null; then
    configure_needed=1
  fi
fi

CONFIGURE_CMD=(bash configure --with-conf-name="${conf_name}" --enable-${variant})
if [ -n "${boot_jdk}" ]; then CONFIGURE_CMD+=(--with-boot-jdk="${boot_jdk}"); fi
if [ ${#extra_configure[@]} -gt 0 ]; then CONFIGURE_CMD+=("${extra_configure[@]}"); fi

if [ $configure_needed -eq 1 ]; then
  info "Running configure for ${variant} (${conf_name})"
  printf '%s\n' "${CONFIGURE_CMD[*]}" >>"${LOG}"
  if ! "${CONFIGURE_CMD[@]}" >>"${LOG}" 2>&1; then
    err "Configure failed. See ${LOG}"
    exit 3
  fi
else
  info "Reusing existing configuration (${conf_name})"
fi

if [ $configure_only -eq 1 ]; then
  info "Configure-only requested. Exiting."; exit 0
fi

if [ $clean_first -eq 1 ]; then
  info "Running make clean"; make -s -j"${jobs}" clean >>"${LOG}" 2>&1 || { err "make clean failed"; exit 4; }
fi

if [ $run_images -eq 1 ]; then
  info "Building target: ${image_target} (jobs=${jobs})"
  if ! make -j"${jobs}" ${image_target} >>"${LOG}" 2>&1; then
    err "Build failed (target ${image_target}). See ${LOG}"
    exit 5
  fi
else
  info "Building target: all (no images)"
  if ! make -j"${jobs}" all >>"${LOG}" 2>&1; then
    err "Build failed (target all). See ${LOG}"; exit 5; fi
fi

JDK_IMAGE_GLOB="${BUILD_DIR}/images/jdk"
if [ -d "${JDK_IMAGE_GLOB}" ]; then
  info "JDK image created: $(c_green "${JDK_IMAGE_GLOB}")"
  JAVA="${JDK_IMAGE_GLOB}/bin/java"
  if [ -x "${JAVA}" ]; then
    info "java -version:"; "${JAVA}" -version 2>&1 | sed 's/^/        /'
  fi
else
  err "Expected JDK image directory not found at ${JDK_IMAGE_GLOB}"; exit 6
fi

info "Build log: ${LOG}"
info "Done."
