#!/usr/bin/env bash
# Builds LLMits.app into ./build.
#   --install   also copy it to /Applications (~/Applications if that isn't writable) and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LLMits"
EXECUTABLE="LLMits"
APP="build/$APP_NAME.app"
MIN_MACOS="14.0"
# The app's name before it was renamed, so an install replaces it rather than sitting beside it.
OLD_APP_NAME="Claude Usage Bar"
OLD_EXECUTABLE="ClaudeUsageBar"

# The app icon is compiled ahead of time; check for it before spending a minute on the build.
# ("error:" makes install.sh show this line.)
[[ -f Support/CompiledIcon/Assets.car && -f Support/CompiledIcon/AppIcon.icns ]] ||
  { echo "error: Support/CompiledIcon is missing; run scripts/build-icon.sh (needs Xcode 26 or later)." >&2; exit 1; }

# Build with the toolchain `xcrun` picks, the same one install.sh checks.
xcrun swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Logos/*.svg "$APP/Contents/Resources/"

# The Liquid Glass app icon (Assets.car for macOS 26 and later, AppIcon.icns before that),
# compiled ahead of time by scripts/build-icon.sh, as compiling it needs Xcode.
cp Support/CompiledIcon/Assets.car Support/CompiledIcon/AppIcon.icns "$APP/Contents/Resources/"

# SwiftPM can stamp the binary as built against the oldest SDK it supports, and macOS uses that
# stamp to decide which modern behaviours the app gets. Record the SDK it was really built with.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "Built $APP"

# Quits this account's running copy and waits for it to exit (forcing it after five seconds).
# Only this account's: on a shared Mac, another user's copy can't be quit and doesn't block.
quit_app() {
  local name="$1"
  pkill -u "$UID" -x "$name" 2>/dev/null || return 0
  for _ in {1..50}; do
    pgrep -u "$UID" -x "$name" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -u "$UID" -x "$name" 2>/dev/null || true
  sleep 0.5
  ! pgrep -u "$UID" -x "$name" >/dev/null
}

# Opens the app and waits for it to be running. Straight after a quit, macOS can briefly treat the
# app as still running and ignore `open`, so it tries a few times.
launch_app() {
  for _ in 1 2 3; do
    open "$1" 2>/dev/null || true
    for _ in {1..30}; do
      pgrep -u "$UID" -x "$EXECUTABLE" >/dev/null && return 0
      sleep 0.1
    done
  done
  return 1
}

# Removes an old copy if there is one. Not being allowed to (another account's copy in
# /Applications, say) is worth a warning but never stops the install.
remove_old_app() {
  [[ -d "$1" ]] || return 1
  rm -rf "$1" 2>/dev/null && return 0
  echo "Warning: couldn't remove $1; delete it in the Finder, or ask an administrator to." >&2
  return 1
}

if [[ "${1:-}" == "--install" ]]; then
  # /Applications, not ~/Applications: from macOS 27, the menu bar only handles items properly for
  # apps run from there, and menu bar managers such as Bartender can't see the others. Anyone in
  # the admin group can write to it without sudo; for anyone else, fall back to ~/Applications.
  if [[ -w /Applications ]]; then
    INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    echo "Warning: /Applications isn't writable by this account, so $APP_NAME goes in ~/Applications. Bartender and similar apps may not be able to move its menu bar item there; install from an administrator account to fix that." >&2
    if [[ -d "/Applications/$APP_NAME.app" ]]; then
      echo "Warning: there's also a $APP_NAME in /Applications, which Spotlight may open instead of this one." >&2
    fi
  fi
  DEST="$INSTALL_DIR/$APP_NAME.app"

  quit_app "$EXECUTABLE" || { echo "Couldn't quit the running $APP_NAME; quit it and try again." >&2; exit 1; }

  # Install first, so a failure here leaves any earlier copy where it was. The new copy goes in
  # beside the old one, and they swap by renaming, which either works or changes nothing (unlike
  # deleting, which can stop halfway and leave a broken app). The suffixes stop either one being
  # opened as an app.
  rm -rf "$DEST.new" "$DEST.old" 2>/dev/null || true
  cp -R "$APP" "$DEST.new"
  if [[ -e "$DEST" ]] && ! mv "$DEST" "$DEST.old" 2>/dev/null; then
    rm -rf "$DEST.new"
    echo "error: couldn't replace $DEST; delete it in the Finder (or ask whoever installed it), then try again." >&2
    # It was quit above; reopen the version that's still there.
    launch_app "$DEST" || true
    exit 1
  fi
  mv "$DEST.new" "$DEST"
  rm -rf "$DEST.old" 2>/dev/null ||
    echo "Warning: couldn't remove the previous version, left at $DEST.old; delete it in the Finder." >&2
  # The staging copy would otherwise show up in Spotlight and Launchpad as a second LLMits.
  rm -rf "$APP"
  echo "Installed $DEST"

  # Then clear away earlier copies. Earlier versions installed into ~/Applications; a copy left
  # there would be a second LLMits.
  if [[ "$INSTALL_DIR" == /Applications ]] && remove_old_app "$HOME/Applications/$APP_NAME.app"; then
    echo "Moved $APP_NAME from ~/Applications to /Applications. If it started at login and stops doing so, turn Launch at Login off and on again from its menu."
  fi
  # And the app it used to be, with its settings.
  if [[ -d "/Applications/$OLD_APP_NAME.app" || -d "$HOME/Applications/$OLD_APP_NAME.app" ]] ||
     pgrep -u "$UID" -x "$OLD_EXECUTABLE" >/dev/null; then
    quit_app "$OLD_EXECUTABLE" || true
    # Its settings go only once no copy is left to use them.
    remove_old_app "/Applications/$OLD_APP_NAME.app" || [[ ! -d "/Applications/$OLD_APP_NAME.app" ]] || kept_old=true
    remove_old_app "$HOME/Applications/$OLD_APP_NAME.app" || [[ ! -d "$HOME/Applications/$OLD_APP_NAME.app" ]] || kept_old=true
    if [[ "${kept_old:-false}" == false ]]; then
      defaults delete io.github.karannavani.claude-usage-bar >/dev/null 2>&1 || true
      echo "Replaced $OLD_APP_NAME, the app's old name. If it started at login, turn on Launch at Login again from LLMits's menu."
    fi
  fi

  # A launch failure isn't a failed install: the app is in place either way.
  if launch_app "$DEST"; then
    echo "Launched $APP_NAME"
  else
    echo "Warning: couldn't launch $APP_NAME automatically; open it from $INSTALL_DIR." >&2
  fi
fi
