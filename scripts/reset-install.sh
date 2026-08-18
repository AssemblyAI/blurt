#!/usr/bin/env bash
set -euo pipefail

# Both bundle ids Blurt ships under. Lowercase to match how macOS records the
# Accessibility TCC client (see the PRODUCT_BUNDLE_IDENTIFIER note in
# App/Blurt/project.yml), where the split is also explained: releases are
# `dev.alex.blurt`, every debug configuration is `dev.alex.blurt.dev`, so a dev
# build is a separate app with its own permissions, defaults and install path.
# The first must match `HostIdentity.blurt.subsystem`
# (Sources/BlurtEngine/HostIdentity.swift) — the code's single definition of
# this string. A full reset means both: this script exists to get back to a
# clean preinstall state, and leaving half the state behind is how you end up
# debugging the other build's leftovers.
BUNDLE_IDS=("dev.alex.blurt" "dev.alex.blurt.dev")

# Quit Blurt first, or every step below is unreliable: a running instance
# keeps its defaults cached in cfprefsd (which rewrites the plist on quit,
# undoing `defaults delete`), can re-acquire TCC grants, and can rewrite the
# keychain item. killall (not AppleScript `quit`) avoids prompting the calling
# terminal for Automation permission. One name covers both builds: PRODUCT_NAME
# stays `Blurt` in every configuration, so both executables are called `Blurt`.
echo "==> Quitting Blurt if running"
killall Blurt 2>/dev/null || true

for bundle_id in "${BUNDLE_IDS[@]}"; do
  echo "==> Resetting TCC permissions for $bundle_id"
  # Microphone (recording), Accessibility (typing into other apps), and
  # ListenEvent / Input Monitoring (the CGEventTap that backs the hold-to-dictate
  # hotkey — see DictationKeyTap).
  tccutil reset Accessibility "$bundle_id" || true
  tccutil reset Microphone "$bundle_id" || true
  tccutil reset ListenEvent "$bundle_id" || true
done

echo "==> Removing duplicate LaunchServices registrations"
# Repeated builds leave Blurt.app / Blurt Dev.app copies in DerivedData, /tmp,
# periphery caches, and other checkouts — all claiming one of the bundle ids.
# macOS then resolves an id to a transient copy TCC refuses to register, so
# Blurt silently vanishes from the Accessibility list. Unregister every copy,
# then re-register only the canonical installs so each id resolves to a stable
# path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  # Exactly the two bundle names, via an optional " Dev" (POSIX BRE interval, so
  # BSD and GNU sed agree). A looser `Blurt[^/]*\.app` would also sweep
  # BlurtUITests-Runner.app — a bundle this script neither owns nor re-registers.
  "$LSREGISTER" -dump 2>/dev/null \
    | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\/Blurt\( Dev\)\{0,1\}\.app\) (0x[0-9a-f]*)$/\1/p' \
    | sort -u \
    | while IFS= read -r app; do
      "$LSREGISTER" -u "$app" >/dev/null 2>&1 && echo "    unregistered: $app" || true
    done || echo "    note: lsregister dump failed; skipping unregister sweep"
  for dest in "/Applications/Blurt.app" "$HOME/Applications/Blurt.app" \
    "/Applications/Blurt Dev.app" "$HOME/Applications/Blurt Dev.app"; do
    [ -d "$dest" ] && "$LSREGISTER" -f "$dest" >/dev/null 2>&1 && echo "    registered: $dest" || true
  done
fi

for bundle_id in "${BUNDLE_IDS[@]}"; do
  echo "==> Clearing UserDefaults for $bundle_id"
  defaults delete "$bundle_id" 2>/dev/null || true
done

# AssemblyAI API key lives in the login keychain as a generic password. The
# keychain service is `HostIdentity.blurt.keychainService` (used by APIKeyStore,
# Sources/BlurtEngine/Config/APIKeyStore.swift). Must match that constant.
# Installs that predate the service rename may still hold the key under the
# old service (the lowercase bundle id), so a full reset deletes both.
KEYCHAIN_SERVICE="blurt"
# The shipping id, always — the pre-rename service predates the debug/release id
# split, so there was only ever one value to have used.
LEGACY_KEYCHAIN_SERVICE="${BUNDLE_IDS[0]}"
KEYCHAIN_ACCOUNT="AssemblyAIAPIKey"
echo "==> Deleting AssemblyAI API key from Keychain ($KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
echo "==> Deleting pre-rename AssemblyAI API key from Keychain ($LEGACY_KEYCHAIN_SERVICE / $KEYCHAIN_ACCOUNT)"
security delete-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true

# Developer mode appends transcript and failure logs here (see DictationLog); a
# fresh install has neither, so clear them too. The rmdir below only succeeds
# once the directory is empty, so every file Blurt writes there must be listed.
DICTATION_LOG_DIR="$HOME/Library/Logs/Blurt"
echo "==> Removing dictation logs ($DICTATION_LOG_DIR/{dictations,errors}.jsonl)"
rm -f "$DICTATION_LOG_DIR/dictations.jsonl" "$DICTATION_LOG_DIR/errors.jsonl"
rmdir "$DICTATION_LOG_DIR" 2>/dev/null || true

echo "Done. Relaunch Blurt for permission prompts to reappear."
