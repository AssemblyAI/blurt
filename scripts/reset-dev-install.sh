#!/usr/bin/env bash
set -euo pipefail

# Resets Blurt Dev (`dev.alex.blurt.dev`, /Applications/Blurt Dev.app — every
# debug build, scripts/dev-build.sh's included) to a clean preinstall state:
# settings, Keychain items, TCC grants, LaunchServices copies, its Library (saved
# transcripts, recordings, read-aloud clips), and the logs and 🌐-key record both
# builds share. The shipping Blurt's own state is left
# alone — scripts/reset-install.sh resets that. The steps live in
# scripts/reset-lib.sh, shared by both.

# shellcheck source=scripts/reset-lib.sh
source "$(dirname "$0")/reset-lib.sh"
reset_install dev
