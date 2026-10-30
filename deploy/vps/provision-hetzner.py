#!/usr/bin/env python3
"""Create a Hetzner Cloud server that installs itself with bootstrap.sh, point a
Cloudflare DNS record at it and wait until the deploy reports (deploy/vps/README.md).

Reads HCLOUD_TOKEN (Read & Write) and CLOUDFLARE_API_TOKEN (Zone DNS Edit on the
zone) from the environment. Without --yes it only prints the plan and the price.
"""
import argparse
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.request

HCLOUD = "https://api.hetzner.cloud/v1"
CLOUDFLARE = "https://api.cloudflare.com/client/v4"


def call(base, token, method, path, body=None):
    request = urllib.request.Request(
        base + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {base}{path}: {error.code} {error.read().decode(errors='replace')[:500]}")


def need_env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"{name} is not set")
    return value


def raw_url(repo, ref):
    match = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repo)
    if not match:
        sys.exit(f"--repo must be a https://github.com/OWNER/REPO URL, got {repo}")
    return f"https://raw.githubusercontent.com/{match[1]}/{match[2]}/{ref}/deploy/vps/bootstrap.sh"


def user_data(args):
    command = ["bash", "/root/omb-bootstrap.sh", "--domain", args.domain, "--repo", args.repo,
               "--ref", args.ref, "--auto-update"]
    if args.signin_emails:
        command += ["--signin-emails", args.signin_emails]
    script = (f"curl -fsSL {shlex.quote(raw_url(args.repo, args.ref))} -o /root/omb-bootstrap.sh && "
              + shlex.join(command)
              + " > /var/log/omb-bootstrap.log 2>&1")
    return "#cloud-config\nssh_pwauth: false\nruncmd:\n  - " + json.dumps(["bash", "-c", script]) + "\n"


def monthly_price(token, server_type, location):
    types = call(HCLOUD, token, "GET", f"/server_types?name={server_type}")["server_types"]
    if not types:
        sys.exit(f"unknown server type {server_type}")
    for price in types[0]["prices"]:
        if price["location"] == location:
            return types[0], price["price_monthly"]["gross"]
    sys.exit(f"{server_type} is not offered in {location}")


def ensure_firewall(token, name):
    existing = call(HCLOUD, token, "GET", f"/firewalls?name={name}")["firewalls"]
    if existing:
        return existing[0]["id"]
    anywhere = ["0.0.0.0/0", "::/0"]
    rules = [{"direction": "in", "protocol": "icmp", "source_ips": anywhere}]
    rules += [{"direction": "in", "protocol": "tcp", "port": port, "source_ips": anywhere} for port in ("22", "80", "443")]
    rules += [{"direction": "in", "protocol": "udp", "port": "443", "source_ips": anywhere}]
    return call(HCLOUD, token, "POST", "/firewalls", {"name": name, "rules": rules})["firewall"]["id"]


def ensure_server(token, args):
    existing = call(HCLOUD, token, "GET", f"/servers?name={args.name}")["servers"]
    if existing:
        print(f"server {args.name} already exists")
        return existing[0]
    ssh_keys = [key["id"] for key in call(HCLOUD, token, "GET", "/ssh_keys")["ssh_keys"]]
    body = {
        "name": args.name,
        "server_type": args.type,
        "location": args.location,
        "image": args.image,
        "ssh_keys": ssh_keys,
        "user_data": user_data(args),
        "labels": {"app": "openmausbot"},
        "firewalls": [{"firewall": ensure_firewall(token, f"{args.name}-web")}],
        "public_net": {"enable_ipv4": True, "enable_ipv6": True},
    }
    server = call(HCLOUD, token, "POST", "/servers", body)["server"]
    print(f"server {args.name} created ({len(ssh_keys)} SSH key(s) from the project)")
    return server


def ensure_dns(token, args, ipv4):
    zone_name = args.zone or ".".join(args.domain.split(".")[-2:])
    zones = call(CLOUDFLARE, token, "GET", f"/zones?name={zone_name}")["result"]
    if not zones:
        sys.exit(f"Cloudflare zone {zone_name} not found for this token")
    zone = zones[0]["id"]
    records = call(CLOUDFLARE, token, "GET", f"/zones/{zone}/dns_records?name={args.domain}")["result"]
    for record in records:
        if record["type"] in ("AAAA", "CNAME"):
            sys.exit(f"{args.domain} already has a {record['type']} record; remove it first")
    record = {"type": "A", "name": args.domain, "content": ipv4, "ttl": 120, "proxied": False,
              "comment": "OpenMausBot (deploy/vps)"}
    a_records = [r for r in records if r["type"] == "A"]
    if a_records:
        call(CLOUDFLARE, token, "PUT", f"/zones/{zone}/dns_records/{a_records[0]['id']}", record)
    else:
        call(CLOUDFLARE, token, "POST", f"/zones/{zone}/dns_records", record)
    print(f"DNS: {args.domain} A {ipv4} (DNS only)")


def wait_for_deploy(domain, minutes):
    url = f"https://{domain}/.well-known/openmausbot-deploy.json"
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                status = json.loads(response.read())
                print(json.dumps(status, indent=2))
                return status.get("result") == "ok"
        except (urllib.error.URLError, OSError, ValueError):
            time.sleep(30)
    print(f"no deploy status at {url} after {minutes} minutes")
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--signin-emails", default="")
    parser.add_argument("--repo", default="https://github.com/marcokoersST/OpenMausBot")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--name", help="server name (default: from the domain)")
    parser.add_argument("--type", default="cx33")
    parser.add_argument("--location", default="nbg1")
    parser.add_argument("--image", default="ubuntu-24.04")
    parser.add_argument("--zone", help="Cloudflare zone (default: the domain's last two labels)")
    parser.add_argument("--wait-minutes", type=int, default=45)
    parser.add_argument("--yes", action="store_true", help="create the server (it is billed)")
    args = parser.parse_args()
    args.name = args.name or args.domain.replace(".", "-")

    hcloud = need_env("HCLOUD_TOKEN")
    cloudflare = need_env("CLOUDFLARE_API_TOKEN")
    server_type, price = monthly_price(hcloud, args.type, args.location)
    print(f"plan: {args.name} = {args.type} ({server_type['cores']} vCPU, {server_type['memory']:g} GB RAM, "
          f"{server_type['disk']} GB disk) in {args.location}, at most EUR {float(price):.2f}/month incl. VAT")
    print(f"      https://{args.domain}, deploying {args.repo} @ {args.ref}, auto-update every 15 minutes")
    if not args.yes:
        print("dry run: add --yes to create it")
        return

    server = ensure_server(hcloud, args)
    ipv4 = server["public_net"]["ipv4"]["ip"]
    print(f"IPv4: {ipv4}")
    ensure_dns(cloudflare, args, ipv4)
    sys.exit(0 if wait_for_deploy(args.domain, args.wait_minutes) else 1)


if __name__ == "__main__":
    main()
