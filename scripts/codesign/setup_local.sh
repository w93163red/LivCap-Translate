#!/usr/bin/env bash

set -exu

certificateFile="codesign"
certificatePassword=$(openssl rand -base64 12)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/generate_selfsigned_certificate.sh" "$certificateFile" "$certificatePassword"
"$SCRIPT_DIR/import_certificate_into_main_keychain.sh" "$certificateFile" "$certificatePassword"

echo "Local code signing setup complete!"
echo "Certificate name: Local Self-Signed"
