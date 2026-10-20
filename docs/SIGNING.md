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

Replacement is possible only with a NaviDrive version whose updater supports
`NDTrustedSigningFingerprints` (see the procedure in the `features-new` branch, released with 1.1.0).
Until such a version is installed by users, replacing the certificate breaks their updates.

## Moving to Developer ID and notarization

Moving to an Apple Developer ID certificate (and notarization, which removes the Gatekeeper steps in the
README) changes the leaf certificate. It is possible only through the replacement procedure above,
with the Developer ID certificate as the new certificate.
