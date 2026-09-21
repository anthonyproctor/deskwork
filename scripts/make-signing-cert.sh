#!/bin/bash
# Create a local code-signing certificate so macOS stops re-asking for
# permissions after every rebuild.
#
# Why this exists: the default build is ad-hoc signed, and an ad-hoc signature
# is just a hash of the binary. macOS remembers privacy grants (Documents
# folder access, and the rest) against the app's signature — so every rebuild
# looks like a brand-new app and the "would like to access files in your
# Documents folder" prompt comes back. For an app that updates itself, that is
# a prompt on every update.
#
# A self-signed certificate fixes it without an Apple Developer account. macOS
# then ties the grant to the certificate, which does not change between
# builds. You approve once more after switching, and never again.
#
# This is OPT-IN. build-app.sh uses the certificate if it finds one and falls
# back to ad-hoc otherwise, so nothing changes for anyone who never runs this.
#
# It adds one certificate to your login keychain, named below. To undo:
#   security delete-identity -c "Project Coldfall Local"
#
# What it is NOT: this is not notarisation and does not remove Gatekeeper's
# "unidentified developer" warning for people you share the app with. It is a
# signature only your own machine trusts, for your own builds.

set -euo pipefail

NAME="Project Coldfall Local"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" is already in your login keychain. Nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A config file rather than -addext: macOS ships LibreSSL, which does not
# support -addext. codeSigning in extendedKeyUsage is what codesign requires.
cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Ten years: long enough never to expire under someone mid-project, and it
# only ever signs builds on this one machine.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The PKCS#12 password is throwaway: the file is imported and deleted within
# this script. LibreSSL writes the legacy format `security import` can read.
openssl pkcs12 -export -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:coldfall 2>/dev/null

# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/id.p12" -k "$KC" -P coldfall -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in your login keychain."
echo "Rebuild with ./scripts/build-app.sh — macOS will ask for permissions once more, then remember."
