#!/usr/bin/env bash
# The shared base of the terminal reset: reset-install.sh (the shipping app)
# and reset-dev-install.sh (Blurt Dev) each call `reset_install` with their own
# build's identity. Sourced, never executed.
#
# Blurt ships the same sweep in-app — Settings > Advanced > Reset, the engine's
# `InstallReset` — for the user who shouldn't have to run a shell script; keep
# the two in step. The scripts stay the fuller ones: they unregister stale app
# copies from LaunchServices, which an app can't meaningfully do to itself.
#
# Each build is a separate app to macOS (releases are `dev.alex.blurt`, every
# debug configuration is `dev.alex.blurt.dev` — see the PRODUCT_BUNDLE_IDENTIFIER
# note in App/Blurt/project.yml), so its TCC rows, defaults domain and Keychain
# items are its own and a reset of one leaves the other's alone. Two things are
# shared, and either reset clears them, as the in-app reset does: the 🌐-key
# record and the developer-mode dictation logs.

# The log subsystem, the same for both builds, the release bundle id (the dev
# build's is this plus `.dev`), and the prefix of the shared 🌐-key suite. Must
# match `HostIdentity.blurt.subsystem` (Sources/BlurtEngine/HostIdentity.swift).
# `ResetScriptContractTests` checks this file against the Swift constants.
BLURT_SUBSYSTEM="dev.alex.blurt"

# The Keychain accounts Blurt writes under its build's service: the API key
# (`APIKeyStore.keychainAccount`) and the Sign in with AssemblyAI session
# (`SignInStore.keychainAccount`).
BLURT_KEYCHAIN_ACCOUNTS=("AssemblyAIAPIKey" "AssemblyAISignIn")

# bundle_id_of APP → the CFBundleIdentifier of the .app at APP, or nothing.
bundle_id_of() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

# reset_install release|dev
reset_install() {
  local bundle_id app_name keychain_services library_dir=""
  case "${1:-}" in
    # Keychain: `HostIdentity.blurt.keychainService`, plus the service installs
    # that predate its rename may still hold the key under — the release bundle
    # id, always, since that rename predates the debug/release id split.
    release)
      bundle_id="$BLURT_SUBSYSTEM" app_name="Blurt"
      keychain_services=("blurt" "$BLURT_SUBSYSTEM")
      ;;
    # Keychain: `HostIdentity.blurtDev.keychainService`.
    dev)
      bundle_id="$BLURT_SUBSYSTEM.dev" app_name="Blurt Dev"
      keychain_services=("blurt-dev")
      # The Library — saved transcripts, recordings, read-aloud clips — under
      # `HostIdentity.blurtDev.dataDirectoryName`. Only the dev reset empties
      # one: the release build's is the user's real history, and a reset for
      # permissions trouble shouldn't take it.
      library_dir="$HOME/Library/Application Support/Blurt Dev"
      ;;
    *)
      echo "usage: reset_install release|dev" >&2
      return 2
      ;;
  esac

  # Quit this build first, or every step below is unreliable: a running
  # instance keeps its defaults cached in cfprefsd (which rewrites the plist on
  # quit, undoing `defaults delete`), can re-acquire TCC grants, and can rewrite
  # the keychain item. Both builds' executables are called `Blurt` (PRODUCT_NAME
  # stays `Blurt` in every configuration), so `killall Blurt` would take the
  # other build down too: match each process's bundle by id instead. kill (not
  # AppleScript `quit`) avoids prompting the calling terminal for Automation.
  # Then wait for it to go, since a quitting app still writes on its way out.
  echo "==> Quitting $app_name if running"
  local pid exe pids=() tries
  for pid in $(pgrep -x Blurt || true); do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    if [ "$(bundle_id_of "${exe%/Contents/MacOS/*}")" = "$bundle_id" ]; then
      kill "$pid" 2>/dev/null && pids+=("$pid")
    fi
  done
  for pid in ${pids[@]+"${pids[@]}"}; do
    for tries in $(seq 50); do
      kill -0 "$pid" 2>/dev/null || break
      [ "$tries" -lt 50 ] && sleep 0.1 || echo "    note: pid $pid is still running"
    done
  done

  echo "==> Resetting TCC permissions for $bundle_id"
  # Microphone (recording), Accessibility (typing into other apps), and
  # ListenEvent / Input Monitoring (the CGEventTap that backs the hold-to-dictate
  # hotkey — see DictationKeyTap), and AppleEvents / Automation (controlling
  # Spotify and Music for the music pause — see MediaPauseController).
  tccutil reset Accessibility "$bundle_id" || true
  tccutil reset Microphone "$bundle_id" || true
  tccutil reset ListenEvent "$bundle_id" || true
  tccutil reset AppleEvents "$bundle_id" || true

  echo "==> Removing duplicate LaunchServices registrations for $bundle_id"
  # Repeated builds leave Blurt.app copies in DerivedData, /tmp, periphery
  # caches, and other checkouts — all claiming a bundle id. macOS then resolves
  # the id to a transient copy TCC refuses to register, so Blurt silently
  # vanishes from the Accessibility list. Unregister every copy of this build,
  # then re-register only its canonical installs so the id resolves to a stable
  # path. A dev build is `Blurt.app` until its install renames it, so the name
  # can't tell the builds apart: each record's own `identifier:` line does
  # (it follows the record's `path:`, and records are split by dashed lines).
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$lsregister" ]; then
    # Exactly the two bundle names, via an optional " Dev". A looser
    # `Blurt[^/]*\.app` would also sweep BlurtUITests-Runner.app — a bundle
    # this script neither owns nor re-registers.
    "$lsregister" -dump 2>/dev/null \
      | awk -v id="$bundle_id" '
          /^-+$/ { path = "" }
          /^path:/ && match($0, /\/.*\/Blurt( Dev)?\.app \(0x[0-9a-f]+\)$/) {
            path = substr($0, RSTART, RLENGTH); sub(/ \(0x[0-9a-f]+\)$/, "", path)
          }
          /^identifier:/ && path != "" { if ($2 == id) print path; path = "" }' \
      | sort -u \
      | while IFS= read -r app; do
        "$lsregister" -u "$app" >/dev/null 2>&1 && echo "    unregistered: $app" || true
      done || echo "    note: lsregister dump failed; skipping unregister sweep"
    local dest
    for dest in "/Applications/$app_name.app" "$HOME/Applications/$app_name.app"; do
      [ -d "$dest" ] && "$lsregister" -f "$dest" >/dev/null 2>&1 && echo "    registered: $dest" || true
    done
  fi

  echo "==> Clearing UserDefaults for $bundle_id"
  defaults delete "$bundle_id" 2>/dev/null || true

  # Keychain items are per login keychain rather than per app, so the builds are
  # NOT separated by their bundle ids the way their defaults and TCC rows are:
  # each one names its own service (see `HostIdentity.keychainService`).
  local service account
  for service in "${keychain_services[@]}"; do
    for account in "${BLURT_KEYCHAIN_ACCOUNTS[@]}"; do
      echo "==> Deleting $account from Keychain ($service)"
      security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || true
    done
  done

  # While `fn` is the dictation key, Blurt sets macOS's "Press 🌐 key to" to Do
  # Nothing and keeps the value it replaced in a suite both builds share (see
  # `GlobeKeyOverride.sharedSuite`). The app puts it back when another key is
  # bound — but a wiped install never does, so restore it here, then drop the
  # record. If the other build still binds `fn`, its next launch re-applies the
  # override (`GlobeKeyOverride.sync` runs at start) and records the value
  # restored here as the original, which it is.
  # `-1` is `GlobeKeyOverride.wasUnset`: the key was absent, so remove it again.
  local globe_suite="$BLURT_SUBSYSTEM.globe-key" replaced
  if replaced=$(defaults read "$globe_suite" hotkey.replacedGlobeKeyUsage 2>/dev/null); then
    echo "==> Restoring the 🌐 key setting Blurt replaced"
    if [ "$replaced" = "-1" ]; then
      defaults delete com.apple.HIToolbox AppleFnUsageType 2>/dev/null || true
    else
      defaults write com.apple.HIToolbox AppleFnUsageType -int "$replaced"
    fi
  fi
  defaults delete "$globe_suite" 2>/dev/null || true

  # Developer mode appends transcript and failure logs here (see DictationLog).
  # Both builds write the one directory, and the in-app reset of either clears
  # it, so this does too. The rmdir only succeeds once the directory is empty,
  # so every file Blurt writes there must be listed.
  local log_dir="$HOME/Library/Logs/Blurt"
  echo "==> Removing dictation logs ($log_dir/{dictations,errors,commands}.jsonl)"
  rm -f "$log_dir/dictations.jsonl" "$log_dir/errors.jsonl" "$log_dir/commands.jsonl"
  rmdir "$log_dir" 2>/dev/null || true

  if [ -n "$library_dir" ]; then
    echo "==> Emptying the Library ($library_dir)"
    rm -rf "$library_dir"
  fi

  echo "Done. Relaunch $app_name for permission prompts to reappear."
}
