#!/usr/bin/env bash
#
# build-macapp.sh — assemble a self-contained "MacM2 IDE.app" bundle.
#
# The bundle contains the Modula-2 editor (the compiled macide GUI) AND the
# compiler/JIT toolchain (newm2-driver + the standard library), so Build & Run
# and autocomplete work when the app is launched from Finder / Applications —
# no dev checkout, no Xcode, no PATH setup required at run time.
#
# Build & Run uses the in-process ORC JIT (`newm2-driver run`), so the shipped
# app needs NO external linker (clang/ld) or runtime static library. Building the
# bundle does need the Rust toolchain + Xcode command-line tools (clang/ld), to
# compile the Rust driver and AOT-link the IDE binary.
#
# Usage:
#   scripts/build-macapp.sh [--debug] [--out DIR] [--open]
#     --debug   use the debug Rust profile (faster build; default: release)
#     --out DIR write the .app into DIR (default: ./dist)
#     --open    `open` the bundle when done
#
set -euo pipefail

APP_NAME="MacM2 IDE"
LAUNCHER="MacM2"                       # CFBundleExecutable (no spaces)
BUNDLE_ID="com.albanread.macm2.ide"
VERSION="1.0"
IDE_SRC="projects/macide/macos_panes_ide.mod"
PROFILE="release"
OUT="dist"
DO_OPEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) PROFILE="debug" ;;
    --out)   OUT="$2"; shift ;;
    --open)  DO_OPEN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 1. Rust toolchain -----------------------------------------------------------
# The driver carries the JIT runtime in-process (Build & Run needs nothing else),
# but AOT-linking the IDE binary below needs libnewm2_runtime.a next to the driver,
# so build both crates for this profile.
say "Building the toolchain — driver + runtime ($PROFILE)…"
if [ "$PROFILE" = "release" ]; then cargo build --release -p newm2-driver -p newm2-runtime
else cargo build -p newm2-driver -p newm2-runtime; fi
DRIVER="target/$PROFILE/newm2-driver"
[ -x "$DRIVER" ] || { echo "driver not found at $DRIVER" >&2; exit 1; }

# --- 2. AOT-compile the IDE to a standalone Mach-O ------------------------------
say "Compiling the IDE ($IDE_SRC)…"
"$DRIVER" build --library library "$IDE_SRC"
IDE_BIN="${IDE_SRC%.mod}.exe"          # the driver writes <name>.exe (a Mach-O)
[ -f "$IDE_BIN" ] || { echo "IDE binary not produced at $IDE_BIN" >&2; exit 1; }

# --- 3. Compile the launcher (a real Mach-O main executable) --------------------
say "Compiling the launcher…"
LAUNCH_BIN="$(mktemp -t macm2-launcher)"
cc -O2 -Wall -o "$LAUNCH_BIN" "$REPO/scripts/macapp-launcher.c"

# --- 4. Assemble the bundle -----------------------------------------------------
APP="$OUT/$APP_NAME.app"
say "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ROOT="$APP/Contents/Resources/newm2-root"     # the working dir the launcher cd's into

# the launcher (CFBundleExecutable) + the IDE Mach-O
cp "$LAUNCH_BIN" "$APP/Contents/MacOS/$LAUNCHER"; chmod +x "$APP/Contents/MacOS/$LAUNCHER"
cp "$IDE_BIN"    "$APP/Contents/MacOS/macide";    chmod +x "$APP/Contents/MacOS/macide"
rm -f "$LAUNCH_BIN"
strip -x "$APP/Contents/MacOS/macide" 2>/dev/null || true   # drop local symbols (strip before signing)

# the self-contained tool root: mirror the relative layout the IDE expects
mkdir -p "$ROOT/target/debug" "$ROOT/docs"
cp "$DRIVER" "$ROOT/target/debug/newm2-driver"    # IDE hardcodes ./target/debug/newm2-driver
chmod +x "$ROOT/target/debug/newm2-driver"
strip -x "$ROOT/target/debug/newm2-driver" 2>/dev/null || true
cp -R library        "$ROOT/library"              # --library library + sidebar lists
cp -R docs/m2-guide  "$ROOT/docs/m2-guide"        # the help-pane topics
# NB: library/ is copied whole — library/NewM2 looks Windows-only but `System_Memory`
# there is pulled in transitively (Strings -> Heap -> System_Memory), so it stays.

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$LAUNCHER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
PLIST
# optional icon: drop a prebuilt AppIcon.icns at assets/macapp/AppIcon.icns
if [ -f "$REPO/assets/macapp/AppIcon.icns" ]; then
  cp "$REPO/assets/macapp/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  printf '  <key>CFBundleIconFile</key><string>AppIcon</string>\n' >> "$APP/Contents/Info.plist"
fi
cat >> "$APP/Contents/Info.plist" <<'PLIST'
</dict>
</plist>
PLIST

# --- 5. Ad-hoc code signing (so it runs locally on Apple Silicon) ---------------
say "Code-signing (ad-hoc)…"
codesign --force -s - "$ROOT/target/debug/newm2-driver" 2>/dev/null || true
codesign --force -s - "$APP/Contents/MacOS/macide"      2>/dev/null || true
codesign --force -s - "$APP/Contents/MacOS/$LAUNCHER"   2>/dev/null || true
codesign --force -s - "$APP"                            2>/dev/null || \
  echo "  (ad-hoc codesign skipped/failed — the app still runs locally)"

SIZE="$(du -sh "$APP" | cut -f1)"
say "Done: $APP  ($SIZE)"
echo "    Launch:  open \"$APP\""
echo "    (Build & Run uses the in-process JIT — no Xcode needed at run time.)"
[ "$DO_OPEN" = 1 ] && open "$APP" || true
