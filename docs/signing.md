# Signing releases with a Developer ID

Releases ship a `Meetey.app` that CI builds, signs with a Developer ID, and
notarizes. `install` and `update` download it instead of compiling, and macOS
then remembers the microphone permission across updates, because the grant is
tied to the Team ID rather than to one build's hash. Without these secrets a
release has no app and install builds from source, which works but asks for the
microphone again after every update.

The certificate and keys live only in GitHub's encrypted secrets. They never go
on the machine that records meetings. The workflow only uses them for `v*`
tags, and GitHub does not give secrets to pull requests from forks.

## 1. Developer ID Application certificate

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If nothing is listed, create one: Xcode → Settings → Accounts → your team →
Manage Certificates → **+** → *Developer ID Application*. Only the team's
Account Holder can create it.

The name ends in your **Team ID**, for example
`Developer ID Application: Adam Cox (ABCDE12345)`. Install trusts downloaded
apps only from that team (`TEAM_ID` in `cli/app-bundle.js`).

## 2. Export it as a .p12

Keychain Access → login → My Certificates → right-click *Developer ID
Application: …* → **Export** → `.p12`, with a strong password. Export only this
one identity. `security export -t identities` would export every identity in
the keychain.

## 3. App Store Connect API key, for notarization

App Store Connect → Users and Access → Integrations → App Store Connect API →
Team Keys → **+**, access *Developer*. Download `AuthKey_<KEYID>.p8`. It can only
be downloaded once, so keep it somewhere safe. Note the **Key ID** and the
**Issuer ID** shown above the list.

## 4. Store them as repository secrets

```bash
base64 -i ~/Desktop/DeveloperID.p12 | gh secret set MACOS_CERT_P12 --repo adamjhc/meetey
gh secret set MACOS_CERT_PASSWORD --repo adamjhc/meetey        # prompts for the .p12 password
base64 -i ~/Downloads/AuthKey_KEYID.p8 | gh secret set NOTARY_KEY_P8 --repo adamjhc/meetey
gh secret set NOTARY_KEY_ID --repo adamjhc/meetey --body KEYID
gh secret set NOTARY_ISSUER_ID --repo adamjhc/meetey --body ISSUER-UUID
```

Then delete the exported `.p12` from the Desktop.

## 5. Set the Team ID and release

Put the Team ID in `TEAM_ID` in `cli/app-bundle.js`, then tag a release. The
`app` job builds, signs, runs the signed binary's selftest, notarizes, staples,
and attaches `Meetey-<version>.zip` to the release. `package-app.mjs` fails the
build if the signature's team is not `TEAM_ID`.

The first update to a signed app asks for the microphone once more, because a
new signature counts as a new app. After that it shouldn't ask again.
