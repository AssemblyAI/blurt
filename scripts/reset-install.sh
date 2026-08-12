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
    done || echo "    note: lsregister dump failed; skipping unregister sweep"
  for dest in "/Applications/Blurt.app" "$HOME/Applications/Blurt.app"; do
    [ -d "$dest" ] && "$LSREGISTER" -f "$dest" >/dev/null 2>&1 && echo "    registered: $dest" || true
  done
fi

echo "==> Clearing UserDefaults for $BUNDLE_ID"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# AssemblyAI API key lives in the login keychain as a generic password. The
# service is `BlurtIdentity.keychainService` and the account is the one
# `APIKeyStore` uses (Sources/BlurtEngine/Config/APIKeyStore.swift) — the product
# name, since Keychain Access shows the service as the item's name. Must match
# those constants. Builds before the rename stored the key under the bundle id
# (`BlurtIdentity.legacyKeychainService`); the app migrates that item on first
# read, but a reset has to clear it too, or the next launch adopts it back.
KEYCHAIN_SERVICE="Blurt"
LEGACY_KEYCHAIN_SERVICE="$BUNDLE_ID"
KEYCHAIN_ACCOUNT="AssemblyAIAPIKey"
echo "==> Deleting AssemblyAI API key from Keychain ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
for service in "$KEYCHAIN_SERVICE" "$LEGACY_KEYCHAIN_SERVICE"; do
  security delete-generic-password -s "$service" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
done

# Developer mode appends transcript and failure logs here (see DictationLog); a
# fresh install has neither, so clear them too. The rmdir below only succeeds
# once the directory is empty, so every file Blurt writes there must be listed.
DICTATION_LOG_DIR="$HOME/Library/Logs/Blurt"
echo "==> Removing dictation logs ($DICTATION_LOG_DIR/{dictations,errors}.jsonl)"
rm -f "$DICTATION_LOG_DIR/dictations.jsonl" "$DICTATION_LOG_DIR/errors.jsonl"
rmdir "$DICTATION_LOG_DIR" 2>/dev/null || true

echo "Done. Relaunch Blurt for permission prompts to reappear."
