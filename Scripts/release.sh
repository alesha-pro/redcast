#!/bin/bash
# Build, sign with Developer ID, notarize and publish a Redcast release. See docs/shipping.md.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME=Redcast
BUNDLE_ID=io.redcast.app
PROFILE="${REDCAST_NOTARY_PROFILE:-redcast-notary}"
WORK="$ROOT/build/release"
FEED="Redcast/Features/Updates/Model/ReleaseFeed.swift"
TRUST="Redcast/Features/Updates/Service/BundleSignature.swift"
FRAMEWORKS=/System/Library/Frameworks/CoreServices.framework/Frameworks
LSREGISTER="$FRAMEWORKS/LaunchServices.framework/Support/lsregister"

usage() {
    cat <<EOF
Usage: Scripts/release.sh <version> [--universal] [--publish] [--notes FILE]
       Scripts/release.sh <version> --dry-run [--universal]
       Scripts/release.sh <version> --self-check

Builds Redcast <version> (MAJOR.MINOR.PATCH) in Release for Apple silicon, signs it with the
keychain's one Developer ID Application identity, notarizes and staples the app and its DMG, then
tags HEAD v<version>, pushes the tag and creates a draft GitHub Release with the zip and the DMG.

  --universal    also ship a -Universal- build, the only one an Intel Mac's updater installs
  --publish      publish the release at once instead of leaving it a draft
  --notes FILE   release notes to use instead of the generated list of commits
  --dry-run      build, sign and package with any identity; no notarization, tag or release
  --self-check   check identity, team, notary profile, tag and tree, and build nothing

Environment: REDCAST_RELEASE_IDENTITY (full identity name), REDCAST_NOTARY_PROFILE
($PROFILE, stored once with 'xcrun notarytool store-credentials $PROFILE').
Output: build/release/<version>/.
EOF
}

say() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() {
    local code=$1
    shift
    printf '✗ %s\n' "$*" >&2
    exit "$code"
}
warn() { printf '! %s\n' "$*" >&2; }

VERSION=""
MODE=release
UNIVERSAL=0
PUBLISH=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
    --universal) UNIVERSAL=1 ;;
    --publish) PUBLISH=1 ;;
    --notes)
        [ $# -ge 2 ] || die 64 "--notes needs a file."
        NOTES_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
        shift
        ;;
    --dry-run) MODE=dry-run ;;
    --self-check) MODE=self-check ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage >&2
        die 64 "unknown option: $1"
        ;;
    *)
        [ -z "$VERSION" ] || die 64 "one version only."
        VERSION="${1#v}"
        ;;
    esac
    shift
done
[ -n "$VERSION" ] || {
    usage >&2
    exit 64
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die 64 "version must be MAJOR.MINOR.PATCH, the only shape the stable channel offers."
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die 64 "no notes file at $NOTES_FILE."

TAG="v$VERSION"
DIST="$WORK/$VERSION"
REPO="$(sed -nE 's/^ *static let repository = "([^"]*)".*/\1/p' "$FEED")"
SOURCE_TEAM="$(sed -nE 's/.*leaf\[subject\.OU\] = \\?"([A-Z0-9]{10})\\?".*/\1/p' "$TRUST")"
[ -n "$REPO" ] || die 1 "could not read the release repository from $FEED."
[ -n "$SOURCE_TEAM" ] || die 1 "could not read the trusted team from $TRUST."
# Only a strict mismatch fails a real release; a dry run may sign with anything.
strict() { [ "$MODE" != dry-run ]; }
fail() { if strict; then die 2 "$@"; else warn "$*"; fi; }

resolve_identity() {
    if [ -n "${REDCAST_RELEASE_IDENTITY:-}" ]; then
        IDENTITY="$REDCAST_RELEASE_IDENTITY"
    else
        local lines
        lines="$(security find-identity -v -p codesigning 2>/dev/null |
            grep -E '^ *[0-9]+\) [0-9A-F]{40} "Developer ID Application: ' || true)"
        [ -n "$lines" ] || die 2 "no valid 'Developer ID Application' identity in the keychain." \
            "Create one in Xcode › Settings › Apple Accounts › Manage Certificates."
        [ "$(wc -l <<<"$lines")" -eq 1 ] || {
            printf '%s\n' "$lines" >&2
            die 2 "several Developer ID identities: set REDCAST_RELEASE_IDENTITY to the full name."
        }
        IDENTITY="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$lines")"
    fi
    TEAM="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null |
        openssl x509 -noout -subject -nameopt multiline 2>/dev/null |
        sed -nE 's/^ *organizationalUnitName *= *([A-Z0-9]+)$/\1/p' | head -1)"
    [ -n "$TEAM" ] || die 2 "no certificate named '$IDENTITY' in the keychain."
    case "$IDENTITY" in
    "Developer ID Application: "*) ;;
    *) fail "'$IDENTITY' is not a Developer ID Application identity; Gatekeeper refuses it." ;;
    esac
    # The installed app accepts an update only from the team it was built to trust.
    [ "$TEAM" = "$SOURCE_TEAM" ] || fail "the identity's team is $TEAM but $TRUST trusts" \
        "$SOURCE_TEAM: set the team there and commit it first, or no copy could update to this."
}

preflight() {
    resolve_identity
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
        git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
        fail "the tag $TAG already exists."
    fi
    if strict; then
        [ -z "$(git status --porcelain)" ] || die 2 "the working tree is not clean."
        git fetch -q origin main || die 1 "could not fetch origin."
        git merge-base --is-ancestor HEAD origin/main ||
            die 2 "HEAD is not on origin/main: push it first, so the tag names a published commit."
        gh auth status >/dev/null 2>&1 || die 2 "gh is not signed in: run 'gh auth login'."
        xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 ||
            die 2 "no working notary profile '$PROFILE'. Store it once (you type the secret):" \
                "xcrun notarytool store-credentials $PROFILE"
    fi
    BUILD="$(git rev-list --count HEAD)"
    note "version:     $VERSION ($BUILD), tag $TAG on $(git rev-parse --short HEAD)"
    note "identity:    $IDENTITY"
    note "team:        $TEAM (trusted by the source: $SOURCE_TEAM)"
    note "repository:  $REPO"
    note "notary:      $([ "$MODE" = dry-run ] && echo skipped || echo "profile $PROFILE")"
    note "builds:      arm64$([ "$UNIVERSAL" -eq 1 ] && echo ", universal")"
    note "output:      $DIST"
}

# Two arguments: the asset label ("" or "Universal-") and the architectures to build.
build() {
    local label=$1 archs=$2 derived="$WORK/DerivedData-${label:-thin}.noindex"
    say "Building $APP_NAME $VERSION for $archs…"
    rm -rf "$derived"
    mkdir -p "$WORK"
    local log="$WORK/build-${label:-thin}.log"
    # Secure timestamps are what notarization requires; install.sh skips them to stay offline.
    if ! xcodebuild -project Redcast.xcodeproj -scheme Redcast -configuration Release \
        -derivedDataPath "$derived" ARCHS="$archs" ONLY_ACTIVE_ARCH=NO \
        REDCAST_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM= \
        OTHER_CODE_SIGN_FLAGS=--timestamp \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
        build >"$log" 2>&1; then
        grep -E 'error:' "$log" | sort -u | head -40 >&2 || true
        die 1 "build failed; the full log is $log"
    fi
    local products="$derived/Build/Products/Release" product
    for product in "$products"/*.app; do
        [ -e "$product" ] && "$LSREGISTER" -u "$product" >/dev/null 2>&1 || true
    done
    APP="$products/$APP_NAME.app"
    verify_build "$archs"
}

verify_build() {
    ./Scripts/verify-signature.sh "$APP" || die 1 "$APP does not pass verify-signature.sh."
    local bin arch slices
    for bin in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Helpers/ClipboardTextHelper" \
        "$APP/Contents/Helpers/$APP_NAME Dictation.app/Contents/MacOS/$APP_NAME Dictation"; do
        slices=" $(lipo -archs "$bin") "
        for arch in $1; do
            [[ "$slices" == *" $arch "* ]] || die 1 "${bin##*/} has no $arch slice."
        done
    done
    local info
    info="$(codesign -dvv "$APP" 2>&1)"
    grep -q "^TeamIdentifier=$TEAM$" <<<"$info" || die 1 "the app is not signed by team $TEAM."
    grep -q "^Timestamp=" <<<"$info" || die 1 "the signature carries no secure timestamp."
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist")" = "$VERSION" ] || die 1 "the app's version is not $VERSION."
    ok "Built and verified $APP_NAME.app ($1)"
}

# Submits one file and waits; a rejection saves Apple's log beside the release.
notarize() {
    local file=$1 out id status
    say "Notarizing ${file##*/} (usually a few minutes)…"
    out="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait \
        --output-format json 2>&1)" || true
    id="$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' <<<"$out" | head -1)"
    status="$(sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' <<<"$out" | tail -1)"
    if [ "$status" != Accepted ]; then
        printf '%s\n' "$out" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" \
            "$DIST/notary-${file##*/}.json" >/dev/null 2>&1 || true
        die 1 "notarization of ${file##*/} ended as '${status:-unknown}'; log: $DIST"
    fi
    ok "Notarized ${file##*/}"
}

package() {
    local label=$1 base="$APP_NAME-${1}$VERSION"
    if strict; then
        local upload="$WORK/upload-${label:-thin}.zip"
        ditto -c -k --keepParent --sequesterRsrc "$APP" "$upload"
        notarize "$upload"
        rm -f "$upload"
        xcrun stapler staple -q "$APP" || die 1 "could not staple the app."
        spctl -a -t exec "$APP" 2>/dev/null || die 1 "Gatekeeper refuses the stapled app."
    fi
    # Only ditto keeps the seal; the updater expands this zip, never the DMG.
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$DIST/$base.zip"
    local stage
    stage="$(mktemp -d "$WORK/dmg.XXXXXX")"
    ditto "$APP" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"
    rm -f "$DIST/$base.dmg"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -format UDZO "$DIST/$base.dmg" ||
        die 1 "could not create the DMG."
    rm -rf "$stage"
    codesign --sign "$IDENTITY" --timestamp "$DIST/$base.dmg" || die 1 "could not sign the DMG."
    if strict; then
        notarize "$DIST/$base.dmg"
        xcrun stapler staple -q "$DIST/$base.dmg" || die 1 "could not staple the DMG."
        spctl -a -t open --context context:primary-signature "$DIST/$base.dmg" 2>/dev/null ||
            die 1 "Gatekeeper refuses the DMG."
    fi
    ASSETS+=("$DIST/$base.zip" "$DIST/$base.dmg")
    ok "Packaged $base.zip and $base.dmg"
}

# The fork's own tags read "Redcast X.Y.Z"; upstream's tags in this clone are not ours.
previous_release() {
    local tag
    for tag in $(git tag --merged HEAD --sort=-v:refname -l 'v[0-9]*'); do
        if [ "$(git for-each-ref "refs/tags/$tag" --format='%(contents:subject)')" = \
            "$APP_NAME ${tag#v}" ]; then
            printf '%s\n' "$tag"
            return
        fi
    done
}

write_notes() {
    NOTES="$DIST/notes.md"
    if [ -n "$NOTES_FILE" ]; then
        cp "$NOTES_FILE" "$NOTES"
        return
    fi
    local since range
    since="$(previous_release)"
    range="${since:+$since..}HEAD"
    {
        echo "## What's new"
        echo
        git log --first-parent --no-merges --format='- %s' "$range"
        echo
        echo "## Install"
        echo
        echo "Download \`$APP_NAME-$VERSION.dmg\`, open it and drag $APP_NAME to Applications."
        echo "Requires macOS 26 or later. Installed copies update themselves from here."
    } >"$NOTES"
}

publish() {
    say "Tagging $TAG and creating the release on $REPO…"
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    git push -q origin "refs/tags/$TAG" || die 1 "could not push $TAG; delete it with 'git tag -d $TAG'."
    local flag=--draft
    [ "$PUBLISH" -eq 0 ] || flag=--latest
    local url
    url="$(gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --verify-tag $flag \
        --title "$APP_NAME $VERSION" --notes-file "$NOTES")" ||
        die 1 "gh release create failed; the tag $TAG is pushed and the files are in $DIST."
    if [ "$PUBLISH" -eq 0 ]; then
        ok "Draft release: $url"
        note "Check it, then publish: gh release edit $TAG --repo $REPO --draft=false --latest"
    else
        ok "Published: $url"
    fi
}

say "Checking the release of $APP_NAME $VERSION…"
preflight
[ "$MODE" != self-check ] || exit 0
rm -rf "$DIST"
mkdir -p "$DIST"
ASSETS=()
# The thin build first: clients pick the first non-universal zip on Apple silicon.
build "" arm64
package ""
if [ "$UNIVERSAL" -eq 1 ]; then
    build "Universal-" "arm64 x86_64"
    package "Universal-"
fi
write_notes
if [ "$MODE" = dry-run ]; then
    ok "Dry run done, nothing notarized or published: $DIST"
    exit 0
fi
publish
