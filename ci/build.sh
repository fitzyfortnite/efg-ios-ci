#!/usr/bin/env bash
# Unpacks the Unity Xcode export, archives it with automatic (cloud) signing and uploads to TestFlight.
# Needs env: EXPORT_KEY (decrypts export/), ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (App Store Connect API key, role Admin)
# Optional: BUILD_NUMBER (default 100 + run number)
set -euo pipefail
TEAM_ID="${TEAM_ID:-S3SMBYR9FZ}"
BUILD_NUMBER="${BUILD_NUMBER:-$((100 + ${GITHUB_RUN_NUMBER:-0}))}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/efg"
LOGS="$ROOT/logs"
mkdir -p "$WORK" "$LOGS"

echo "== Xcode"
# App Store requires the iOS 26 SDK: pick the newest Xcode 26 on the runner
XC=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$XC" ]; then sudo xcode-select -s "$XC/Contents/Developer"; fi
xcodebuild -version
echo "== export"; cat "$ROOT/export/build_info.txt"

echo "== decrypt"
# export/ holds AES-256-CBC (OpenSSL, PBKDF2-SHA256 600k) ciphertext + HMAC-SHA256 of the ciphertext
OSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
[ -x "$OSSL" ] || { brew install openssl@3 >/dev/null; OSSL="$(brew --prefix openssl@3)/bin/openssl"; }
KEYFILE="$WORK/export.key"; ( umask 077; printf '%s' "$EXPORT_KEY" > "$KEYFILE" )
cat "$ROOT"/export/efg_ios.zip.enc.[0-9][0-9][0-9] > "$WORK/efg_ios.zip.enc"
python3 - "$KEYFILE" "$WORK/efg_ios.zip.enc" "$ROOT/export/efg_ios.zip.enc.hmac" <<'PY'
import hmac, hashlib, sys
key = open(sys.argv[1]).read().strip().encode()
mk = hashlib.pbkdf2_hmac("sha256", key, b"efg-export-mac", 200000)
h = hmac.new(mk, digestmod=hashlib.sha256)
with open(sys.argv[2], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
if not hmac.compare_digest(h.hexdigest(), open(sys.argv[3]).read().strip()):
    sys.exit("::error::Export integrity check failed (wrong EXPORT_KEY or corrupted parts)")
print("integrity ok")
PY
"$OSSL" enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in "$WORK/efg_ios.zip.enc" -out "$WORK/efg_ios.zip" -pass "file:$KEYFILE"
rm -f "$KEYFILE" "$WORK/efg_ios.zip.enc"
[ "$(shasum -a 256 "$WORK/efg_ios.zip" | cut -d' ' -f1)" = "$(cat "$ROOT/export/efg_ios.zip.sha256")" ] || { echo "::error::Decrypted zip checksum mismatch"; exit 1; }

echo "== unpack"
rm -rf "$WORK/xcode" && mkdir -p "$WORK/xcode" && cd "$WORK/xcode"
unzip -q "$WORK/efg_ios.zip"
# the zip comes from Windows: restore execute bits for build-phase scripts and the macOS IL2CPP tools
find . -name "*.sh" -exec chmod +x {} +
chmod -R +x Il2CppOutputProject/IL2CPP/build

echo "== Info.plist checks"
# the Unity export must have run its iOS post-build steps (they only exist while iOS is the active platform)
if ! /usr/libexec/PlistBuddy -c "Print :GADApplicationIdentifier" Info.plist >/dev/null 2>&1; then
  echo "::error::Info.plist has no GADApplicationIdentifier: the Xcode export was made before the scripts recompiled for iOS. Re-export from Unity with iOS already active."
  exit 1
fi
/usr/libexec/PlistBuddy -c "Delete :ITSAppUsesNonExemptEncryption" Info.plist >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" Info.plist

echo "== build number $BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist

echo "== team"
sed -i '' "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $TEAM_ID;/g" Unity-iPhone.xcodeproj/project.pbxproj

echo "== pods"
# the full GitHub specs repo is several GB; the CDN is enough
sed -i '' "/github.com\/CocoaPods\/Specs/d" Podfile
pod install --repo-update 2>&1 | tee "$LOGS/pod.log"

echo "== api key"
KEY_DIR="$HOME/private_keys"; mkdir -p "$KEY_DIR"
KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "== archive (unsigned; App Store signing is applied at export by Xcode cloud signing)"
# Automatic signing at archive time wants a *development* profile, which needs a registered device.
# So: archive unsigned, ad-hoc sign with the app's entitlements (Game Center), then -exportArchive
# re-signs with the cloud-managed Apple Distribution certificate + an App Store profile (no device needed).
ARCHIVE="$WORK/EscapeFromGranny.xcarchive"
xcodebuild -workspace Unity-iPhone.xcworkspace -scheme Unity-iPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  archive > "$LOGS/archive.log" 2>&1 || { grep -E "error:|BUILD FAILED|ARCHIVE FAILED" "$LOGS/archive.log" | head -80; tail -60 "$LOGS/archive.log"; exit 1; }
tail -5 "$LOGS/archive.log"

echo "== ad-hoc sign with entitlements"
APP=$(ls -d "$ARCHIVE/Products/Applications/"*.app)
find "$APP/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null | xargs -0 -I{} codesign -f -s - {}
# Unity writes "<true />", which the codesign entitlements parser rejects: normalise with plutil
plutil -convert xml1 -o "$WORK/app.entitlements" EscapeFromGranny.entitlements
codesign -f -s - --entitlements "$WORK/app.entitlements" "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep "<key>" || true

echo "== export + upload to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/out" \
  -exportOptionsPlist "$ROOT/ci/ExportOptions.plist" "${AUTH[@]}" > "$LOGS/export.log" 2>&1 || { tail -80 "$LOGS/export.log"; exit 1; }
tail -20 "$LOGS/export.log"
rm -f "$KEY_PATH"
echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect > TestFlight after processing (5-30 min)."
