#!/bin/zsh
# Rebuild 'Syncopation CE.app' from Syncopation.swift
# The Community Edition installs alongside Syncopation Pro: different app
# name, different bundle id, so neither overwrites or shadows the other.
set -e
cd "$(dirname "$0")"

APP="Syncopation CE.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Universal binary: build each architecture and join them, so the app runs
# natively on both Apple Silicon and Intel Macs (macOS 14 still supports Intel
# machines from roughly 2018 onwards).
SOURCES=(Syncopation.swift IPodDB.swift AudioMetadata.swift AudioConvert.swift IPodModels.swift IPodSync.swift)
SLICES=()
for ARCH in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 \
        -target ${ARCH}-apple-macos13.0 \
        $SOURCES \
        -o "$APP/Contents/MacOS/SyncopationCE-$ARCH"
    SLICES+=("$APP/Contents/MacOS/SyncopationCE-$ARCH")
done
lipo -create $SLICES -output "$APP/Contents/MacOS/SyncopationCE"
rm -f $SLICES

# This folder is iCloud-synced, which keeps re-adding Finder xattrs that make
# codesign fail ("resource fork ... not allowed"). Sign a clean copy in local
# tmp, then move it back.
TMP=$(mktemp -d)
ditto --norsrc --noextattr --noacl "$APP" "$TMP/$APP"
codesign --force --sign - "$TMP/$APP"
rm -rf "$APP"
mv "$TMP/$APP" "$APP"
rmdir "$TMP"
echo "Built $APP — double-click it in Finder or run: open \"$APP\""
echo "Install with: rm -rf \"/Applications/$APP\" && cp -R \"$APP\" /Applications/"
