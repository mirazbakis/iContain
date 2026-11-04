#!/bin/bash
# Compiles core/ for iPhone and the Apple-silicon Simulator, then wraps both static
# libraries and the C header into iContainFFI.xcframework. Run after changing core/.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Same minimum as project.yml, so C code inside dependencies targets the same iOS.
export IPHONEOS_DEPLOYMENT_TARGET=18.0

targets=(aarch64-apple-ios aarch64-apple-ios-sim)
args=()
for target in "${targets[@]}"; do
  echo "→ cargo build ($target)"
  cargo build --manifest-path "$root/core/Cargo.toml" --release --target "$target"
  args+=(-library "$root/core/target/$target/release/libicontain_ffi.a" -headers "$root/core/include")
done

echo "→ iContainFFI.xcframework"
rm -rf "$root/iContainFFI.xcframework"
xcodebuild -create-xcframework "${args[@]}" -output "$root/iContainFFI.xcframework" >/dev/null
echo "Done. Regenerate the Xcode project with: xcodegen generate"
