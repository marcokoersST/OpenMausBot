# Production VPS deployment

One OpenMausBot server on a dedicated Linux VPS, built from this repository,
reachable at `https://<your domain>`, with every bot turn sandboxed. It is
meant for bots that work with APIs and the internet around the clock: routines,
webhooks from other services, connected apps, custom MCP servers and a browser
per bot.

```
internet ──443──▶ Caddy (TLS, Let's Encrypt) ──▶ OpenMausBot server (127.0.0.1:8799)
           ──/hooks/*──────────────────────────▶ webhook receiver  (127.0.0.1:8800)
                                                   └─ each bot turn in a bot box:
                                                      own namespaces, egress gate,
                                                      credential broker (docs/bot-box.md)
```

## What you need

- A VPS with Ubuntu 24.04, x86-64, at least 4 vCPU and 8 GB RAM (bots with a
  browser use memory) and 80 GB disk. Pick an EU region when your data must stay
  in the EU (for example Hetzner CX32/CPX31 in Falkenstein, Nuremberg or Helsinki).
  Use it for this server only.
- An SSH key on that server for `root` (the provider's console adds it at creation).
- A hostname, such as `maus.example.com`, with an **A record** pointing at the
  server's IPv4 address. Ports 80 and 443 must be reachable.
- The Claude and/or ChatGPT accounts the bots will run on.

## Install

On the new server, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/marcokoersST/OpenMausBot/main/deploy/vps/bootstrap.sh \
  | bash -s -- --domain maus.example.com --signin-emails @example.com
```

`--signin-emails` lists who may sign in at `https://<domain>/pair` with an
emailed code (addresses or `@domain`, comma-separated); leave it out to use
pairing codes only. `--ref BRANCH` deploys another branch, `--engines` changes
the baked-in engine CLIs, `--auto-update` deploys new commits on that branch by
itself (below). `bootstrap.sh --help` lists every option.

The script, safe to run again:

1. installs security updates and turns on automatic ones (`unattended-upgrades`);
2. adds 4 GB of swap when there is none;
3. turns SSH password login off when a key is present, and enables `fail2ban`;
4. closes every inbound port except 22, 80 and 443 (`ufw`);
5. installs Docker and loads the `openmausbot-omb` AppArmor profile;
6. clones this repository to `/opt/openmausbot` and writes `deploy/vps/.env`;
7. schedules a nightly backup (`openmausbot-backup.timer`, around 03:30) and,
   with `--auto-update`, a check for new commits every 15 minutes
   (`openmausbot-sync.timer`);
8. builds the image from that checkout and starts the server and Caddy.

Where the AppArmor profile cannot be loaded, the container runs unconfined and
the bot box may report itself off; the deploy status below shows it.

### Without a shell: Hetzner Cloud and Cloudflare

[`provision-hetzner.py`](provision-hetzner.py) does all of the above from any
machine with Python 3, without SSH: it creates a Hetzner Cloud server whose
first boot runs `bootstrap.sh --auto-update`, puts it behind a Hetzner Cloud
Firewall (22, 80, 443, ICMP), points a Cloudflare A record at it (DNS only, so
Caddy gets its own certificate) and waits for the deploy status.

```sh
export HCLOUD_TOKEN=…          # Hetzner project → Security → API tokens, Read & Write
export CLOUDFLARE_API_TOKEN=…  # Cloudflare token with Zone → DNS → Edit on the zone
deploy/vps/provision-hetzner.py --domain maus.example.com --ref main \
  --signin-emails you@example.com            # prints the plan and the monthly price
deploy/vps/provision-hetzner.py … --yes      # creates it (billed per hour)
```

The defaults are a CX33 in Nuremberg with Ubuntu 24.04 (`--type`, `--location`,
`--image`). SSH keys stored in the Hetzner project are installed; SSH password
login is off either way, and Hetzner's web console remains the way in. Running it
again reuses the server and the record.

Then sign the engines in and pair your first browser:

```sh
cd /opt/openmausbot/deploy/vps
./omb login claude          # Claude Code: follow the link it prints
./omb login codex           # Codex: device code
./omb pair --label "Laptop" # open the printed https://<domain>/pair#code=… link
./omb box-check             # expect "passed":32,"total":32
```

Pair other devices with `./omb pair`, or let colleagues sign in with their
email when `OMB_SIGNIN_EMAILS` covers them. Admins manage that list later in
Settings → Remote access.

## Operating it

All commands run from `/opt/openmausbot/deploy/vps` as root.

| Command | Does |
|---|---|
| `./omb status` | containers, health, version, public address |
| `./omb logs [omb\|caddy]` | follow the logs |
| `./omb update` | back up, `git pull` the deployed branch, rebuild, restart |
| `./omb sync` | `update`, only when the branch has new commits (what the timer runs) |
| `./omb deploy` | `up`, publishing the result as the deploy status |
| `./omb up` | rebuild and restart without pulling (after editing `.env`) |
| `./omb backup` | stop for a moment, archive everything, start again |
| `./omb restore FILE` | replace all data with an archive (backs up first, asks to confirm) |
| `./omb pair`, `./omb login ENGINE`, `./omb exec CMD` | as above |

Settings live in `deploy/vps/.env` (see [`.env.example`](.env.example)); apply a
change with `./omb up`.

**Updates.** The server runs exactly what is on the deployed branch of this
repository. Merge to that branch, then run `./omb update`; with `--auto-update`
the server does that itself within 15 minutes of a push. Whoever can push to the
deployed branch therefore controls the server: protect that branch. Rebuilding
also picks up the current base image and Debian packages. Running turns are
interrupted by a restart, so update between routine runs.

**Deploy status.** `https://<domain>/.well-known/openmausbot-deploy.json` is
public and says which commit runs, whether its deploy succeeded, the bot box
self-check count and, after a failure, the last 30 lines of its output:

```json
{"commit": "504856a…", "result": "ok", "botBox": "32/32", "log": null, "at": "…"}
```

Caddy serves it only while the server is healthy, so a first install that fails
shows nothing there; Hetzner's console and `/var/log/omb-bootstrap.log` do.

**Backups.** Each archive holds the whole data volume: chats, bots, routines,
paired sessions, the engines' logins and the bots' browser profiles. Archives
and a copy of `.env` are kept in `/var/backups/openmausbot` (root only) for
`BACKUP_KEEP_DAYS` days. The server is stopped for the seconds the archive takes,
because SQLite must not be copied while it is written. A backup on the same
disk does not survive losing the server: set `BACKUP_OFFSITE` to an
rsync-over-SSH target (a Hetzner Storage Box, for example) and add the root
user's SSH key there; every backup is then mirrored. Turn on the provider's
own server snapshots as well.

## Security model

- The server only listens on `127.0.0.1` inside its container. Caddy shares
  that network namespace, so every request from outside arrives through a proxy
  and needs a paired session; `/hooks/*` is the exception and checks each
  hook's own secret (docs/self-hosting.md).
- **Bot box on** (`OMB_BOT_BOX=1`): every engine process, shell command and
  MCP server a bot starts runs in its own bubblewrap sandbox. It cannot read the
  server's database, settings or other bots' folders, cannot see other
  processes, holds per-turn tokens instead of provider keys, and reaches the
  network only through the egress gate, which allows public addresses and
  refuses this server, the private network and cloud metadata. `./omb box-check`
  proves each of these at any time; the server also checks at every start and
  logs `bot box: on (…)`.
- To let bubblewrap create namespaces inside Docker, the server container runs
  with a seccomp profile that is Docker's default plus `clone`, `unshare`,
  `mount`, `umount2`, `pivot_root` and `sethostname`
  ([`seccomp-bot-box.json`](seccomp-bot-box.json), from
  [moby/profiles](https://github.com/moby/profiles)), the `openmausbot-omb`
  AppArmor profile (unconfined, plus the `userns` permission Ubuntu 24.04
  requires), and `systempaths=unconfined` (the kernel mounts a new `/proc` only
  when none of the container's is masked). That widens the container's
  boundary with the host kernel: **known risk**, accepted because the host runs
  nothing else and the bots' own code runs inside the much narrower box.
- Docker publishes ports past `ufw`; the stack publishes only 80 and 443, which
  are open anyway. Do not add `ports:` to the server.
- Bots reach the whole public internet. Limit what they can do there per bot
  (approval levels, connected apps) rather than at the network.
- Engine subscription logins sit in the box's home because the engine needs
  them; a bot can read its own engine's login (docs/bot-box.md, "What it does
  not do yet").

## Decisions

| Decision | Why |
|---|---|
| Docker Compose + Caddy on an own domain, not the managed tunnel or Tailscale | A fixed address under our control, automatic HTTPS, and public webhook ingress for other services; no dependency on the upstream openmausbot.com tunnel |
| Build from this checkout instead of pulling `ghcr.io/milind-soni/openmausbot` | The server must run our own branch, including changes not upstream |
| All deploy files in `deploy/vps/` | Upstream files stay untouched, so syncing with upstream does not conflict |
| Bot box on, with the container permissions above | Bots run code from the internet; isolating each turn from the server's secrets and network matters more than the wider container boundary |
| Stop-the-world nightly backup | The documented safe way to copy SQLite; costs a few seconds |
| One dedicated VPS | The host's only job is this server, which keeps the AppArmor and seccomp trade-off contained |
| Hetzner Cloud CX33 for a test server | EU region, hourly billing, and an API that creates the server and its firewall without SSH; 8 GB RAM leaves room for the build and the bots' browsers |
| Auto-update from a branch, plus a public deploy status | The server can then be changed and checked without a shell on it (the sandbox Claude Code works from has no outbound SSH) |

## Verified

On 2026-10-29, the image built from this checkout ran with this compose file in a
Docker 29 test container (Ubuntu 24.04 kernel 6.18, no AppArmor): server healthy,
`bot box: on`, the box self-check 32/32, HTTPS through Caddy (internal
certificate for `localhost`), API refused before pairing and answered after,
`/hooks/*` reaching the webhook receiver, backup and restore round trip. Not
verified there: `bootstrap.sh` on a real VPS, a Let's Encrypt certificate, and
the AppArmor profile on an AppArmor host. Check `./omb box-check` after the first
install; if it reports the box `off`, the server log names the reason.

On 2026-10-30, in the same test host: `omb deploy` publishing a failed build with
its log, the deploy status served through Caddy with `"botBox": "32/32"`, `omb
sync` doing nothing without new commits, and the cloud-init user data that
`provision-hetzner.py` generates parsing as YAML. Not verified: a sync that
deploys a new commit, and the Hetzner and Cloudflare API calls themselves.
