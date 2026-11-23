#!/usr/bin/env bash
# Installs LLMits by building it from source into ~/Applications.
#
#   Install:    curl -fsSL https://raw.githubusercontent.com/karannavani/llmits/main/install.sh | bash
#   Uninstall:  curl -fsSL https://raw.githubusercontent.com/karannavani/llmits/main/install.sh | bash -s -- --uninstall
#
# Run it from a clone (./install.sh) to install that checkout instead of downloading a fresh copy.
# Building locally means there's no unsigned download for Gatekeeper to block.
set -euo pipefail

REPO="https://github.com/karannavani/llmits.git"
APP_NAME="LLMits"
EXECUTABLE="LLMits"
BUNDLE_ID="io.github.karannavani.llmits"
DEST="$HOME/Applications/$APP_NAME.app"
OLD_APP="$HOME/Applications/Claude Usage Bar.app"

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  step "Uninstalling $APP_NAME"
  removed=false
  for name in "$EXECUTABLE" ClaudeUsageBar; do
    pkill -x "$name" 2>/dev/null || true
  done
  for app in "$DEST" "$OLD_APP"; do
    if [[ -d "$app" ]]; then
      rm -rf "$app"
      note "Removed $app"
      removed=true
    fi
  done
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults delete io.github.karannavani.claude-usage-bar >/dev/null 2>&1 || true
  [[ "$removed" == true ]] || note "$APP_NAME wasn't installed in ~/Applications."
  note "If you had turned on Launch at Login, also remove it in"
  note "System Settings > General > Login Items."
  exit 0
fi

step "Checking requirements"

[[ "$(uname -s)" == "Darwin" ]] || fail "$APP_NAME only runs on macOS."
macos_version="$(sw_vers -productVersion)"
# Swift 6 first came with the developer tools for macOS 14.5, so earlier versions can't build it.
IFS=. read -r macos_major macos_minor _ <<<"$macos_version"
(( macos_major > 14 || (macos_major == 14 && ${macos_minor:-0} >= 5) )) ||
  fail "macOS 14.5 or later is required (this Mac has $macos_version)."

if ! xcode-select -p >/dev/null 2>&1; then
  note "Apple's Command Line Tools are needed to build the app."
  note "A dialog will open to install them. When it finishes, run this installer again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi
# `|| true` keeps `set -e` from ending the script silently when the tools are broken.
swift_output="$(xcrun swift --version 2>&1 || true)"
swift_version="$(printf '%s\n' "$swift_output" | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)"
if [[ -z "$swift_version" ]]; then
  printf '%s\n' "$swift_output" | head -n 5 | sed 's/^/    /' >&2
  if printf '%s' "$swift_output" | grep -qi 'license'; then
    fail "Xcode's licence hasn't been accepted yet. Run: sudo xcodebuild -license accept"
  fi
  fail "Apple's developer tools aren't working. Reinstall them with: xcode-select --install (or update Xcode), then try again."
fi
if (( ${swift_version%%.*} < 6 )); then
  fail "Swift 6 or later is required (found $swift_version). Update the Command Line Tools in Software Update (or Xcode in the App Store), then try again."
fi
note "macOS $macos_version, Swift $swift_version"

found_login=false
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || [[ -f "$HOME/.claude/.credentials.json" ]]; then
  note "Found your Claude Code login (for Claude limits)"
  found_login=true
fi
codex_home="${CODEX_HOME:-$HOME/.codex}"
if grep -q '"access_token"' "$codex_home/auth.json" 2>/dev/null; then
  note "Found your Codex ChatGPT login (for ChatGPT limits)"
  found_login=true
fi
cursor_db="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
if [[ -f "$cursor_db" ]] && /usr/bin/sqlite3 "file:$cursor_db?mode=ro" \
  "SELECT 1 FROM ItemTable WHERE key = 'cursorAuth/accessToken' AND length(value) > 0" 2>/dev/null | grep -q 1; then
  note "Found your Cursor login (for Cursor limits)"
  found_login=true
fi
if [[ "$found_login" == false ]]; then
  note "No Claude Code, Codex or Cursor login found yet. The app will install, but has nothing to"
  note "show until you sign in to at least one: run 'claude' and sign in, run 'codex login', or"
  note "sign in to the Cursor app."
fi

# Use this checkout when run from a clone; otherwise download a fresh copy.
script_path="${BASH_SOURCE[0]:-}"
if [[ -f "$script_path" && -f "$(dirname "$script_path")/scripts/build-app.sh" ]]; then
  source_dir="$(cd "$(dirname "$script_path")" && pwd)"
else
  command -v git >/dev/null || fail "git is required (it comes with Apple's Command Line Tools)."
  step "Downloading the source"
  work_dir="$(/usr/bin/mktemp -d)"
  trap 'rm -rf "${work_dir:?}"' EXIT
  # No login prompt if the repo can't be reached: fail with a clear message instead.
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 "$REPO" "$work_dir/llmits" ||
    fail "Couldn't download the source from $REPO. Check your connection and try again."
  source_dir="$work_dir/llmits"
fi

# Remember a custom CODEX_HOME for launches that don't inherit this shell's environment. Saved
# before the build, which launches the app, so its first check already looks in the right place.
if [[ -n "${CODEX_HOME:-}" ]]; then
  defaults write "$BUNDLE_ID" CodexHome "$CODEX_HOME"
fi

step "Building (about a minute the first time)"
build_log="$(/usr/bin/mktemp -t llmits-build)"
if ! "$source_dir/scripts/build-app.sh" --install >"$build_log" 2>&1; then
  # Show the actual errors first; the rest of the log is mostly long compiler command lines.
  if grep -q 'error:' "$build_log"; then
    # `|| true`: `head` closing the pipe early mustn't end the script before it says where the log is.
    grep 'error:' "$build_log" | sort -u | head -n 15 >&2 || true
  else
    tail -n 30 "$build_log" >&2
  fi
  fail "The build failed. Full log: $build_log"
fi
grep -E '^(Replaced|Warning)' "$build_log" | sed 's/^/    /' || true
rm -f "$build_log"

step "Done"
note "$APP_NAME is installed in ~/Applications."
note "Look for a small grid of dots and a percentage in your menu bar; click it for every limit."
note "To start it automatically, choose Launch at Login from its menu."
note "Can't see it? If you use Bartender or Ice, it may be in the hidden section."
