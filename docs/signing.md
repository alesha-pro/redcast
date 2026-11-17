# Signing

Three identities, one per kind of build. Each stays the same from build to build, which is what makes
macOS remember Accessibility and the other grants: ad-hoc signing changes every build, and macOS
forgets.

| Build | Identity | Where it is named |
| --- | --- | --- |
| Xcode, VS Code F5, `xcodebuild` | `Redcast Self-Signed`, which each contributor creates once (§1) | `project.yml` |
| `Scripts/install.sh` on this Mac | the installed copy's identity, else Developer ID, else Apple Development | the script |
| Releases | `Developer ID Application: Anton Orlov (3BLDMY4DX4)`, notarized and stapled | `Scripts/release.sh` |

## 1. Create the `Redcast Self-Signed` identity (once)

Run these in a terminal. They generate a self-signed code-signing certificate and import it into your
login keychain:

```sh
# Generate a self-signed code-signing cert (10-year, codeSigning use).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/tc-key.pem -out /tmp/tc-cert.pem \
  -subj "/CN=Redcast Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle it as a .p12 (the non-empty password keeps `security import` happy).
openssl pkcs12 -export -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Redcast Self-Signed" -out /tmp/tc.p12 -passout pass:redcast

# Import into the login keychain so codesign can use it without prompting.
security import /tmp/tc.p12 -k ~/Library/Keychains/login.keychain-db \
  -P redcast -A -T /usr/bin/codesign

rm -f /tmp/tc-key.pem /tmp/tc-cert.pem /tmp/tc.p12
```

Verify it's there:

```sh
security find-identity -p codesigning | grep "Redcast Self-Signed"
```

Now local builds (Xcode, VS Code F5, `xcodebuild`) sign with it, and you grant Accessibility once.

## Hardened runtime

**Release only**, on both targets: `ENABLE_HARDENED_RUNTIME: YES`, which notarization requires. Debug
must stay without it — hardened runtime turns on library validation, and Xcode's
`Redcast Dev.debug.dylib` is refused at launch because a self-signed identity carries no Team ID for
the loader to match. The flag is not part of the designated requirement, so turning it on costs no
Accessibility grant. Each entitlement in `Redcast/Redcast.entitlements` earns its place:

| Entitlement | Without it |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore cannot JIT, and every extension command runs on the interpreter |
| `com.apple.security.automation.apple-events` | Every Apple event is refused with `-1743` and no prompt — Get Info, the Finder selection an extension reads, and the System Events–driven system actions all die silently |
| `com.apple.security.device.camera` | The camera prompt never appears and access resolves as denied |
| `com.apple.security.personal-information.calendars` | `requestFullAccessToEvents()` returns `false` in milliseconds with no dialog, and Redcast never appears under System Settings › Calendars |

**A usage string is not enough under the hardened runtime.** `tccd` checks the matching entitlement
*before* it prompts, and without it logs "requires entitlement … but it is missing" and denies on the
spot — no dialog, no error, status still `.notDetermined`. A grant saved before the hardened runtime
arrived keeps working, since `tccd` does not re-check it, which is why this surfaces only on fresh
installs. Adding a protected resource therefore means adding its usage string *and* its entitlement.

`RESOURCE_ENTITLEMENTS` in `Scripts/verify-signature.sh` maps every protected resource's usage string
to its entitlement, including resources Redcast does not use. That grants nothing — only
`Redcast.entitlements` does, and a row whose usage string `Info.plist` doesn't declare is skipped. It
is there so a future feature that adds the usage string but forgets the entitlement fails the release
instead of shipping a prompt that can never appear.

Nothing else is needed: the only `dlopen` is Apple's own IOBluetooth, so library validation is left
on, and `node`, `ray` and shell commands are separate processes it never reaches. Bluetooth has no
hardened-runtime entitlement.

`./Scripts/verify-signature.sh <path-to-.app>` asserts all of this — the runtime flag on the app *and*
on `Contents/Helpers/ClipboardTextHelper`, an intact nested seal, no `get-task-allow`, and an
entitlement for every usage string `Info.plist` declares. `install.sh` and `release.sh` run it before
packaging:
a nested binary missing the runtime flag is the most common notarization rejection, and a usage string
missing its entitlement ships a permission that can never be granted.

## Developer ID and the updater

`BundleSignature` trusts a bundle signed under Apple's Developer ID chain by team `3BLDMY4DX4`, or one
carrying the running app's own leaf certificate. The requirement pins the team rather than the
certificate, so a renewal strands nobody, and `release.sh` refuses an identity of another team. It
deliberately omits the `notarized` keyword: that resolves a ticket through `syspolicyd` or the
network, and the updater verifies in a cache directory Gatekeeper has never assessed, so an offline
Mac would refuse a bundle the chain already proves is ours. `install.sh` signs with the same
Developer ID when it can, so a local install and a release keep one requirement and one set of grants.

The Developer ID private key exists only in this Mac's login keychain, with a `.p12` backup kept
outside the repository. Losing both means a new certificate from the team's owner.

## Quarantine

macOS quarantines anything downloaded from the internet. A release's app and DMG are notarized and
stapled, so Gatekeeper opens them on first launch without a warning and nobody runs `xattr`.
