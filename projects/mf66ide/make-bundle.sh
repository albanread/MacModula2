#!/usr/bin/env bash
# Build a self-contained MF66.app bundling the IDE (mf66ide, MacModula2/Cocoa) and
# the engine (mf66 + mf66-tcl, Rust). The IDE resolves the engine executables
# relative to its own location (Contents/MacOS), so the bundle is relocatable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"            # projects/mf66ide (IDE source)
W2ROOT="$(cd "$HERE/../.." && pwd)"              # WindowsModula2 root (toolchain)
MF66="/Users/oberon/claudeprojects/MF66"
APP="$MF66/dist/MF66.app"                        # distributable bundle in the MF66 repo
mkdir -p "$MF66/dist"

echo "==> building the IDE (mf66ide)"
( cd "$W2ROOT" && ./target/debug/newm2-driver build --library library projects/mf66ide/mf66ide.mod )

echo "==> building the engine (mf66 + mf66-tcl, release)"
( cd "$MF66" && cargo build --release --features ui --bin mf66 --bin mf66-tcl )

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/examples"
cp "$HERE/mf66ide"                 "$APP/Contents/MacOS/mf66ide"
cp "$MF66/target/release/mf66"     "$APP/Contents/MacOS/mf66"
cp "$MF66/target/release/mf66-tcl" "$APP/Contents/MacOS/mf66-tcl"
cp "$MF66"/examples/*.f            "$APP/Contents/Resources/examples/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MF66</string>
  <key>CFBundleDisplayName</key><string>MF66 Forth IDE</string>
  <key>CFBundleExecutable</key><string>mf66ide</string>
  <key>CFBundleIdentifier</key><string>com.mf66.ide</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing (each Mach-O, then the bundle)"
codesign --force --sign - "$APP/Contents/MacOS/mf66"     2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/mf66-tcl" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/mf66ide"  2>/dev/null || true
codesign --force --sign - "$APP"                         2>/dev/null || true

echo "==> done: $APP"
du -sh "$APP" 2>/dev/null || true
