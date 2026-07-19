#!/usr/bin/env bash
# Setup stable development code signing to reduce keychain prompts
set -euo pipefail

echo "🔐 Setting up stable development code signing..."
echo ""
echo "This will create a self-signed certificate that stays consistent across rebuilds,"
echo "reducing keychain permission prompts."
echo ""

# Check if we already have a CodexBar development certificate
CERT_NAME="CodexBar Development"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✅ Certificate '$CERT_NAME' already exists!"
    echo ""
    echo "To use it, add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "    export APP_IDENTITY='$CERT_NAME'"
    echo ""
    echo "Then restart your terminal and rebuild with ./Scripts/compile_and_run.sh"
    exit 0
fi

echo "Creating self-signed certificate '$CERT_NAME'..."
echo ""

# Create a temporary config file for the certificate
TEMP_CONFIG=$(mktemp)
trap "rm -f $TEMP_CONFIG" EXIT

cat > "$TEMP_CONFIG" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $CERT_NAME
O = CodexBar Development
C = US

[ v3_req ]
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF

# Generate the certificate
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
    -nodes -keyout /tmp/codexbar-dev.key -out /tmp/codexbar-dev.crt \
    -config "$TEMP_CONFIG" 2>/dev/null

# Convert to PKCS12 format
openssl pkcs12 -export -out /tmp/codexbar-dev.p12 \
    -inkey /tmp/codexbar-dev.key -in /tmp/codexbar-dev.crt \
    -passout pass: 2>/dev/null

# Import into keychain
security import /tmp/codexbar-dev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -T /usr/bin/security

# Clean up temporary files
rm -f /tmp/codexbar-dev.{key,crt,p12}

echo ""
echo "✅ Certificate created successfully!"
echo ""
echo "⚠️  IMPORTANT: You need to trust this certificate for code signing:"
echo ""
echo "1. Open Keychain Access.app"
echo "2. Find '$CERT_NAME' in the 'login' keychain"
echo "3. Double-click it"
echo "4. Expand 'Trust' section"
echo "5. Set 'Code Signing' to 'Always Trust'"
echo "6. Close the window (enter your password when prompted)"
echo ""
echo "Then add this to your shell profile (~/.zshrc or ~/.bashrc):"
echo ""
echo "    export APP_IDENTITY='$CERT_NAME'"
echo ""
echo "Restart your terminal and rebuild with ./Scripts/compile_and_run.sh"

