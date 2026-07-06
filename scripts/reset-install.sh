#!/usr/bin/env bash
set -euo pipefail

# Lowercase to match how macOS records the Accessibility TCC client (see the
# PRODUCT_BUNDLE_IDENTIFIER note in App/Blurt/project.yml). Must match
# `BlurtIdentity.subsystem` (Sources/BlurtEngine/BlurtIdentity.swift) — the
# code's single definition of this string.
BUNDLE_ID="dev.alex.blurt"

# Quit Blurt first, or every step below is unreliable: a running instance
# keeps its defaults cached in cfprefsd (which rewrites the plist on quit,
# undoing `defaults delete`), can re-acquire TCC grants, and can rewrite the
# keychain item. killall (not AppleScript `quit`) avoids prompting the calling
# terminal for Automation permission.
echo "==> Quitting Blurt if running"
killall Blurt 2>/dev/null || true

echo "==> Resetting TCC permissions for $BUNDLE_ID"
# Microphone (recording), Accessibility (typing into other apps), and
# ListenEvent / Input Monitoring (the CGEventTap that backs the hold-to-dictate
# hotkey — see DictationKeyTap).
tccutil reset Accessibility "$BUNDLE_ID" || true
tccutil reset Microphone "$BUNDLE_ID" || true
tccutil reset ListenEvent "$BUNDLE_ID" || true

echo "==> Removing duplicate LaunchServices registrations for $BUNDLE_ID"
# Repeated builds leave Blurt.app copies in DerivedData, /tmp, periphery
# caches, and other checkouts — all claiming this bundle id. macOS then resolves
# the id to a transient copy TCC refuses to register, so Blurt silently
# vanishes from the Accessibility list. Unregister every copy, then re-register
# only the canonical install so the bundle id resolves to a stable path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -dump 2>/dev/null \
    | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\/Blurt\.app\) (0x[0-9a-f]*)$/\1/p' \
    | sort -u \
    | while IFS= read -r app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 && echo "    unregistered: $app" || true
      done
  for dest in "/Applications/Blurt.app" "$HOME/Applications/Blurt.app"; do
    [ -d "$dest" ] && "$LSREGISTER" -f "$dest" >/dev/null 2>&1 && echo "    registered: $dest" || true
  done
fi

echo "==> Clearing UserDefaults for $BUNDLE_ID"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# AssemblyAI API key lives in the login keychain as a generic password. The
# keychain service is `BlurtIdentity.subsystem` (used by APIKeyStore,
# Sources/BlurtEngine/Config/APIKeyStore.swift) — the lowercase bundle id to
# match macOS convention. Must match that constant.
KEYCHAIN_SERVICE="dev.alex.blurt"
KEYCHAIN_ACCOUNT="AssemblyAIAPIKey"
echo "==> Deleting AssemblyAI API key from Keychain ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true

# Developer mode appends a (raw, polished) corpus here (see DictationLog); a
# fresh install has none, so clear it too.
DICTATION_LOG_DIR="$HOME/Library/Logs/Blurt"
echo "==> Removing dictation log ($DICTATION_LOG_DIR/dictations.jsonl)"
rm -f "$DICTATION_LOG_DIR/dictations.jsonl"
rmdir "$DICTATION_LOG_DIR" 2>/dev/null || true

echo "Done. Relaunch Blurt for permission prompts to reappear."
