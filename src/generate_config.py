#!/usr/bin/env python3

import json
import os
import copy
import sys

# 1. Parse inputs from environment variables
ips_env = os.environ.get('THE_CLEAN_CF_IPS', '')
if not ips_env:
    print("Error: THE_CLEAN_CF_IPS environment variable is missing or empty.", file=sys.stderr)
    sys.exit(1)

ips = [ip.strip() for ip in ips_env.split(',') if ip.strip()]
sni = os.environ.get('THE_SNI', '')
uuid = os.environ.get('THE_UUID', '')

input_file = 'src/sing-box.json'
output_file = 'build/staging/etc/sing-box/config.json'

try:
    with open(input_file, 'r') as f:
        config = json.load(f)
except FileNotFoundError:
    print(f"Error: Could not find template at {input_file}", file=sys.stderr)
    sys.exit(1)

# 2. Rebuild Outbounds
outbounds = config.get('outbounds', [])
vless_template = next((ob for ob in outbounds if ob.get('tag') == 'out-proxy'), None)
other_outbounds = [ob for ob in outbounds if ob.get('tag') != 'out-proxy']

if vless_template:
    vless_nodes = []
    vless_tags = []

    # Generate an individual VLESS node for each IP securely via object assignment
    for i, ip in enumerate(ips):
        tag = f"vless-cf-{i}"
        vless_tags.append(tag)
        
        node = copy.deepcopy(vless_template)
        node['tag'] = tag
        node['server'] = ip
        
        # Robustly inject SNI and UUID directly into the JSON dictionary
        if 'uuid' in node:
            node['uuid'] = uuid
        
        if 'tls' in node and 'server_name' in node['tls']:
            node['tls']['server_name'] = sni
            
        if 'transport' in node and 'headers' in node['transport'] and 'Host' in node['transport']['headers']:
            node['transport']['headers']['Host'] = sni

        vless_nodes.append(node)

    # Create the urltest load balancer
    urltest = {
        "type": "urltest",
        "tag": "out-proxy",
        "outbounds": vless_tags,
        "url": "https://cp.cloudflare.com/generate_204",
        "interval": "30s",
        "tolerance": 50
    }

    # Replace the outbounds array entirely
    config['outbounds'] = [urltest] + vless_nodes + other_outbounds

# 3. Update routing rules robustly
rules = config.get('route', {}).get('rules', [])
for rule in rules:
    if 'ip_cidr' in rule:
        # Locate the specific bypass rule and replace it cleanly
        if 'THE_CLEAN_CF_IP/32' in rule['ip_cidr']:
            rule['ip_cidr'].remove('THE_CLEAN_CF_IP/32')
            # Inject all clean IPs as /32 CIDR arrays
            rule['ip_cidr'].extend([f"{ip}/32" for ip in ips])

# 4. Save the finalized JSON
os.makedirs(os.path.dirname(output_file), exist_ok=True)
with open(output_file, 'w') as f:
    json.dump(config, f, indent=4)

print(f"[OK] Generated dynamic sing-box JSON configuration at {output_file}")