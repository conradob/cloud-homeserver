# Adding Another WireGuard Peer (Service + Headless Boot + SSH)

Extends [Self-Hosted Service Behind a VPS via WireGuard](self-hosted-service-with-wireguard.md).

The base guide connects **one** home machine (`10.8.0.2`) to the VPS tunnel. This
doc covers adding **additional** peer machines — the running example is a second
Mac (`10.8.0.3`) serving a `t3` app exposed at `t3-1.<domain>` — and three things
the base guide left open:

- templating **multiple** peers in the VPS WireGuard config,
- bringing the tunnel up **headless at boot** (before any GUI login) via a
  `launchd` daemon,
- reaching a peer over the tunnel with **SSH** through the VPS as a jump host.

## Address plan

The tunnel is a single `/24` (`10.8.0.0/24`). Give each machine the next free `/32`:

| WG IP | Machine | Role |
|---|---|---|
| `10.8.0.1` | VPS | `wg0` interface / hub |
| `10.8.0.2` | home machine | peer 1 (paperclip `:3100`, t3-2 `:3773`) |
| `10.8.0.3` | t3-1 machine | peer 2 (t3-1 `:3773`) |

Peers only ever talk to the VPS (`10.8.0.1`); they never need to reach each other.

---

## Step 1 — Generate keys for the new peer

Run on the machine that will hold the key (or any trusted machine). Treat every
file as a secret.

```bash
umask 077
mkdir -p ~/wg-t3-1 && cd ~/wg-t3-1
wg genkey | tee t3-1_private.key | wg pubkey > t3-1_public.key
wg genpsk > t3-1_preshared.key
```

- `t3-1_private.key` + `t3-1_preshared.key` → the **new machine's** tunnel config (Step 3).
- `t3-1_public.key` + `t3-1_preshared.key` → the **VPS** `.env` (Step 2).
- The private key **never** goes to the VPS.

---

## Step 2 — Register the peer on the VPS

### The generator templates one `[Peer]` block per machine

`compose/wireguard/entrypoint.sh` renders `wg0.conf` from env vars — one guard +
one `[Peer]` block per peer:

```sh
: "${WG_PRIVATE_KEY:?WG_PRIVATE_KEY must be set}"
: "${WG_PEER_PUBLIC_KEY:?WG_PEER_PUBLIC_KEY must be set}"
: "${WG_PEER_PRESHARED_KEY:?WG_PEER_PRESHARED_KEY must be set}"
: "${WG_PEER2_PUBLIC_KEY:?WG_PEER2_PUBLIC_KEY must be set}"
: "${WG_PEER2_PRESHARED_KEY:?WG_PEER2_PRESHARED_KEY must be set}"

cat > /config/wg_confs/wg0.conf <<EOF
[Interface]
Address    = 10.8.0.1/24
ListenPort = 51820
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
# home machine
PublicKey    = ${WG_PEER_PUBLIC_KEY}
PresharedKey = ${WG_PEER_PRESHARED_KEY}
AllowedIPs   = 10.8.0.2/32

[Peer]
# t3-1 machine
PublicKey    = ${WG_PEER2_PUBLIC_KEY}
PresharedKey = ${WG_PEER2_PRESHARED_KEY}
AllowedIPs   = 10.8.0.3/32
EOF
```

To add a **third** peer later: add `WG_PEER3_*` guards, another `[Peer]` block
with `AllowedIPs = 10.8.0.4/32`, wire the vars through `compose.yaml`
(`wireguard_generate_config.environment`) and `.env_template`, then redeploy.

### Set the keys in the VPS `.env`

`compose/compose.yaml` passes the vars into the sidecar:

```yaml
  wireguard_generate_config:
    environment:
      WG_PEER2_PUBLIC_KEY: "${WG_PEER2_PUBLIC_KEY}"
      WG_PEER2_PRESHARED_KEY: "${WG_PEER2_PRESHARED_KEY}"
```

Append the values to `compose/.env` **on the VPS**. To keep the preshared key out
of shell history, copy the key files over and read them on the VPS instead of
echoing the value on the command line:

```bash
scp ~/wg-t3-1/t3-1_public.key ~/wg-t3-1/t3-1_preshared.key vps:/tmp/
ssh vps 'cd /var/opt/cloud-homeserver/compose &&
  grep -q "^WG_PEER2_PUBLIC_KEY=" .env || {
    echo "WG_PEER2_PUBLIC_KEY=$(cat /tmp/t3-1_public.key)"
    echo "WG_PEER2_PRESHARED_KEY=$(cat /tmp/t3-1_preshared.key)"
  } >> .env
  rm -f /tmp/t3-1_public.key /tmp/t3-1_preshared.key'
```

### Redeploy WireGuard

The generator's `entrypoint.sh` is baked into its image at build time, so the
config change requires `--build`:

```bash
cd /var/opt/cloud-homeserver/compose
docker compose up -d --build wireguard_generate_config   # regenerate wg0.conf
docker compose restart wireguard                         # apply
docker exec wireguard wg show                            # should now list TWO peers
```

> The `restart` briefly drops **all** peers (including the existing home peer);
> they re-handshake within seconds. UDP 51820 is already open from the base setup.

Grab the **VPS interface public key** — you need it for the client config:

```bash
docker exec wireguard wg show wg0 public-key
```

---

## Step 3 — Bring the tunnel up on the new machine

Type the config locally (don't transfer the private key). `wg0.conf`:

```ini
[Interface]
Address    = 10.8.0.3/24
PrivateKey = <t3-1_private.key contents>

[Peer]
PublicKey           = <VPS interface public key from Step 2>
PresharedKey        = <t3-1_preshared.key contents>
Endpoint            = vps.<your-domain>:51820
AllowedIPs          = 10.8.0.1/32
PersistentKeepalive = 25
```

- `AllowedIPs = 10.8.0.1/32` routes only tunnel traffic through the tunnel.
- `PersistentKeepalive = 25` keeps the home NAT mapping open so the VPS can always
  reach the peer.
- Don't use a Cloudflare-proxied hostname for `Endpoint` — Cloudflare doesn't
  forward UDP. A directly-resolving A record (or raw IP) is fine.

Pick **one** of the two ways to run it — never both for the same tunnel (they
fight over the `wg0` interface and identical keys, and the VPS sees the source
port flap).

### Option A — WireGuard.app (roaming, needs a GUI login)

Import the config, enable **On-Demand** (Wi-Fi + Ethernet), toggle ON. On-Demand
reactivates on wake/reconnect **while a user is logged in**, but does **not** come
up after a cold boot until someone logs into the GUI. Fine for a laptop; not for a
headless service host.

### Option B — wg-quick + launchd daemon (headless, boots before login) — recommended for a service host

Install the CLI tools and the config as root:

```bash
brew install wireguard-tools
sudo install -o root -g wheel -m 600 ~/wg-t3-1/wg0.conf /etc/wireguard/wg0.conf
sudo wg-quick up wg0        # test it comes up (creates utunN, backgrounds a route monitor)
```

Create `/Library/LaunchDaemons/com.wireguard.wg0.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wireguard.wg0</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; [ -f /var/run/wireguard/wg0.name ] || exec wg-quick up wg0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>60</integer>
    <key>StandardOutPath</key>
    <string>/var/log/wireguard-wg0.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/wireguard-wg0.log</string>
</dict>
</plist>
```

Load it:

```bash
sudo install -o root -g wheel -m 644 com.wireguard.wg0.plist /Library/LaunchDaemons/com.wireguard.wg0.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.wireguard.wg0.plist
sudo launchctl enable  system/com.wireguard.wg0
sudo launchctl print   system/com.wireguard.wg0 | grep -E "state ="   # -> state = running
```

**Why the guard instead of a bare `KeepAlive`.** `wg-quick up` is a one-shot: it
sets up the interface and exits. A plain `KeepAlive = true` would make launchd
relaunch it in a ~10s loop, and each rerun errors with `wg0 already exists`. The
guard `[ -f /var/run/wireguard/wg0.name ] || …` makes every relaunch a **no-op
unless the tunnel is actually down**, turning `KeepAlive` into a self-healing
watchdog: it comes up at boot (`RunAtLoad`) and, if the tunnel ever drops, is
restored within ~60s (`ThrottleInterval`). The interface itself persists after
`wg-quick` exits, so this only ever acts on a real drop.

Management:

```bash
sudo launchctl bootout   system /Library/LaunchDaemons/com.wireguard.wg0.plist   # stop + unload
sudo launchctl bootstrap system /Library/LaunchDaemons/com.wireguard.wg0.plist   # load
sudo wg-quick down wg0    # manual down — the watchdog re-ups within ~60s unless you bootout first
```

### Bind the service to the tunnel address

Configure the app (`t3`) to bind `10.8.0.3:3773` (not `0.0.0.0`/`127.0.0.1`), so
it's reachable only over the tunnel.

### Verify

```bash
# on the new machine
ping -c2 10.8.0.1
sudo wg show                       # handshake with the VPS peer
# on the VPS
docker exec wireguard wg show      # peer 10.8.0.3 shows endpoint + recent handshake
```

---

## Step 4 — Expose the service via Traefik

`compose/traefik/entrypoint.sh` renders one dynamic route file per host. The `t3-1`
block mirrors `t3-2`, pointing at the new peer:

```sh
cat > /dynamic/t3-1.yml <<EOF
http:
  routers:
    t3-1:
      rule: "Host(\`t3-1.${MY_DOMAIN}\`)"
      entryPoints:
        - websecure
      service: t3-1
      middlewares:
        - authelia@docker

  services:
    t3-1:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://10.8.0.3:3773"
EOF
```

Redeploy the generator (Traefik picks up the file via watch — no proxy restart):

```bash
cd /var/opt/cloud-homeserver/compose
docker compose up -d --build traefik_generate_dynamic
docker exec traefik cat /dynamic/t3-1.yml            # sanity-check render
docker compose logs proxy | grep -i t3-1             # "Adding route for t3-1.<domain>"
```

- **DNS:** no new record if you have the wildcard `*.<domain>` → VPS.
- **Authelia:** the default `one_factor` policy applies automatically; only edit
  `configuration.yml` if this host needs a different policy.
- **Verify the edge** (works even before the backend is up — auth runs first):
  ```bash
  curl -sI https://t3-1.<domain>     # HTTP/2 302 -> auth.<domain>
  ```

---

## Step 5 — SSH to the peer over the tunnel

A peer accepts no inbound public traffic, so SSH hops through the VPS. No Traefik
route and no WireGuard change are needed — the tunnel already routes VPS ↔ peer.

On the **peer** (enable SSH and authorize a key):

```bash
sudo systemsetup -setremotelogin on          # macOS; sshd binds 0.0.0.0:22, reachable at 10.8.0.3:22 over the tunnel
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf '%s\n' 'ssh-ed25519 AAAA... your-client-key' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

> **If `systemsetup` fails with "Turning Remote Login on or off requires Full Disk
> Access privileges"** (common on recent macOS when the terminal app lacks FDA),
> enable it in **System Settings → General → Sharing → Remote Login**, or bypass
> `systemsetup` entirely with `launchctl` (this state persists across reboots):
>
> ```bash
> sudo launchctl enable    system/com.openssh.sshd
> sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
> ```
>
> The Sharing pane may still show Remote Login "off" (you didn't toggle it there),
> but sshd is enabled and starts at boot. Confirm it's listening from the VPS:
> `ssh vps 'nc -w3 10.8.0.3 22 </dev/null | head -1'` → `SSH-2.0-OpenSSH_…`.

On your **client** (`~/.ssh/config`), reuse the VPS as a jump host:

```
Host vps
  HostName vps.<your-domain>
  User <vps-user>
  IdentityFile ~/.ssh/<vps-key>

Host t3-1
  HostName 10.8.0.3
  User <peer-user>
  ProxyJump vps
```

Then `ssh t3-1`.

### Bootstrapping when the peer is publickey-only

If the peer's sshd accepts only `publickey`, `ssh-copy-id` can't get in (you'd need
a key already installed). Plant the first key through a channel that isn't
key-gated: an existing session/console on the peer (append the `.pub` directly), or
temporarily set `PasswordAuthentication yes`, copy the key, then revert.

Key present but still `Permission denied (publickey)` is almost always **permissions**
(`~` not group-writable, `~/.ssh` = `700`, `authorized_keys` = `600`, owned by the
login user) or a **wrong/line-wrapped key**. Confirm the offered key matches:

```bash
ssh-keygen -lf ~/.ssh/authorized_keys      # fingerprints must include the client key's
```

### Lock down to keys-only

Once your key works, disable password auth. On macOS, drop a file in
`/etc/ssh/sshd_config.d/` (the main `sshd_config` `Include`s it near the top, so it
wins) rather than editing `sshd_config` directly:

```bash
sudo tee /etc/ssh/sshd_config.d/200-keys-only.conf >/dev/null <<'EOF'
# Public-key auth only. Both lines are required because macOS sets UsePAM yes.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t                                 # validate before relying on it
```

macOS spawns `sshd` per connection, so new connections pick this up immediately — no
reload. Verify from the VPS that only `publickey` is offered:

```bash
ssh vps 'ssh -o PreferredAuthentications=none -o StrictHostKeyChecking=no <peer-user>@10.8.0.3 true'
# -> Permission denied (publickey).          password/keyboard-interactive are gone
```

> Do this **only after** confirming key login works — with password fallback off,
> the authorized key becomes the only way in remotely.

---

## Deploying repo changes to the VPS

The VPS runs the stack from a git checkout at `/var/opt/cloud-homeserver` (fork
remote named `conradob`). The flow:

```bash
# locally
git add compose/ && git commit -m "..." && git push origin main
# on the VPS
cd /var/opt/cloud-homeserver && git pull conradob main
# then rebuild only the generator(s) whose entrypoint changed
cd compose && docker compose up -d --build wireguard_generate_config traefik_generate_dynamic
```

Generators bake their `entrypoint.sh` at build time, so config-only changes still
need `--build`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| VPS `wg show` lists the peer but no handshake | Peer tunnel not up, or `Endpoint`/firewall blocking UDP 51820 |
| Two `utun*` interfaces both on `10.8.0.x` | WireGuard.app **and** the daemon are both up for the same tunnel — disable one |
| VPS peer endpoint/port keeps changing | Same as above — app and daemon flapping the source port |
| `launchctl` job relaunches in a tight loop | Bare `KeepAlive` without the `wg0.name` guard on a one-shot `wg-quick up` |
| `502 Bad Gateway` after Authelia login | Service not bound to `10.8.0.3:<port>`, or tunnel down |
| `ssh` works to VPS but not to the peer | Key not in the **peer's** `authorized_keys`, or file permissions |

Useful checks on the peer:

```bash
sudo wg show all                 # exactly one wireguard interface expected
scutil --nc list                 # WireGuard.app tunnels register here; should be empty for this config
sudo launchctl print system/com.wireguard.wg0 | grep -E "state ="
```
