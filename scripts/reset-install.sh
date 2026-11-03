#!/usr/bin/env bash
set -euo pipefail

# Resets the shipping Blurt (`dev.alex.blurt`, /Applications/Blurt.app) to a
# clean preinstall state: settings, Keychain items, TCC grants, LaunchServices
# copies, and the logs and 🌐-key record both builds share. Blurt Dev's own
# state is left alone — scripts/reset-dev-install.sh resets that. Blurt's Library
# (saved transcripts and recordings) is kept: it's the user's history.
# The steps live in scripts/reset-lib.sh, shared by both.

# shellcheck source=scripts/reset-lib.sh
source "$(dirname "$0")/reset-lib.sh"
reset_install release
