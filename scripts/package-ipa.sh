#!/bin/bash
# Wraps a built iContain.app into an .ipa, ad hoc signed so sideloading tools accept
# it (they sign it again with your certificate), and checks the result.
# Usage: scripts/package-ipa.sh <path/to/iContain.app> <output.ipa>
set -euo pipefail

app="$1"
out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Payload"
cp -R "$app" "$work/Payload/"
find "$work/Payload" -name '.DS_Store' -delete
codesign --force --sign - --timestamp=none --generate-entitlement-der "$work/Payload/$(basename "$app")"
codesign --verify "$work/Payload/$(basename "$app")"
rm -f "$out"
(cd "$work" && zip -qry -X "$out" Payload)

unzip -tq "$out" >/dev/null
info="$work/Payload/$(basename "$app")/Info.plist"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
  echo "$key = $(/usr/libexec/PlistBuddy -c "Print :$key" "$info")"
done
ls -lh "$out"
