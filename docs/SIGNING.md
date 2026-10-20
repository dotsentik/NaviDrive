# Code signing

NaviDrive release builds are signed with a self-signed certificate named **"NaviDrive Signing"**
(`CODE_SIGN_IDENTITY` in `project.yml`). The SHA-256 fingerprint of its leaf certificate is pinned in
[`Config/signing-fingerprint.txt`](../Config/signing-fingerprint.txt).

## Why the certificate must not change

The in-app updater installs a new version only if it is signed with the same leaf certificate as the
running copy: the new app must satisfy the designated requirement of the running app
(`identifier "com.navidrive.NaviDrive" and certificate leaf = H"…"`).

If the certificate is lost, recreated (even with the same name) or replaced, every installed copy of
NaviDrive rejects all further updates with "The new version is not signed with the same certificate as
this copy". Users would have to download and install the new version by hand.

So:

- Never delete, recreate or replace "NaviDrive Signing" in the keychain.
- Never sign a release with another identity. `Scripts/release.sh` compares the fingerprint of the built
  app with `Config/signing-fingerprint.txt` and refuses to release on a mismatch.
- Keep an offline backup of the certificate and its private key (below).

## Backing up the certificate

This is a manual step; no script or agent exports the private key.

1. Open Keychain Access → login keychain → My Certificates.
2. Select "NaviDrive Signing" (expand it to make sure the private key is included).
3. File → Export Items… → format "Personal Information Exchange (.p12)".
4. Protect the file with a strong, unique password.
5. Store the .p12 and its password in a password manager, and a second copy on an offline medium
   (for example, an encrypted USB drive kept separately).

To restore on a new Mac, double-click the .p12 and import it into the login keychain.

## Expiry

The current certificate is valid until **2027-10-17** (`notAfter` of the leaf certificate).
`Scripts/release.sh` prints the expiry date and warns when fewer than 180 days remain.

macOS keeps accepting an existing signature after the certificate expires, but new builds can no longer
be signed with an expired certificate. Well before the expiry date, create a new certificate and move to
it with the replacement procedure below. Do not wait until it has expired: the transition release must
still be signed with the old certificate.

## Replacing the certificate safely

The updater accepts a new version when its signature is valid and either:

- (a) it satisfies the designated requirement of the running copy (same identifier, same certificate), or
- (b) it has the same bundle identifier and the SHA-256 fingerprint of its leaf certificate is listed in
  `NDTrustedSigningFingerprints` in the `Info.plist` of the running copy.

The SHA-256 checksum, version and download host checks apply in both cases. Ad-hoc signatures are
always rejected. `NDTrustedSigningFingerprints` is set in `project.yml` (target `NaviDrive` → `info`) and
currently lists only the current fingerprint from `Config/signing-fingerprint.txt`. Fingerprints are
compared without regard to case, spaces or colons.

Procedure (requires users to run 1.1.0 or later, the first version with rule (b)):

1. Create the new certificate and back it up (see above). Get its fingerprint from a test build signed with
   it: `codesign -d --extract-certificates`, then `openssl x509 -inform DER -in codesign0 -noout -fingerprint -sha256`.
2. Transition release: add the new fingerprint to `NDTrustedSigningFingerprints` (keep the old one), sign
   with the **old** certificate as usual and release it. Installed copies accept it by rule (a).
3. Wait until users have updated to the transition release (it is the copy whose `Info.plist` decides what
   the next update may be signed with).
4. Following releases: switch `CODE_SIGN_IDENTITY` to the new certificate, replace the fingerprint in
   `Config/signing-fingerprint.txt` with the new one so `Scripts/release.sh` accepts the build, and update
   the expiry date in this document. Copies that installed the transition release accept them by rule (b).
5. Later, once old copies no longer matter, the old fingerprint can be removed from the list.

Users who skip the transition release can no longer update in the app and must install the DMG by hand.

## Moving to Developer ID and notarization

Moving to an Apple Developer ID certificate (and notarization, which removes the Gatekeeper steps in the
README) changes the leaf certificate. It is possible only through the replacement procedure above,
with the Developer ID certificate as the new certificate.
