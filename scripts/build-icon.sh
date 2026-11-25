#!/usr/bin/env bash
# Compiles the app icon (Support/AppIcon.icon, made in Icon Composer) into Support/CompiledIcon,
# which scripts/build-app.sh copies into the app, and renders the README's copies into docs. Run
# it after changing the icon and commit the result, so building the app needs only Apple's Command
# Line Tools: compiling the icon needs the actool in Xcode 26 or later, and rendering it needs
# Icon Composer, which comes with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="14.0"
OUT="Support/CompiledIcon"

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "Compiling the icon needs Xcode 26 or later. If it's installed, select it with:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

work="$(/usr/bin/mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

# Assets.car holds the Liquid Glass icon for macOS 26 and later; AppIcon.icns is for earlier
# versions. Support/Info.plist already names both (CFBundleIconName and CFBundleIconFile).
xcrun actool "$PWD/Support/AppIcon.icon" --compile "$work" \
  --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
  --output-partial-info-plist "$work/icon-info.plist" --output-format human-readable-text

mkdir -p "$OUT"
cp "$work/Assets.car" "$work/AppIcon.icns" "$OUT/"
echo "Compiled the app icon into $OUT"

# The README's copies of the icon, as macOS draws it in light and dark mode, at 128 points (@2x).
# This ictool comes with Icon Composer; the one `xcrun` finds is a version of actool instead.
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || { echo "Rendering the README's icon needs Icon Composer, which comes with Xcode 26 or later." >&2; exit 1; }
for rendition in Default Dark; do
  suffix=""
  [[ "$rendition" == Dark ]] && suffix="-dark"
  "$ictool" "$PWD/Support/AppIcon.icon" --export-image --output-file "$PWD/docs/llmits-icon$suffix.png" \
    --platform macOS --rendition "$rendition" --width 128 --height 128 --scale 2 >/dev/null
done
echo "Rendered the README's icon into docs"
