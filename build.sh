#!/bin/bash
set -e

PORT=8000
SINGBOX_VERSION="v1.12.22"
NAIVE_VERSION="v143.0.7499.109-2"
HOST_BIN_DIR="build/host"
BIN_DIR="build/staging/usr/bin"
VARS_FILE="build/user_vars.env"
LOCAL_IP=$( (ip -4 addr show 2>/dev/null || ifconfig 2>/dev/null) | grep -o '192\.168\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | head -n 1 )

if ! command -v expect >/dev/null 2>&1; then
  echo "Error: expect is not installed."
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "Error: node is not installed. Please install Node.js."
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "Error: npm is not installed. Please install Node.js/npm."
  exit 1
fi
if ! command -v http-server >/dev/null 2>&1; then
  echo "Error: http-server is not installed globally."
  echo "Please run: npm install -g http-server@latest"
  exit 1
fi

HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64" ]]; then
  SB_ARCH="amd64"
  NAIVE_ARCH="x64"
elif [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  SB_ARCH="arm64"
  NAIVE_ARCH="arm64"
else
  echo "Unsupported host architecture: $HOST_ARCH"
  exit 1
fi

if [[ "$HOST_OS" == "darwin" ]]; then
  SB_OS="darwin"
  NAIVE_OS="mac"
elif [[ "$HOST_OS" == "linux" ]]; then
  SB_OS="linux"
  NAIVE_OS="linux"
elif [[ "$HOST_OS" == "freebsd" || "$HOST_OS" == "openbsd" ]]; then
  SB_OS="freebsd"
  NAIVE_OS="linux" # NaiveProxy has no official BSD release; handled below
else
  echo "Unsupported host OS: $HOST_OS"
  exit 1
fi

mkdir -p build/staging/{etc/naive,etc/sing-box,usr/bin} "$HOST_BIN_DIR"

if [[ -f "$VARS_FILE" ]]; then
  source "$VARS_FILE"
else
  read -p "Enter DOMAIN_IPV4: " DOMAIN_IPV4
  read -p "Enter DOMAIN_IPV6: " DOMAIN_IPV6
  read -p "Enter THE_DOMAIN: " THE_DOMAIN
  read -p "Enter NAIVE_USER: " NAIVE_USER
  read -p "Enter NAIVE_PASSWORD: " NAIVE_PASSWORD
  read -p "Enter SSH_USER_NAME: " SSH_USER_NAME
  read -p "Enter SSH_USER_PASSWORD: " SSH_USER_PASSWORD
  read -p "Enter SSH_ROOT_PASSWORD: " SSH_ROOT_PASSWORD

  # printf %q to safely escape variables for future sourcing
  {
    printf "DOMAIN_IPV4=%q\n" "$DOMAIN_IPV4"
    printf "DOMAIN_IPV6=%q\n" "$DOMAIN_IPV6"
    printf "THE_DOMAIN=%q\n" "$THE_DOMAIN"
    printf "NAIVE_USER=%q\n" "$NAIVE_USER"
    printf "NAIVE_PASSWORD=%q\n" "$NAIVE_PASSWORD"
    printf "SSH_USER_NAME=%q\n" "$SSH_USER_NAME"
    printf "SSH_USER_PASSWORD=%q\n" "$SSH_USER_PASSWORD"
    printf "SSH_ROOT_PASSWORD=%q\n" "$SSH_ROOT_PASSWORD"
  } > "$VARS_FILE"
fi
chmod 600 $VARS_FILE

escape() {
  printf '%s' "$1" | sed 's/[|\\&]/\\&/g'
}

template_copy() {
  sed -e "s|DOMAIN_IPV4|$(escape "$DOMAIN_IPV4")|g" \
      -e "s|DOMAIN_IPV6|$(escape "$DOMAIN_IPV6")|g" \
      -e "s|THE_DOMAIN|$(escape "$THE_DOMAIN")|g" \
      -e "s|NAIVE_USER|$(escape "$NAIVE_USER")|g" \
      -e "s|NAIVE_PASSWORD|$(escape "$NAIVE_PASSWORD")|g" \
      -e "s|HTTP_PORT|$(escape "$PORT")|g" \
      -e "s|LOCAL_IP|$(escape "$LOCAL_IP")|g" \
      -e "s|SSH_USER_NAME|$(escape "$SSH_USER_NAME")|g" \
      -e "s|SSH_USER_PASSWORD|$(escape "$SSH_USER_PASSWORD")|g" \
      -e "s|SSH_ROOT_PASSWORD|$(escape "$SSH_ROOT_PASSWORD")|g" \
      "$1" > "$2"
}

download_naive() {
  if [[ ! -f "$BIN_DIR/naive" ]]; then
    local filename="naiveproxy-${NAIVE_VERSION}-openwrt-aarch64_generic-static"
    local url="https://github.com/klzgrad/naiveproxy/releases/download/${NAIVE_VERSION}/${filename}.tar.xz"
    
    echo "Downloading OpenWrt NaiveProxy..."
    mkdir -p tmp_naive
    curl -fL -# -o tmp_naive/naive.tar.xz "$url"
    tar -xf tmp_naive/naive.tar.xz -C tmp_naive
    mv "tmp_naive/${filename}/naive" "$BIN_DIR/naive"
    rm -rf tmp_naive
  fi
}

download_singbox() {
  if [[ ! -f "$BIN_DIR/sing-box" ]]; then
    local ver="${SINGBOX_VERSION#v}"
    local filename="sing-box_${ver}_openwrt_aarch64_generic.ipk"
    local url="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/${filename}"
    
    echo "Downloading OpenWrt sing-box..."
    mkdir -p tmp_singbox
    curl -fL -# -o tmp_singbox/sing-box.ipk "$url"
    tar -xf tmp_singbox/sing-box.ipk -C tmp_singbox
    tar -xf tmp_singbox/data.tar.* -C tmp_singbox
    mv tmp_singbox/usr/bin/sing-box "$BIN_DIR/sing-box"
    rm -rf tmp_singbox
  fi
}

download_host_naive() {
  if [[ "$HOST_OS" == "freebsd" || "$HOST_OS" == "openbsd" ]]; then
    echo "Skipping Host NaiveProxy (no official BSD builds available)."
    return 0
  fi

  if [[ ! -f "$HOST_BIN_DIR/naive" ]]; then
    local filename="naiveproxy-${NAIVE_VERSION}-${NAIVE_OS}-${NAIVE_ARCH}"
    local url="https://github.com/klzgrad/naiveproxy/releases/download/${NAIVE_VERSION}/${filename}.tar.xz"
    
    echo "Downloading Host NaiveProxy for validation..."
    mkdir -p tmp_host_naive
    curl -fL -# -o tmp_host_naive/naive.tar.xz "$url"
    tar -xf tmp_host_naive/naive.tar.xz -C tmp_host_naive
    mv "tmp_host_naive/${filename}/naive" "$HOST_BIN_DIR/naive"
    rm -rf tmp_host_naive
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

download_naive
download_singbox
download_host_naive
download_host_singbox

chmod +x "$BIN_DIR/naive" "$BIN_DIR/sing-box"
[[ -f "$HOST_BIN_DIR/naive" ]] && chmod +x "$HOST_BIN_DIR/naive"
[[ -f "$HOST_BIN_DIR/sing-box" ]] && chmod +x "$HOST_BIN_DIR/sing-box"

template_copy src/deploy.sh build/deploy.sh
template_copy src/rc.local build/staging/etc/rc.local
template_copy src/naive.json build/staging/etc/naive/config.json
template_copy src/sing-box.json build/staging/etc/sing-box/config.json

chmod 700 build/deploy.sh build/staging/etc/rc.local          
chmod 600 build/staging/etc/naive/config.json build/staging/etc/sing-box/config.json

echo -e "\nValidating configurations..."
if [[ -f "$HOST_BIN_DIR/sing-box" ]]; then
  "$HOST_BIN_DIR/sing-box" check -c build/staging/etc/sing-box/config.json
  echo "[OK] sing-box configuration is valid."
fi

if [[ -f "$HOST_BIN_DIR/naive" ]]; then
  # Create a temporary file to capture output
  NAIVE_LOG=$(mktemp)
  
  # Redirect stdout and stderr to the log file
  "$HOST_BIN_DIR/naive" build/staging/etc/naive/config.json > "$NAIVE_LOG" 2>&1 &
  NAIVE_PID=$!
  disown $NAIVE_PID # Stop bash from monitoring this job for a silent kill
  sleep 2
  
  if kill -0 $NAIVE_PID 2>/dev/null; then
    kill $NAIVE_PID 2>/dev/null
    echo "[OK] NaiveProxy configuration is valid."
  else
    echo "[ERROR] NaiveProxy configuration is invalid! Output log below:"
    echo "============================================================"
    cat "$NAIVE_LOG"
    echo "============================================================"
    rm -f "$NAIVE_LOG"
    exit 1
  fi
  
  rm -f "$NAIVE_LOG"
fi

tar -czf build/sysupgrade_backup.tgz -C build/staging .
chmod 600 build/sysupgrade_backup.tgz

echo -e "\n================================================================"
echo "Deploy on your router with this commmand in another terminal:"
echo "================================================================"
echo "./build/deploy.sh"
echo -e "================================================================"
echo "Hit Crtl+C after the finish to end this script."
echo "================================================================"

http-server build -p "$PORT"