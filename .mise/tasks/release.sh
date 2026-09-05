#!/usr/bin/env bash
# mise description="Build, Developer ID sign, notarize, GitHub-release, and update the Homebrew cask"
#
# Usage: mise run release [build-date]
#   build-date defaults to today (YYYYMMDD). Produces version 1.1.16-tme.<build-date>.
#
# One-time setup required before the first run (see CLAUDE.md "Signed release"):
#   1. A "Developer ID Application" cert installed (EPCO Concepts team).
#   2. A shared App Store Connect API key for the EPCO team, stored in 1Password as item
#      "EPCO-ASC-API" (fields issuer + key-id) plus the .p8 as document "EPCO-ASC-API-key".
set -euo pipefail

# ---- config ----
REPO="tmepple/Browserino"                 # fork (GitHub releases live here)
TAP_DIR="${HOME}/Code/homebrew-tap"       # shared clone of tmepple/homebrew-tap; the cask lives here
TAP_NAME="tmepple/tap"                    # brew-facing tap name
BUNDLE_ID="xyz.alexstrnik.Browserino"
SCHEME="Browserino"
PROJECT="Browserino.xcodeproj"
OP_VAULT="Private"
OP_ITEM="op://${OP_VAULT}/EPCO-ASC-API"   # holds the issuer + key-id fields (single-line values)
OP_KEY_DOC="EPCO-ASC-API-key"             # the .p8 private key, stored as a 1Password *document*
                                          # (a text field flattens the PEM newlines -> invalidPEMDocument)
# The credential lives in the personal 1Password account, not the work account that may also
# be signed in. op has no per-reference account syntax, so scope all op calls via OP_ACCOUNT.
export OP_ACCOUNT="${OP_ACCOUNT:-epples.1password.com}"

die() { echo "error: $*" >&2; exit 1; }

# repo root = two levels above .mise/tasks/
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# MARKETING_VERSION is the source of truth in project.pbxproj
MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION/{gsub(/[ ;]/,"",$2); print $2; exit}' "$PROJECT/project.pbxproj")"
[[ -n "$MARKETING_VERSION" ]] || die "could not read MARKETING_VERSION from $PROJECT/project.pbxproj"

BUILD_DATE="${1:-$(date +%Y%m%d)}"
VERSION="${MARKETING_VERSION}-tme.${BUILD_DATE}"
TAG="v${VERSION}"

# ---- temp workspace + cleanup ----
P8=""
WORK=""
cleanup() {
  [[ -n "$P8"   && -f "$P8"   ]] && rm -f "$P8"
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. preflight ----
[[ -z "$(git status --porcelain)" ]] || die "git tree not clean; commit or stash first"
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists"

# The cask is committed into the shared tap clone, so it has to be clean and current
[[ -d "$TAP_DIR/.git" ]] || die "homebrew tap not found at $TAP_DIR"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || die "uncommitted changes in $TAP_DIR; commit or stash first"
git -C "$TAP_DIR" pull --rebase --quiet

DEVID_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)"
if [[ -z "$DEVID_LINE" ]]; then
  cat >&2 <<'EOF'
No "Developer ID Application" certificate found. One-time setup:
  Xcode > Settings > Accounts > EPCO Concepts > Manage Certificates
        > + > Developer ID Application
Then re-run this task.
EOF
  exit 1
fi
TEAM_ID="$(echo "$DEVID_LINE" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')"
IDENTITY_SHA="$(echo "$DEVID_LINE" | awk '{print $2}')"
[[ -n "$TEAM_ID" ]] || die "could not parse team id from: $DEVID_LINE"
[[ "$IDENTITY_SHA" =~ ^[A-F0-9]{40}$ ]] || die "could not parse identity SHA from: $DEVID_LINE"
echo "Identity: $DEVID_LINE"
echo "Team:     $TEAM_ID"
echo "Version:  $VERSION"

command -v op >/dev/null || die "1Password CLI (op) not found"
# `op whoami` reports "not signed in" under desktop-app integration (op 2.34.x) even when
# auth works; `op user get --me` does the real app handshake, so use it as the preflight.
op user get --me >/dev/null 2>&1 || die "cannot authenticate to 1Password account '$OP_ACCOUNT'; unlock the 1Password app (or run: op signin --account $OP_ACCOUNT)"

# ---- 2. notary credentials from 1Password (rendered to temp, removed on exit) ----
P8="$(mktemp -t browserino-notary)"
op document get "$OP_KEY_DOC" --vault "$OP_VAULT" > "$P8" \
  || die "could not read document '$OP_KEY_DOC' from vault '$OP_VAULT'"
KEY_ID="$(op read "${OP_ITEM}/key-id")"
ISSUER_ID="$(op read "${OP_ITEM}/issuer")"
[[ -s "$P8" && -n "$KEY_ID" && -n "$ISSUER_ID" ]] || die "incomplete notary credentials in 1Password"
head -1 "$P8" | grep -q "BEGIN PRIVATE KEY" \
  || die "document '$OP_KEY_DOC' is not a valid .p8 PEM (first line: $(head -1 "$P8"))"

# ---- 3. build unsigned, then sign with Developer ID ----
# The project pins CODE_SIGN_IDENTITY[sdk=macosx*] = "Don't Code Sign", and SDK-conditional
# build settings can't be reliably overridden on the xcodebuild command line (the '=' inside
# the brackets gets mis-parsed). So build unsigned — known-good, same as the Debug build —
# and sign the bundle directly. No nested frameworks/helpers, so one pass is complete.
echo "==> Building (unsigned)..."
rm -rf build
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build \
  build CODE_SIGNING_ALLOWED=NO

APP="$ROOT/build/Build/Products/Release/Browserino.app"
[[ -d "$APP" ]] || die "build did not produce $APP"

echo "==> Signing with Developer ID (hardened runtime + secure timestamp)..."
codesign --force --options runtime --timestamp \
  --entitlements "Browserino/Browserino.entitlements" \
  --sign "$IDENTITY_SHA" \
  "$APP"

echo "==> Verifying signature..."
codesign --verify --strict --verbose=2 "$APP"

# ---- 4. notarize + staple ----
WORK="$(mktemp -d)"
echo "==> Notarizing (automated scan, typically 1-3 min)..."
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" \
  --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
  --wait --timeout 30m --output-format json > "$WORK/notarize.json"
# Read Apple's verdict explicitly (and fetch its log when rejected) rather than
# trusting the exit status
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/notarize.json")"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$WORK/notarize.json")"
echo "Notarization $STATUS (submission $SUBMISSION_ID)"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" >&2 || true
  die "notarization was not accepted"
fi

echo "==> Stapling ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

# ---- 5. package the stapled app ----
ASSET="$WORK/Browserino-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ASSET"
SHA256="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
echo "Asset:  $(basename "$ASSET")"
echo "sha256: $SHA256"

# ---- 6. GitHub release on the fork ----
echo "==> Creating GitHub release $TAG..."
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ASSET" \
  --repo "$REPO" --latest \
  --title "$TAG" \
  --notes "tmepple fork of Browserino v${MARKETING_VERSION} (build ${BUILD_DATE}). Developer ID signed + notarized."

# ---- 7. update the cask in the tap ----
echo "==> Updating cask in $TAP_DIR..."
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/browserino-tme.rb" <<EOF
cask "browserino-tme" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/Browserino-#{version}.zip"
  name "Browserino (tmepple fork)"
  desc "Browser picker — tmepple fork"
  homepage "https://github.com/${REPO}"

  depends_on macos: :ventura

  app "Browserino.app"

  # Upgrades quit a running Browserino before swapping the bundle
  uninstall quit: "${BUNDLE_ID}"

  zap trash: ["~/Library/Preferences/${BUNDLE_ID}.plist"]
end
EOF
git -C "$TAP_DIR" add Casks/browserino-tme.rb
git -C "$TAP_DIR" commit -m "browserino-tme ${VERSION}"
git -C "$TAP_DIR" push

# ---- done ----
cat <<EOF

✓ Released ${TAG}
  Release: https://github.com/${REPO}/releases/tag/${TAG}
  Install: brew install --cask ${TAP_NAME}/browserino-tme
  Upgrade: brew upgrade --cask browserino-tme

  Brewfile:
    tap "${TAP_NAME}"
    cask "browserino-tme"
EOF
