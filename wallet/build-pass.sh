#!/bin/bash
# Builds and signs Mahir.pkpass from the files in this folder.
# Usage: ./build-pass.sh path/to/PassCertificate.p12
set -euo pipefail

cd "$(dirname "$0")"

P12="${1:-}"
if [[ -z "$P12" || ! -f "$P12" ]]; then
  echo "Usage: ./build-pass.sh path/to/PassCertificate.p12" >&2
  exit 1
fi

read -r -s -p "Password for $(basename "$P12"): " P12_PASS
echo
export P12_PASS

BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD/pass"

# Keychain exports use older ciphers that OpenSSL 3 only reads with -legacy.
LEGACY=""
if ! openssl pkcs12 -in "$P12" -passin env:P12_PASS -nokeys -clcerts -out /dev/null 2>/dev/null; then
  LEGACY="-legacy"
fi
openssl pkcs12 $LEGACY -in "$P12" -passin env:P12_PASS -clcerts -nokeys -out "$BUILD/cert.pem"
openssl pkcs12 $LEGACY -in "$P12" -passin env:P12_PASS -nocerts -nodes -out "$BUILD/key.pem"
chmod 600 "$BUILD/key.pem"

# Apple's intermediate certificate, needed in the signature chain.
curl -fsSL -o "$BUILD/wwdr.cer" https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer
openssl x509 -inform DER -in "$BUILD/wwdr.cer" -out "$BUILD/wwdr.pem"

# The certificate itself names the Pass Type ID (UID) and Team ID (OU).
SUBJECT=$(openssl x509 -in "$BUILD/cert.pem" -noout -subject -nameopt RFC2253)
PASS_TYPE_ID=$(sed -E 's/.*UID=([^,]+).*/\1/' <<<"$SUBJECT")
TEAM_ID=$(sed -E 's/.*OU=([^,]+).*/\1/' <<<"$SUBJECT")
echo "Pass Type ID: $PASS_TYPE_ID"
echo "Team ID:      $TEAM_ID"

sed -e "s/__PASS_TYPE_ID__/$PASS_TYPE_ID/" -e "s/__TEAM_ID__/$TEAM_ID/" \
  pass.template.json > "$BUILD/pass/pass.json"
cp icon.png icon@2x.png icon@3x.png logo.png logo@2x.png "$BUILD/pass/"

(
  cd "$BUILD/pass"
  {
    echo "{"
    first=1
    for f in *; do
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '  "%s": "%s"' "$f" "$(shasum -a 1 "$f" | cut -d' ' -f1)"
    done
    echo
    echo "}"
  } > ../manifest.json
  mv ../manifest.json manifest.json

  openssl smime -binary -sign \
    -certfile ../wwdr.pem -signer ../cert.pem -inkey ../key.pem \
    -in manifest.json -out signature -outform DER

  rm -f ../../Mahir.pkpass
  zip -q -X ../../Mahir.pkpass ./*
)

rm -f "$BUILD/key.pem"
echo "Built $(pwd)/Mahir.pkpass"
