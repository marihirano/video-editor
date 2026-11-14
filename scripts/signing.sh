#!/bin/zsh
# A stable signature for the app, so macOS remembers the screen recording permission across rebuilds.
#
# macOS ties privacy permissions to the app's signature. An "ad-hoc" signature changes with every build,
# so the permission would be asked for again each time. Instead, this makes one self-made signing
# certificate ("Video Editor Local Signing") the first time it runs, and keeps it in its own keychain file
# (~/Library/Keychains/video-editor-signing.keychain-db) used only for this. Nothing is trusted or
# installed system-wide, and no Apple developer account is needed. The app only runs on this Mac.
#
# Sourced by build-app.sh; sets SIGN_IDENTITY (or leaves it empty → ad-hoc).
SIGN_NAME="Video Editor Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/video-editor-signing.keychain-db"
SIGN_PASS="video-editor-local"   # protects only this throwaway signing key on this Mac
SIGN_IDENTITY=""

make_identity() {
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null || return 1
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_NAME" \
        -out "$tmp/id.p12" -passout pass:"$SIGN_PASS" 2>/dev/null || return 1
    security create-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN" || return 1
    security set-keychain-settings "$SIGN_KEYCHAIN"   # don't lock itself after a timeout
    security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"
    security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P "$SIGN_PASS" -T /usr/bin/codesign >/dev/null || return 1
    security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGN_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1
    rm -rf "$tmp"
}

if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
    echo "Making the app's signing certificate (first build only)…"
    make_identity || { echo "Couldn't make a signing certificate; using an ad-hoc signature."; rm -f "$SIGN_KEYCHAIN"; }
fi
if [[ -f "$SIGN_KEYCHAIN" ]]; then security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN" 2>/dev/null; fi

# Which signature to use, best first:
# 1. An "Apple Development" certificate (made by Xcode after signing in with an Apple ID, free).
SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
# 2. The self-made certificate above. codesign only finds it once its keychain is on your keychain list,
#    which you do once (it changes your keychain settings, so the script never does it by itself):
#      security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') ~/Library/Keychains/video-editor-signing.keychain-db
if [[ -z "$SIGN_IDENTITY" ]] && security list-keychains -d user | grep -q "video-editor-signing"; then
    SIGN_IDENTITY="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/'"$SIGN_NAME"'/ {print $2; exit}')"
fi
# 3. Otherwise empty: build-app.sh signs ad-hoc.
