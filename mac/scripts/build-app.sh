#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
package_dir="${script_dir:h}"
bundle_path="${package_dir}/SecondSightMac.app"
contents_path="${bundle_path}/Contents"
macos_path="${contents_path}/MacOS"
frameworks_path="${contents_path}/Frameworks"
resources_path="${contents_path}/Resources"

resolve_signing_identity() {
  if [[ -n "${SECONDSIGHT_SIGNING_IDENTITY:-}" ]]; then
    print -r -- "$SECONDSIGHT_SIGNING_IDENTITY"
    return
  fi

  security find-identity -v -p codesigning \
    | awk '/"Apple Development:/ { print $2; exit }'
}

signing_identity="$(resolve_signing_identity)"
if [[ -z "$signing_identity" ]]; then
  print -u2 "No Apple Development signing identity was found."
  print -u2 "Install a development certificate or set SECONDSIGHT_SIGNING_IDENTITY to a stable code-signing identity."
  print -u2 "Ad-hoc signing is intentionally disabled because it invalidates macOS privacy permissions after rebuilds."
  exit 3
fi

cd "$package_dir"
swift build -c release --product SecondSightMac

if [[ "$bundle_path" != "$package_dir/SecondSightMac.app" ]]; then
  print -u2 "Refusing unexpected bundle path: $bundle_path"
  exit 2
fi
rm -rf "$bundle_path"
mkdir -p "$macos_path" "$frameworks_path" "$resources_path"

cp ".build/release/SecondSightMac" "$macos_path/SecondSightMac"
cp "Resources/Info.plist" "$contents_path/Info.plist"
if [[ -f "Config.plist" ]]; then
  cp "Config.plist" "$resources_path/Config.plist"
else
  cp "Config.template.plist" "$resources_path/Config.plist"
fi
for localization_dir in Resources/*.lproj(N); do
  cp -R "$localization_dir" "$resources_path/"
done

cp -R ".build/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework" "$frameworks_path/"
cp -R ".build/artifacts/livekit-uniffi-xcframework/RustLiveKitUniFFI/RustLiveKitUniFFI.xcframework/macos-arm64_x86_64/RustLiveKitUniFFI.framework" "$frameworks_path/"

if ! otool -l "$macos_path/SecondSightMac" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$macos_path/SecondSightMac"
fi

plutil -lint "$contents_path/Info.plist" "$resources_path/Config.plist"
codesign --force --sign "$signing_identity" --timestamp=none "$frameworks_path/LiveKitWebRTC.framework"
codesign --force --sign "$signing_identity" --timestamp=none "$frameworks_path/RustLiveKitUniFFI.framework"
codesign --force --sign "$signing_identity" --timestamp=none "$macos_path/SecondSightMac"
codesign --force --sign "$signing_identity" --timestamp=none "$bundle_path"
codesign --verify --deep --strict --verbose=2 "$bundle_path"

print -u2 "Signed with stable identity: $signing_identity"
print "$bundle_path"
