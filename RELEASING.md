# Releasing Ruf

Public releases are automated from version tags. They currently use Ruf's
pinned self-signed Code Signing identity and are not notarized.

## Signing

### Self-signed releases

Ruf's pinned identity is named `Ruf Release Code Signing`. The release
maintainer must back up its certificate and private key as a
password-protected `.p12` outside the repository.

To validate this packaging path locally, import the identity into the login
Keychain and run:

```sh
./script/build_and_run.sh --release-self-signed
```

The stable identity persists across releases, but it does not satisfy
Gatekeeper or support notarization. Users must explicitly allow Ruf on first
launch. Moving from an older ad-hoc-signed release may also require granting
Accessibility permission one final time.

### Developer ID and notarization

To create a Developer ID release, store a `notarytool` profile in Keychain and
run:

```sh
RUF_DEVELOPER_ID_APPLICATION="Developer ID Application: NAME (TEAM_ID)" \
RUF_NOTARY_PROFILE="ruf-notary" \
./script/build_and_run.sh --release-notarized
```

The automated release workflow does not currently use this path.

## Publish a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
2. Copy `.github/release-notes/TEMPLATE.md` to
   `.github/release-notes/vMAJOR.MINOR.PATCH.md` and replace its placeholder
   with concise, user-visible changes.
3. Commit the version and release notes, push the commit to `main`, and wait
   for the `main` CI run to succeed.
4. Tag that same commit and push the matching tag:

   ```sh
   git tag vMAJOR.MINOR.PATCH
   git push origin vMAJOR.MINOR.PATCH
   ```

The tag triggers `.github/workflows/release.yml`. The workflow validates the
version and previous appcast, builds and tests Ruf, creates the self-signed
universal DMG, signs the Sparkle update, and verifies uploaded asset digests
before publishing the GitHub Release. Ordinary pushes to `main` run CI but
never publish a release.

## GitHub release environment

The workflow reads these secrets from the `release` GitHub environment:

- `RUF_CODESIGN_CERTIFICATE_P12`: the base64-encoded pinned self-signed `.p12`
- `RUF_CODESIGN_CERTIFICATE_PASSWORD`: the `.p12` export password
- `RUF_SPARKLE_PRIVATE_KEY`: the contents of the file written by Sparkle's
  `generate_keys --account com.qichen.ruf -x /secure/path/Ruf-Sparkle.private-key`
  command

Create that environment before pushing the first automated release tag. Keep
it approval-free for automatic publication, restrict deployments to release
tags, and limit tag creation to maintainers through a repository ruleset.
