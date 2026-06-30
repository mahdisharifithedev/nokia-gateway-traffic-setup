#!/usr/bin/env python3

import os
import sys
import json
import shutil
import socket
import getpass
import platform
import subprocess
import urllib.request
import tarfile
import threading
import http.server
import socketserver
import copy
from pathlib import Path

PORT = 8000
HOST_BIN_DIR = "build/host"
BIN_DIR = "build/staging/usr/bin"
VARS_FILE = "build/user_vars.json"
SINGBOX_VERSION = "v1.14.0-alpha.37"

def get_local_ip():
    """Fetches the local IPv4 address."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.255.255.255", 1))
            return s.getsockname()[0]
        except Exception:
            return "127.0.0.1"

def check_dependencies():
    """Ensures required system binaries are installed."""
    missing = []
    for cmd in ['expect', 'go', 'git', 'upx']:
        if not shutil.which(cmd):
            missing.append(cmd)
    if missing:
        print(f"Error: Missing required system dependencies: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

def get_host_info():
    """Detects host OS and architecture mapping them to sing-box nomenclature."""
    sys_name = platform.system().lower()
    mach = platform.machine().lower()

    if mach in ('x86_64', 'amd64'):
        sb_arch = 'amd64'
    elif mach in ('aarch64', 'arm64'):
        sb_arch = 'arm64'
    else:
        print(f"Error: Unsupported architecture: {mach}", file=sys.stderr)
        sys.exit(1)

    if sys_name == 'darwin':
        sb_os = 'darwin'
    elif sys_name == 'linux':
        sb_os = 'linux'
    elif sys_name in ('freebsd', 'openbsd'):
        sb_os = 'freebsd'
    else:
        print(f"Error: Unsupported OS: {sys_name}", file=sys.stderr)
        sys.exit(1)

    return sb_os, sb_arch

def load_or_prompt_vars():
    """Loads variables from JSON or securely prompts the user."""
    vars_dict = {}
    if os.path.exists(VARS_FILE):
        try:
            with open(VARS_FILE, 'r') as f:
                vars_dict = json.load(f)
        except json.JSONDecodeError:
            pass
            
    required_keys = [
        ('THE_CLEAN_CF_IPS', False),
        ('THE_SNI', False),
        ('THE_UUID', False),
        ('SSH_USER_NAME', False),
        ('SSH_USER_PASSWORD', True),
        ('SSH_ROOT_PASSWORD', True)
    ]

    needs_save = False
    for key, is_secret in required_keys:
        if key not in vars_dict or not vars_dict[key]:
            if is_secret:
                vars_dict[key] = getpass.getpass(f"Enter {key}: ")
            else:
                vars_dict[key] = input(f"Enter {key}: ")
            needs_save = True

    if 'THE_FAKE_SNI' not in vars_dict:
        vars_dict['THE_FAKE_SNI'] = input("Enter THE_FAKE_SNI (leave blank to disable spoofing): ")
        needs_save = True

    if needs_save:
        with open(VARS_FILE, 'w') as f:
            json.dump(vars_dict, f, indent=4)
        os.chmod(VARS_FILE, 0o600)
        
    return vars_dict

def template_copy(src, dest, replacements):
    """Reads a template, applies exact string replacements securely, and writes out."""
    with open(src, 'r') as f:
        content = f.read()
    for key, val in replacements.items():
        content = content.replace(key, str(val))
    with open(dest, 'w') as f:
        f.write(content)

def make_executable(path):
    """Cross-platform equivalent of chmod +x"""
    mode = os.stat(path).st_mode
    mode |= (mode & 0o444) >> 2    # copy R bits to X
    os.chmod(path, mode)


def build_openwrt_singbox():
    """Clones, cross-compiles, and compresses sing-box for the OpenWrt router."""
    bin_path = os.path.join(BIN_DIR, "sing-box")
    if os.path.isfile(bin_path):
        return

    print(f"\nBuilding OpenWrt sing-box from source ({SINGBOX_VERSION})...")
    os.makedirs("tmp_src", exist_ok=True)
    repo_dir = os.path.abspath("tmp_src/sing-box")
    
    if not os.path.isdir(repo_dir):
        subprocess.run(
            ["git", "clone", "--branch", SINGBOX_VERSION, "--depth", "1", 
             "https://github.com/SagerNet/sing-box.git", repo_dir],
            check=True
        )

    env = os.environ.copy()
    env["CGO_ENABLED"] = "0"
    env["GOOS"] = "linux"
    env["GOARCH"] = "arm64"
    env["GOARM64"] = "v8.2,crypto"

    tags = "with_utls,badlinkname,tfogo_checklinkname0"
    ldflags = "-X 'internal/godebug.defaultGODEBUG=multipathtcp=0' -checklinkname=0 -s -w"

    print("Cross-compiling for linux/arm64 (Optimized for Cortex-A55 / ARMv8.2 Crypto)...")
    subprocess.run(
        ["go", "build", "-v", "-trimpath", "-tags", tags, "-ldflags", ldflags, "-o", os.path.abspath(bin_path), "./cmd/sing-box"],
        cwd=repo_dir, env=env, check=True
    )

    print("Compressing the binary with UPX...")
    subprocess.run(["upx", "--best", "--lzma", os.path.abspath(bin_path)], check=True)
    shutil.rmtree("tmp_src")

def download_host_singbox(sb_os, sb_arch):
    """Downloads the native pre-compiled sing-box binary to validate configs locally."""
    host_bin = os.path.join(HOST_BIN_DIR, "sing-box")
    if os.path.isfile(host_bin):
        return

    print("\nDownloading Host sing-box for validation...")
    ver = SINGBOX_VERSION.lstrip('v')
    filename = f"sing-box-{ver}-{sb_os}-{sb_arch}"
    url = f"https://github.com/SagerNet/sing-box/releases/download/{SINGBOX_VERSION}/{filename}.tar.gz"

    tar_path = "tmp_host_singbox.tar.gz"
    urllib.request.urlretrieve(url, tar_path)

    with tarfile.open(tar_path, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name.endswith("sing-box") and not member.isdir():
                member.name = os.path.basename(member.name)
                tar.extract(member, path=HOST_BIN_DIR)
                break

    os.remove(tar_path)

def generate_config(vars_dict):
    """Generates the dynamic sing-box config JSON based on user variables."""
    input_file = 'src/sing-box.json'
    output_file = 'build/staging/etc/sing-box/config.json'

    with open(input_file, 'r') as f:
        config = json.load(f)

    ips = [ip.strip() for ip in vars_dict['THE_CLEAN_CF_IPS'].split(',') if ip.strip()]
    sni = vars_dict['THE_SNI']
    uuid = vars_dict['THE_UUID']
    fake_sni = vars_dict.get('THE_FAKE_SNI', '').strip()

    outbounds = config.get('outbounds', [])
    vless_template = next((ob for ob in outbounds if ob.get('type') == 'vless' and ob.get('tag') == 'out-proxy'), None)
    urltest_template = next((ob for ob in outbounds if ob.get('type') == 'urltest' and ob.get('tag') == 'template-urltest'), None)
    
    other_outbounds = [ob for ob in outbounds if ob != vless_template and ob != urltest_template]

    if vless_template:
        def populate_vless_node(node_template, ip_addr, tag_name):
            node = copy.deepcopy(node_template)
            node['tag'] = tag_name
            node['server'] = ip_addr
            
            if 'uuid' in node: 
                node['uuid'] = uuid
            if 'tls' in node:
                if 'server_name' in node['tls']:
                    node['tls']['server_name'] = sni
                if fake_sni:
                    node['tls']['spoof'] = fake_sni
                else:
                    node['tls'].pop('spoof', None)
                    node['tls'].pop('spoof_method', None)
                    
            if 'transport' in node and 'headers' in node['transport'] and 'Host' in node['transport']['headers']:
                node['transport']['headers']['Host'] = sni
                
            return node

        if len(ips) == 1:
            # Single IP: Skip urltest, use VLESS directly as the main proxy
            single_node = populate_vless_node(vless_template, ips[0], 'out-proxy')
            config['outbounds'] = [single_node] + other_outbounds
        elif len(ips) > 1 and urltest_template:
            # Multiple IPs: Generate VLESS nodes and link them via the urltest template
            vless_nodes = []
            vless_tags = []
            for i, ip in enumerate(ips):
                tag = f"vless-cf-{i}"
                vless_tags.append(tag)
                vless_nodes.append(populate_vless_node(vless_template, ip, tag))

            urltest = copy.deepcopy(urltest_template)
            urltest['tag'] = 'urltest' # Assign a distinct, accurate tag
            urltest['outbounds'] = vless_tags
            
            config['outbounds'] = [urltest] + vless_nodes + other_outbounds

            for server in config.get('dns', {}).get('servers', []):
                if server.get('detour') == 'out-proxy':
                    server['detour'] = 'urltest'

            for rule in config.get('route', {}).get('rules', []):
                if rule.get('outbound') == 'out-proxy':
                    rule['outbound'] = 'urltest'

    rules = config.get('route', {}).get('rules', [])
    for rule in rules:
        if 'ip_cidr' in rule and isinstance(rule['ip_cidr'], list):
            if 'THE_CLEAN_CF_IP/32' in rule['ip_cidr']:
                rule['ip_cidr'].remove('THE_CLEAN_CF_IP/32')
                rule['ip_cidr'].extend([f"{ip}/32" for ip in ips])

    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(config, f, indent=4)

    print(f"\n[OK] Generated dynamic sing-box JSON configuration at {output_file}")


def main():
    run_deploy = "--no-deploy" not in sys.argv

    check_dependencies()
    sb_os, sb_arch = get_host_info()
    local_ip = get_local_ip()

    for d in ["build/staging/etc/sing-box", "build/staging/usr/bin", HOST_BIN_DIR]:
        os.makedirs(d, exist_ok=True)

    vars_dict = load_or_prompt_vars()

    build_openwrt_singbox()
    download_host_singbox(sb_os, sb_arch)
    make_executable(os.path.join(BIN_DIR, "sing-box"))
    make_executable(os.path.join(HOST_BIN_DIR, "sing-box"))

    replacements = copy.copy(vars_dict)
    replacements.update({"HTTP_PORT": PORT, "LOCAL_IP": local_ip})
    
    template_copy('src/deploy.sh', 'build/deploy.sh', replacements)
    template_copy('src/rc.local', 'build/staging/etc/rc.local', replacements)
    make_executable('build/deploy.sh')
    make_executable('build/staging/etc/rc.local')

    generate_config(vars_dict)

    print("\nValidating configurations...")
    val_proc = subprocess.run(
        [os.path.join(HOST_BIN_DIR, "sing-box"), "check", "-c", "build/staging/etc/sing-box/config.json"],
        capture_output=True, text=True
    )
    if val_proc.returncode == 0:
        print("[OK] sing-box configuration is valid.")
    else:
        print(f"Error: Invalid sing-box configuration!\n{val_proc.stderr}", file=sys.stderr)
        sys.exit(1)

    def reset_tar_info(tarinfo):
        tarinfo.uid = tarinfo.gid = 0
        tarinfo.uname = tarinfo.gname = "root"
        return tarinfo

    print("\nPackaging sysupgrade archive natively...")
    tgz_path = "build/sysupgrade_backup.tgz"
    with tarfile.open(tgz_path, "w:gz") as tar:
        tar.add("build/staging", arcname=".", filter=reset_tar_info)
    os.chmod(tgz_path, 0o600)

    if not run_deploy:
        print("\n================================================================")
        print("Build complete. Skipping deployment due to --no-deploy flag.")
        print("================================================================")
        return

    print(f"\nStarting Python web server on port {PORT}...")
    class SilentHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args): pass # Silence HTTP logs
        
    os.chdir("build") # Serve from 'build' directory
    httpd = socketserver.TCPServer(("", PORT), SilentHandler)
    httpd.allow_reuse_address = True
    
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()

    print("\n================================================================")
    print("Deploying on your router...")
    print("================================================================")
    try:
        subprocess.run(["expect", "-f", "deploy.sh"], check=True)
        print("================================================================")
        print("[OK] Deployment successfully completed.")
    except subprocess.CalledProcessError:
        print("[ERROR] Deployment failed.", file=sys.stderr)
    except KeyboardInterrupt:
        print("\n[INFO] Deployment interrupted by user.")
    finally:
        print("Stopping Python web server...")
        httpd.shutdown()
        httpd.server_close()

if __name__ == "__main__":
    main()