#!/bin/bash
# Shared by check.sh and design-sync.sh: which swift-format to run. Sourced, not run.
#
# Sets SWIFT_FORMAT to the command as an array: the active Xcode toolchain's
# (through xcrun) when it has one, else a bare swift-format on PATH (e.g. a Linux
# build), else empty — and the caller decides what running without one means.
# shellcheck disable=SC2034 # used by the scripts that source this file
if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT=(xcrun swift-format)
elif command -v swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT=(swift-format)
else
  SWIFT_FORMAT=()
fi
