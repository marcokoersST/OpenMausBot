#!/usr/bin/env bash
# Turn a fresh Ubuntu 24.04 (or 22.04) VPS into a hardened OpenMausBot server
# (deploy/vps/README.md). Run as root; safe to run again.
#
#   curl -fsSL https://raw.githubusercontent.com/marcokoersST/OpenMausBot/main/deploy/vps/bootstrap.sh \
#     | bash -s -- --domain maus.example.com --signin-emails @example.com
set -euo pipefail

DOMAIN=""
SIGNIN_EMAILS=""
REPO="https://github.com/marcokoersST/OpenMausBot.git"
REF="main"
DIR="/opt/openmausbot"
ENGINES="@anthropic-ai/claude-code @openai/codex"
AUTO_UPDATE=""

usage() {
  cat <<'EOF'
usage: bootstrap.sh --domain HOST [options]

  --domain HOST          public hostname; its DNS A record must point at this server
  --signin-emails LIST   who may sign in with an emailed code, e.g. "@example.com"
  --engines "PKG ..."    engine CLIs to bake in (default: Claude Code and Codex)
  --repo URL             git repository to deploy (default: the marcokoersST fork)
  --ref BRANCH           branch to deploy and follow on updates (default: main)
  --dir PATH             checkout location (default: /opt/openmausbot)
  --auto-update          deploy new commits on the branch every 15 minutes
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --signin-emails) SIGNIN_EMAILS="$2"; shift 2 ;;
    --engines) ENGINES="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --auto-update) AUTO_UPDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$DOMAIN" ] || { usage >&2; exit 1; }
grep -q '^ID=ubuntu$' /etc/os-release || warn "tested on Ubuntu 22.04 and 24.04 only"

export DEBIAN_FRONTEND=noninteractive

step "System packages and automatic security updates"
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl git ufw fail2ban unattended-upgrades rsync dnsutils apparmor
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades fail2ban

step "Swap"
if ! swapon --show | grep -q . && [ "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" -lt 16000000 ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

step "SSH: keys only"
if [ -s /root/.ssh/authorized_keys ] || compgen -G '/home/*/.ssh/authorized_keys' >/dev/null; then
  cat > /etc/ssh/sshd_config.d/10-openmausbot.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
  warn "no SSH authorized_keys found; password login stays on. Add a key and run this again."
fi

step "Firewall: SSH, HTTP and HTTPS only"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

step "Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

step "Checkout $REPO ($REF) in $DIR"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch origin "$REF"
  git -C "$DIR" checkout "$REF"
  git -C "$DIR" pull --ff-only origin "$REF"
else
  git clone --branch "$REF" "$REPO" "$DIR"
fi

step "Settings in $DIR/deploy/vps/.env"
ENV_FILE="$DIR/deploy/vps/.env"
[ -f "$ENV_FILE" ] || install -m 0600 "$DIR/deploy/vps/.env.example" "$ENV_FILE"
set_env() {
  local key="$1" value="$2"
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
  else
    echo "$key=$value" >> "$ENV_FILE"
  fi
}
set_env DOMAIN "$DOMAIN"
set_env ENGINES "$ENGINES"
[ -z "$SIGNIN_EMAILS" ] || set_env OMB_SIGNIN_EMAILS "$SIGNIN_EMAILS"

step "AppArmor profile for the server container"
# Ubuntu 24.04 lets only profiles with a userns rule create user namespaces,
# which the bot box needs; AppArmor 3 (22.04) has no such restriction or rule.
if [ -e /etc/apparmor.d/abi/4.0 ]; then
  cat > /etc/apparmor.d/openmausbot-omb <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile openmausbot-omb flags=(unconfined) {
  userns,
}
EOF
else
  cat > /etc/apparmor.d/openmausbot-omb <<'EOF'
include <tunables/global>

profile openmausbot-omb flags=(unconfined) {
}
EOF
fi
if aa-enabled -q 2>/dev/null && apparmor_parser -r /etc/apparmor.d/openmausbot-omb; then
  set_env OMB_APPARMOR_PROFILE openmausbot-omb
else
  warn "AppArmor profile not loaded; the container runs unconfined and the bot box may report off"
  set_env OMB_APPARMOR_PROFILE unconfined
fi

step "DNS check"
public_ip="$(curl -fsS4 --max-time 10 https://api.ipify.org || true)"
resolved="$(dig +short A "$DOMAIN" | tail -n 1)"
if [ -z "$resolved" ] || [ "$resolved" != "$public_ip" ]; then
  warn "$DOMAIN resolves to '${resolved:-nothing}', this server is '${public_ip:-unknown}'. Caddy gets a certificate only once the A record points here."
fi

step "Nightly backup and automatic updates"
cat > /etc/systemd/system/openmausbot-backup.service <<EOF
[Unit]
Description=OpenMausBot backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=$DIR/deploy/vps/omb backup
EOF
cat > /etc/systemd/system/openmausbot-backup.timer <<'EOF'
[Unit]
Description=Nightly OpenMausBot backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
if [ -n "$AUTO_UPDATE" ]; then
  cat > /etc/systemd/system/openmausbot-sync.service <<EOF
[Unit]
Description=Deploy new OpenMausBot commits
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=$DIR/deploy/vps/omb sync
EOF
  cat > /etc/systemd/system/openmausbot-sync.timer <<'EOF'
[Unit]
Description=Check for new OpenMausBot commits

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
fi
systemctl daemon-reload
systemctl enable --now openmausbot-backup.timer
[ -z "$AUTO_UPDATE" ] || systemctl enable --now openmausbot-sync.timer

step "Build and start (the first build takes several minutes)"
"$DIR/deploy/vps/omb" deploy

cat <<EOF

OpenMausBot is running at https://$DOMAIN

Next:
  $DIR/deploy/vps/omb login claude      sign Claude Code in (and/or: login codex)
  $DIR/deploy/vps/omb pair --label "My laptop"
                                         open the printed link to pair a browser
  $DIR/deploy/vps/omb box-check         confirm every bot turn runs sandboxed
EOF
