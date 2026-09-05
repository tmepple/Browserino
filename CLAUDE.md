# Browserino — local fork dev notes

This is `tmepple/Browserino`, a personal fork of `AlexStrNik/Browserino`. Upstream is the source of truth; this fork carries occasional cherry-picked PRs that haven't merged upstream yet.

## Merging an upstream PR

Upstream PRs can be pulled directly from GitHub's pull refs without adding a remote:

```bash
git fetch https://github.com/AlexStrNik/Browserino.git pull/<N>/head:pr-<N>-<slug>
git merge --no-ff pr-<N>-<slug> -m "Merge PR AlexStrNik#<N>: <title>"
git branch -d pr-<N>-<slug>
```

`--no-ff` preserves the PR-merge context in history even when it would fast-forward.

## Building a Release for local install

The project ships with `CODE_SIGNING_ALLOWED = NO` and a hard-coded upstream
`DEVELOPMENT_TEAM`. Rather than fight that with sign-during-build overrides, **build the
bundle unsigned (the project's default) and sign it afterward.** The project pins
`"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Don't Code Sign"`, and that SDK-conditional setting
can't be reliably overridden on the `xcodebuild` command line — the `=` inside the brackets
gets mis-parsed (the value comes through as `macosx*]=...`), so a sign-during-build
invocation fails with *"No certificate for team … matching …"*. **Do not edit
`project.pbxproj`** — keeping it untouched keeps future upstream merges conflict-free.

Ad-hoc signing is the right choice for a personal install on this Mac: locally-built apps have no `com.apple.quarantine` xattr, so Gatekeeper doesn't intervene, and no Apple Developer account / provisioning profile is required.

```bash
rm -rf build
xcodebuild -project Browserino.xcodeproj -scheme Browserino \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build \
  build CODE_SIGNING_ALLOWED=NO

# ad-hoc sign the finished bundle — no nested frameworks/helpers, so one pass is complete:
codesign --force -s - build/Build/Products/Release/Browserino.app
```

(The notarized release task in `.mise/tasks/release.sh` uses the same build-unsigned-then-
`codesign` flow, just with the Developer ID identity plus `--options runtime --timestamp`.)

Verify the result:

```bash
codesign --verify --verbose=2 build/Build/Products/Release/Browserino.app
# Expect: "valid on disk" and "satisfies its Designated Requirement"
```

## Installing into /Applications

Browserino is almost always running (it's the default browser), so it has to be quit before its bundle can be replaced.

```bash
osascript -e 'quit app "Browserino"'; sleep 1
rm -rf /Applications/Browserino.app
cp -R build/Build/Products/Release/Browserino.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Browserino.app
open /Applications/Browserino.app
```

The default-browser association and user preferences are keyed by bundle id (`xyz.alexstrnik.Browserino`), so they survive the replacement as long as the bundle id is not changed.

## Debug builds

For quick local iteration that doesn't touch /Applications, skip signing entirely:

```bash
xcodebuild -project Browserino.xcodeproj -scheme Browserino \
  -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
# Launches from ~/Library/Developer/Xcode/DerivedData/Browserino-*/Build/Products/Debug/
```

## Signed release & Homebrew distribution

For running this fork on *other* Macs without copy-pasting the bundle around, the
app is Developer ID-signed + Apple-notarized and distributed as a Homebrew cask in
`tmepple/homebrew-tap`. Notarization is an automated malware scan (not App Review) —
it takes minutes, has no human approval step, and once the ticket is **stapled** the
app launches on any Mac with no Gatekeeper prompt and no `xattr` fiddling.

The whole flow is one task: `mise run release [build-date]` (see `.mise/tasks/release.sh`).
It builds → signs (Developer ID, hardened runtime, secure timestamp) → notarizes (failing
with Apple's log if the verdict isn't *Accepted*) → staples → cuts a GitHub release on the
fork → rewrites `Casks/browserino-tme.rb` in the shared tap clone at `~/Code/homebrew-tap`
(which must be clean; the task pulls it first, commits `browserino-tme <version>`, pushes).

### One-time setup (per machine that cuts releases)

1. **Developer ID Application cert** (EPCO Concepts team): Xcode → Settings → Accounts →
   EPCO Concepts → Manage Certificates → **+** → *Developer ID Application*. The release
   task auto-detects the identity and team id from the installed cert — nothing is hardcoded.
2. **App Store Connect API key** for `notarytool` — created on **appstoreconnect.apple.com**
   (not Xcode, not developer.apple.com): Users and Access → **Integrations** tab → App Store
   Connect API → **Team Keys** → **+** (role *Developer* is sufficient). Download the `.p8`
   once (no re-download); note the **Key ID** and the **Issuer ID** (top of the Keys page).
   This is a **team-wide** credential — one key notarizes any EPCO app, so it's stored
   generically and reused, not per-app.
3. **Store the credential in 1Password** (vault `Private`, **personal account**). The `.p8`
   must be a **document**, not a text field — pasting a PEM into a text field flattens its
   newlines and notarytool then rejects it with `invalidPEMDocument`.
   ```bash
   # issuer + key id — single-line values, fine as fields:
   op item create --account epples.1password.com \
     --category="API Credential" --title="EPCO-ASC-API" --vault=Private \
     issuer="<ISSUER_ID>" key-id="<KEY_ID>"
   # the private key — byte-exact, as a document titled EPCO-ASC-API-key:
   op document create AuthKey_<KEY_ID>.p8 --account epples.1password.com \
     --title="EPCO-ASC-API-key" --vault=Private
   ```
   (Either command can be done in the 1Password GUI instead — for the key, New Item →
   Document → upload the `.p8` → title `EPCO-ASC-API-key`.)

   The task reads `op://Private/EPCO-ASC-API/{issuer,key-id}` plus `op document get
   EPCO-ASC-API-key`, renders the `.p8` to a temp file for the duration of one `notarytool`
   call, and removes it on exit (never persisted to disk plaintext). Secret references have
   no account component, so when multiple 1Password accounts are signed in the task scopes
   all `op` calls via `OP_ACCOUNT` (default `epples.1password.com`; override by exporting it).

### Versioning

`MARKETING_VERSION` stays at the upstream value (no `project.pbxproj` edits). The tag and
cask carry the fork build date: **`<upstream>-tme.<YYYYMMDD>`** (e.g. `1.1.16-tme.20260601`),
so `brew upgrade` detects a new fork build even when the upstream version is unchanged. The
About screen shows `Browserino v<upstream>` plus a `TME Fork · <date>` line
(`Browserino/Views/Preferences/AboutTab.swift`) — a view-only marker with no side effects.

### Installing on another Mac (declarative)

The cask token is `browserino-tme` (not `browserino`) to avoid colliding with a future
official Browserino cask in homebrew-cask. The installed bundle is still `Browserino.app`.

```ruby
# Brewfile
tap "tmepple/tap"
cask "browserino-tme"
```

```bash
brew install --cask tmepple/tap/browserino-tme   # first install
brew upgrade --cask browserino-tme               # after a new release here
```

The cask quits a running Browserino before an upgrade swaps the bundle (`uninstall quit:`).
