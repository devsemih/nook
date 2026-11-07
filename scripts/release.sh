#!/bin/zsh
# Nook sürümü: Developer ID ile imzalı, Apple onaylı (notarized) bir .dmg üretir.
# Builds a Developer ID signed, notarized Nook.dmg.
#
# Bir kez / once:
#   xcrun notarytool store-credentials nook-notary --apple-id <apple-id> --team-id <TEAM_ID>
# Sonra / then:
#   scripts/release.sh
#
# İmza ayarları Config/Signing.xcconfig dosyasından gelir (bkz. Config/Signing.xcconfig.example).
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-nook-notary}"
OUT="${RELEASE_OUT:-build/release}"
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
TEAM=$(grep -E '^DEVELOPMENT_TEAM' Config/Signing.xcconfig | sed -E 's/.*= *//')
DMG="$OUT/Nook-$VERSION.dmg"

[[ -n "$TEAM" ]] || { echo "Config/Signing.xcconfig içinde DEVELOPMENT_TEAM yok"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null

echo "› Arşivleniyor ($VERSION)"
xcodebuild -project Posta.xcodeproj -scheme Posta -configuration Release \
  -archivePath "$OUT/Nook.xcarchive" -derivedDataPath "$OUT/DerivedData" archive -quiet

echo "› Developer ID ile dışa aktarılıyor"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Nook.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet

echo "› .dmg hazırlanıyor"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$OUT/export/Nook.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nook" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "› Apple'a onaya gönderiliyor (birkaç dakika sürebilir)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "› Doğrulanıyor"
spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG"
echo "Hazır: $DMG"
