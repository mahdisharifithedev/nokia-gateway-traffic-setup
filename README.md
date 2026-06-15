# Nokia Fastmile 3.2 Gateway 5G - Traffic Routing Setup

An automated, educational project for managing and manipulating network traffic on the Nokia Fastmile 3.2 Gateway 5G (and similar OpenWrt-based environments). This project provides a complete toolchain to cross-compile, configure, package, and deploy a custom `sing-box` routing environment directly to the router.

> **Note:** This project is intended strictly for educational purposes to demonstrate advanced network administration, automated cross-compiling, packet marking via `iptables`, and TUN interface routing.

## Features

* **Automated Cross-Compilation:** Dynamically fetches and builds `sing-box` from source, specifically optimized for `linux/arm64` (Cortex-A55 / ARMv8.2 Crypto).
* **Dynamic Configuration Generation:** Parses user inputs to generate a tailored `sing-box.json` utilizing VLESS, WebSockets, and URLTest for multi-IP high availability.
* **Zero-Touch Deployment:** Packages the compiled binaries and configuration into an OpenWrt-compatible `sysupgrade.tgz` archive and automates router deployment via an SSH `expect` script.
* **Advanced Traffic Manipulation:** Utilizes custom `rc.local` startup scripts to deploy `iptables`/`ip6tables` connection marking (CONNMARK), `sysctl` TCP optimizations (e.g., fq_codel, tcp_fastopen), and hardware offloading management.
* **Custom SNI Routing:** Demonstrates TLS client hello manipulation and sequence routing for educational packet inspection studies.

## Prerequisites

Before running the build script, ensure your host machine (Linux/macOS/BSD) has the following system dependencies installed:

* **Python 3.x**
* **Go** (`go`) - For cross-compiling the `sing-box` binary.
* **Git** (`git`) - To fetch the `sing-box` source code.
* **UPX** (`upx`) - To compress the final executable.
* **Expect** (`expect`) - For automating the SSH deployment phase.

You will also need SSH access to your Nokia Fastmile 3.2 Gateway with root privileges.

## Project Structure

* `build.py`: The core orchestration script. Handles dependency checks, variable prompting, cross-compilation, configuration templating, archiving, and initiating deployment.
* `src/sing-box.json`: The base template for the `sing-box` routing configuration. Uses a TUN inbound and VLESS outbound over WebSockets.
* `src/deploy.sh`: An `expect` script template that handles the automated SSH login, file transfer, and reboot sequence on the target router.
* `src/rc.local`: The router startup script. It restores the `sysupgrade` archive, sets kernel/firewall parameters, starts the proxy, and applies necessary `iptables` routing marks.

## Usage Guide

### 1. Clone and Prepare
Ensure you are in the root directory of the project.
### 2. Run the Build Pipeline
Execute the main build script:
```bash
python3 build.py
```
### 3. Enter Configuration Variables
On the first run, the script will securely prompt you for your network variables (these will be saved locally to build/user_vars.json with a UNIX 600 permission):

- `THE_CLEAN_CF_IPS`: A comma-separated list of destination IPs.
- `THE_SNI`: Your Server Name Indication target.
- `THE_UUID`: Your VLESS UUID.
- `THE_FAKE_SNI`: (Optional) Custom SNI payload for traffic testing.
- `SSH_USER_NAME`, `SSH_USER_PASSWORD`, `SSH_ROOT_PASSWORD`: Router credentials for automated deployment.

### 4. Deployment Phase
Once compiled and packaged, the script spins up an ephemeral Python HTTP server on port 8000. The expect script then logs into your router, pulls the sysupgrade_backup.tgz archive via wget, places it in /data/, and reboots the gateway to apply the new state.

Local Testing Only (Skip Deployment)
If you only want to build the configuration and binaries locally to inspect the output without pushing to your router, append the --no-deploy flag:
```bash
python3 build.py --no-deploy
```

## How It Works (Technical Overview)

1. Host Detection & Build: The script detects your host OS/Architecture to download a local validation binary. It then sets up a cross-compilation toolchain targeting linux/arm64 and compiles the sing-box binary, stripping debugging symbols and compressing it with upx to save space on the router's limited flash memory.
2. Config Synthesis: It injects your variables into sing-box.json. If multiple IPs are provided, it automatically configures a urltest outbound group to load balance and measure latency across the provided endpoints.
3. Startup Injection: The rc.local file is populated with your deployment logic. Upon router reboot, rc.local extracts the custom system state, configures sysctl for optimal TCP queueing (fq_codel), clears large proxy cache files to prevent memory exhaustion, and maps specific iptables marks (202) to ensure tunneled traffic does not loop.
4. Verification: Before packaging, the host sing-box binary performs a dry-run syntax check on the generated JSON configuration to prevent bricking the router's network stack with invalid rules.

## License
This project is licensed under the MIT License. See the LICENSE file in the root directory for more information.