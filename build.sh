#!/bin/bash
set -e

PORT=8000
SINGBOX_VERSION="v1.13.13"
HOST_BIN_DIR="build/host"
BIN_DIR="build/staging/usr/bin"
VARS_FILE="build/user_vars.env"
LOCAL_IP=$( (ip -4 addr show 2>/dev/null || ifconfig 2>/dev/null) | grep -o '192\.168\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | head -n 1)

RUN_DEPLOY=true
for arg in "$@"; do
    if [[ "$arg" == "--no-deploy" ]]; then
        RUN_DEPLOY=false
        break
    fi
done

# Prerequisite Checks
for cmd in python3 expect go git upx; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64" ]]; then
    SB_ARCH="amd64"
elif [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    SB_ARCH="arm64"
else
    echo "Unsupported host architecture: $HOST_ARCH"
    exit 1
fi

if [[ "$HOST_OS" == "darwin" ]]; then
    SB_OS="darwin"
elif [[ "$HOST_OS" == "linux" ]]; then
    SB_OS="linux"
elif [[ "$HOST_OS" == "freebsd" || "$HOST_OS" == "openbsd" ]]; then
    SB_OS="freebsd"
else
    echo "Unsupported host OS: $HOST_OS"
    exit 1
fi

mkdir -p build/staging/{etc/sing-box,usr/bin} "$HOST_BIN_DIR"

if [[ -f "$VARS_FILE" ]]; then
    source "$VARS_FILE"
else
    read -p "Enter THE_CLEAN_CF_IPS: " THE_CLEAN_CF_IPS
    read -p "Enter THE_SNI: " THE_SNI
    read -p "Enter THE_UUID: " THE_UUID
    read -p "Enter SSH_USER_NAME: " SSH_USER_NAME
    read -p "Enter SSH_USER_PASSWORD: " SSH_USER_PASSWORD
    read -p "Enter SSH_ROOT_PASSWORD: " SSH_ROOT_PASSWORD

    # printf %q to safely escape variables for future sourcing
    {
        printf "THE_CLEAN_CF_IPS=%q\n" "$THE_CLEAN_CF_IPS"
        printf "THE_SNI=%q\n" "$THE_SNI"
        printf "THE_UUID=%q\n" "$THE_UUID"
        printf "SSH_USER_NAME=%q\n" "$SSH_USER_NAME"
        printf "SSH_USER_PASSWORD=%q\n" "$SSH_USER_PASSWORD"
        printf "SSH_ROOT_PASSWORD=%q\n" "$SSH_ROOT_PASSWORD"
    } >"$VARS_FILE"
fi
chmod 600 "$VARS_FILE"

escape() {
    printf '%s' "$1" | sed 's/[|\\&]/\\&/g'
}

template_copy() {
    sed -e "s|THE_CLEAN_CF_IPS|$(escape "$THE_CLEAN_CF_IPS")|g" \
        -e "s|THE_SNI|$(escape "$THE_SNI")|g" \
        -e "s|THE_UUID|$(escape "$THE_UUID")|g" \
        -e "s|HTTP_PORT|$(escape "$PORT")|g" \
        -e "s|LOCAL_IP|$(escape "$LOCAL_IP")|g" \
        -e "s|SSH_USER_NAME|$(escape "$SSH_USER_NAME")|g" \
        -e "s|SSH_USER_PASSWORD|$(escape "$SSH_USER_PASSWORD")|g" \
        -e "s|SSH_ROOT_PASSWORD|$(escape "$SSH_ROOT_PASSWORD")|g" \
        "$1" >"$2"
}

build_singbox_openwrt() {
    if [[ ! -f "$BIN_DIR/sing-box" ]]; then
        echo "Building OpenWrt sing-box from source ($SINGBOX_VERSION)..."

        mkdir -p tmp_src
        if [[ ! -d "tmp_src/sing-box" ]]; then
            # Clone the exact version specified
            git clone --branch "$SINGBOX_VERSION" --depth 1 https://github.com/SagerNet/sing-box.git tmp_src/sing-box
        fi

        local WORK_DIR=$(pwd)
        cd tmp_src/sing-box

        # Tags: with_utls as requested. badlinkname and tfogo_checklinkname0 are MANDATORY for Go 1.23+ compatibility.
        local TAGS="with_utls,badlinkname,tfogo_checklinkname0"

        # Linker flags: -s (strip symbol table) and -w (strip DWARF debugging info) radically reduce binary size.
        local LDFLAGS="-X 'internal/godebug.defaultGODEBUG=multipathtcp=0' -checklinkname=0 -s -w"

        echo "Cross-compiling for linux/arm64 (Optimized for Cortex-A55 / ARMv8.2 Crypto)..."

        # Set GOARM64 to target ARMv8.2-A and utilize hardware cryptography (aes, sha1, sha2)
        export GOARM64="v8.2,crypto"

        # CGO_ENABLED=0 guarantees a static binary. -trimpath removes host filesystem paths.
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -v -trimpath -tags "$TAGS" -ldflags "$LDFLAGS" -o "$WORK_DIR/$BIN_DIR/sing-box" ./cmd/sing-box

        echo "Compressing the binary with UPX..."
        # Use UPX with LZMA compression for maximum file size reduction
        upx --best --lzma "$WORK_DIR/$BIN_DIR/sing-box"

        cd "$WORK_DIR"
        rm -rf tmp_src
    fi
}

download_host_singbox() {
    if [[ ! -f "$HOST_BIN_DIR/sing-box" ]]; then
        local ver="${SINGBOX_VERSION#v}"
        local filename="sing-box-${ver}-${SB_OS}-${SB_ARCH}"
        local url="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/${filename}.tar.gz"

        echo "Downloading Host sing-box for validation..."
        mkdir -p tmp_host_singbox
        curl -fL -# -o tmp_host_singbox/sing-box.tar.gz "$url"
        tar -xzf tmp_host_singbox/sing-box.tar.gz -C tmp_host_singbox
        mv "tmp_host_singbox/${filename}/sing-box" "$HOST_BIN_DIR/sing-box"
        rm -rf tmp_host_singbox
    fi
}

# Execute build and download functions explicitly
build_singbox_openwrt
download_host_singbox

chmod +x "$BIN_DIR/sing-box"
[[ -f "$HOST_BIN_DIR/sing-box" ]] && chmod +x "$HOST_BIN_DIR/sing-box"

template_copy src/deploy.sh build/deploy.sh
template_copy src/rc.local build/staging/etc/rc.local

echo -e "\nGenerating dynamic sing-box JSON config..."
# Export variables to the environment so Python can securely pull them
export THE_CLEAN_CF_IPS THE_SNI THE_UUID
python3 src/generate_config.py

chmod 700 build/deploy.sh build/staging/etc/rc.local

echo -e "\nValidating configurations..."
if [[ -f "$HOST_BIN_DIR/sing-box" ]]; then
    "$HOST_BIN_DIR/sing-box" check -c build/staging/etc/sing-box/config.json
    echo "[OK] sing-box configuration is valid."
fi

echo -e "\nPackaging sysupgrade archive natively..."
# Force root ownership if using GNU tar (Linux), while preserving the exact './' OpenWrt path structure
if tar --version 2>/dev/null | grep -q GNU; then
    tar --owner=0 --group=0 -czf build/sysupgrade_backup.tgz -C build/staging .
else
    tar -czf build/sysupgrade_backup.tgz -C build/staging .
fi
chmod 600 build/sysupgrade_backup.tgz

# Start Python HTTP Server in the background serving the 'build' directory
echo -e "\nStarting Python web server on port $PORT..."
(cd build && python3 -m http.server "$PORT" >/dev/null 2>&1) &
WEBSERVER_PID=$!

# Ensure the webserver gets killed upon exit (even if the script errors out)
trap "echo -e '\nStopping Python web server...'; kill $WEBSERVER_PID 2>/dev/null" EXIT

sleep 2
if [ "$RUN_DEPLOY" = true ]; then
    echo -e "\n================================================================"
    echo "Deploying on your router..."
    echo -e "================================================================"
    ./build/deploy.sh
    echo -e "================================================================"
    echo "[OK] Deployment successfully completed."
else
    echo -e "\n================================================================"
    echo "Build complete. Skipping deployment due to --no-deploy flag."
    echo "================================================================"
fi

exit 0
