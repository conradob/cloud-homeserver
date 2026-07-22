# Self-Hosted Service Behind a VPS via WireGuard

How to expose a self-hosted service running on a home Mac through a VPS-based reverse proxy (Traefik + Authelia), without opening any inbound ports at home.

The running example is Paperclip on `http://10.8.0.2:3100`, but the pattern works for any HTTP service on the home machine.

## Architecture

```
   Browser
     │ HTTPS
     ▼
   service.<domain>  →  VPS public IP
     │
   ┌─┴────────────────────────────────────┐
   │ VPS                                  │
   │   Traefik (TLS + Authelia)           │
   │     ▼ http://10.8.0.2:3100           │
   │   wg0  ←  10.8.0.1                   │
   └─────│────────────────────────────────┘
         │ WireGuard (UDP 51820)
         ▼
   ┌──────────────────────────────────────┐
   │ Home Mac                             │
   │   utunN  ←  10.8.0.2                 │
   │     ▼                                │
   │   Service :3100 (binds 10.8.0.2)     │
   └──────────────────────────────────────┘
```

Key properties:

- Home Mac accepts **no** inbound public traffic; it dials out to the VPS.
- Home's public IP (static or dynamic) is irrelevant.
- Two auth layers protect the service: Authelia at the edge, the service's own auth inside.
- No external identity provider is required.

## Prerequisites

- VPS already running Docker, Traefik, and Authelia (Docker provider for existing services).
- VPS firewall allows TCP 443 inbound. UDP 51820 will be added below.
- Wildcard or per-host DNS for the new subdomain already pointing to the VPS.
- Home Mac with admin (sudo) user for initial setup; service may run as a non-admin user.
- `wireguard-tools` available somewhere for key generation (`apt install wireguard-tools`, `brew install wireguard-tools`, etc.).

---

## Phase 1 — Generate keys

Run on any trusted machine. Treat all output files as secrets.

```bash
mkdir -p ~/wg-keys && cd ~/wg-keys
umask 077

wg genkey | tee vps_private.key | wg pubkey > vps_public.key
wg genkey | tee home_private.key | wg pubkey > home_public.key
wg genpsk > preshared.key

ls -la
```

You should end up with five files at mode `600`. The preshared key is optional but cheap defense-in-depth — keep it.

---

## Phase 2 — VPS: WireGuard container

Run WireGuard as a container alongside Traefik/Authelia. Use `network_mode: host` so the `wg0` interface lives on the VPS host's network stack — Traefik in its own bridge network can then reach `10.8.0.2` through normal host routing, without sharing network namespaces.

### docker-compose service

Add to your existing compose file:

```yaml
  wireguard_generate_config:
    build: wireguard
    volumes:
      - ../data/wireguard:/config
    environment:
      WG_PRIVATE_KEY: "${WG_PRIVATE_KEY}"
      WG_PEER_PUBLIC_KEY: "${WG_PEER_PUBLIC_KEY}"
      WG_PEER_PRESHARED_KEY: "${WG_PEER_PRESHARED_KEY}"

  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    depends_on:
      wireguard_generate_config:
        condition: service_completed_successfully
    volumes:
      - ../data/wireguard:/config
      - /lib/modules:/lib/modules
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "Europe/Lisbon"
    restart: unless-stopped
```

The `wireguard_generate_config` sidecar templates the config file from environment variables so no secrets sit in the compose file. A minimal version:

`wireguard/Dockerfile`:

```dockerfile
FROM alpine:latest
RUN apk add --no-cache bash
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`wireguard/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /config/wg_confs
cat > /config/wg_confs/wg0.conf <<EOF
[Interface]
Address    = 10.8.0.1/24
ListenPort = 51820
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
PublicKey    = ${WG_PEER_PUBLIC_KEY}
PresharedKey = ${WG_PEER_PRESHARED_KEY}
AllowedIPs   = 10.8.0.2/32
EOF

chmod 600 /config/wg_confs/wg0.conf
```

> This is the single-peer form. To connect additional machines to the tunnel, the
> generator templates one `[Peer]` block per peer — see
> [Adding Another WireGuard Peer](adding-a-wireguard-peer.md).

Set the variables in your `.env` file:

```bash
WG_PRIVATE_KEY=<vps_private.key contents>
WG_PEER_PUBLIC_KEY=<home_public.key contents>
WG_PEER_PRESHARED_KEY=<preshared.key contents>
```

### Open UDP 51820

```bash
sudo ufw allow 51820/udp
# Also check your cloud provider's security group / firewall.
```

### Bring it up

```bash
docker compose up -d wireguard
docker exec wireguard wg show
ip addr show wg0           # should show 10.8.0.1/24
```

`wg show` will list the home peer but no handshake yet — that's expected until the home side comes up.

---

## Phase 3 — Home Mac: WireGuard.app

The official WireGuard.app from the Mac App Store handles the userspace tunnel, system extension approval, and on-demand activation. It does not require sudo for day-to-day operation once installed.

### Install

```bash
# Option 1: Mac App Store (recommended — auto-updates)
# Search "WireGuard" → publisher "WireGuard Development Team"

# Option 2: Homebrew Cask
brew install --cask wireguard
```

Launch the app once. macOS will prompt to approve a System Extension and a VPN configuration — approve both. You may also need to visit **System Settings → Privacy & Security** to allow the extension.

### Prepare the tunnel config

Type the config locally rather than transferring it (the private key is sensitive). `~/Desktop/wg0.conf`:

```ini
[Interface]
Address    = 10.8.0.2/24
PrivateKey = <home_private.key contents>

[Peer]
PublicKey           = <vps_public.key contents>
PresharedKey        = <preshared.key contents>
Endpoint            = vps.<your-domain>:51820
AllowedIPs          = 10.8.0.1/32
PersistentKeepalive = 25
```

Notes:

- `Endpoint` is the VPS's public hostname (preferred — survives IP changes) or raw IP, plus the WireGuard UDP port. Don't use a Cloudflare-proxied DNS record here — Cloudflare doesn't forward UDP.
- `AllowedIPs = 10.8.0.1/32` keeps only tunnel-bound traffic routed through the tunnel. Nothing else is affected.
- `PersistentKeepalive = 25` is required — without it the home NAT mapping eventually drops and the VPS can no longer reach the home Mac.

### Import and activate

In WireGuard.app:

1. Click **+** → **Import tunnel(s) from file** → select `wg0.conf`.
2. With `wg0` selected, click **Edit**. Under "On-Demand," check **Ethernet** and **Wi-Fi**. Save.
3. Toggle the tunnel **ON**. Within ~10s the status should read "Active."

Securely delete the source file:

```bash
rm -P ~/Desktop/wg0.conf
```

The app now holds the config in the system keychain.

### Verify

From the Mac:

```bash
ifconfig | grep -A 3 utun | grep 10.8.0.2     # interface up
ping -c 2 10.8.0.1                             # reach VPS over tunnel
```

From the VPS:

```bash
docker exec wireguard wg show                  # "latest handshake" within last minute
ping -c 2 10.8.0.2                             # reach home over tunnel
```

### Boot-time behavior

With On-Demand enabled, the tunnel reactivates whenever the Mac has network connectivity — including after reboot. Test it:

```bash
sudo reboot
# After reboot, do NOT log in to the GUI.
# From the VPS, wait a minute and:
ping -c 2 10.8.0.2
```

If ping fails until someone logs in to the Mac's GUI, the tunnel is waiting for a user session. Options: enable auto-login for an admin user, or switch to a `launchd` LaunchDaemon running `wg-quick` as root — see [Adding Another WireGuard Peer → headless boot daemon](adding-a-wireguard-peer.md#option-b--wg-quick--launchd-daemon-headless-boots-before-login--recommended-for-a-service-host).

### Bind the service to the tunnel address

Configure the home service (Paperclip, etc.) to bind `10.8.0.2:<port>` rather than `0.0.0.0` or `127.0.0.1`. This restricts it to tunnel-only access — even other devices on the home LAN can't reach it.

For Paperclip specifically: choose **Authenticated + Public** mode at onboarding, set the base URL to the final public URL (`https://service.<domain>`), set bind host to `10.8.0.2`, and whitelist the public hostname with `pnpm paperclipai allowed-hostname service.<domain>`.

Verify from the VPS:

```bash
curl -m 5 http://10.8.0.2:3100/api/health
```

---

## Phase 4 — Traefik: file provider for external services

Traefik's Docker provider can't see services that aren't containers on the VPS. Enable the file provider alongside it to expose external services via dynamic config files.

The file provider reads YAML as-is — it does **not** expand `${MY_DOMAIN}` or any other compose variable. To keep secrets and per-deployment hostnames out of the repo, this project uses the same pattern as the WireGuard config: a small init sidecar (`traefik_generate_dynamic`) renders the route file from environment variables at startup, and Traefik picks it up via file watching.

### Update Traefik command, volumes, and dependencies

```yaml
  traefik_generate_dynamic:
    build: traefik
    volumes:
      - ../data/traefik/dynamic:/dynamic
    environment:
      MY_DOMAIN: "${MY_DOMAIN}"

  proxy:
    image: traefik
    container_name: traefik
    depends_on:
      authelia:
        condition: service_started
      traefik_generate_dynamic:
        condition: service_completed_successfully
    command:
      - "--log.level=DEBUG"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      # ADD:
      - "--providers.file.directory=/dynamic"
      - "--providers.file.watch=true"
      # ... existing cert resolver and entrypoint flags unchanged
    volumes:
      - "../data/traefik/letsencrypt:/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      # ADD (note ":ro" — the generator writes, Traefik only reads):
      - "../data/traefik/dynamic:/dynamic:ro"
```

Two things changed beyond the file-provider flags themselves: `depends_on` had to switch to long-form so `proxy` can wait for the generator to finish via `service_completed_successfully`, and a new `traefik_generate_dynamic` service was added that shares the same host bind mount in read-write mode.

### The generator

`compose/traefik/Dockerfile`:

```dockerfile
FROM alpine
WORKDIR /dynamic
ADD entrypoint.sh /bin/entrypoint.sh
RUN chmod +x /bin/entrypoint.sh
ENTRYPOINT /bin/entrypoint.sh
```

`compose/traefik/entrypoint.sh`:

```sh
#!/bin/sh
set -e

: "${MY_DOMAIN:?MY_DOMAIN must be set}"

mkdir -p /dynamic

cat > /dynamic/paperclip.yml <<EOF
http:
  routers:
    paperclip:
      rule: "Host(\`org.${MY_DOMAIN}\`)"
      entryPoints:
        - websecure
      service: paperclip
      middlewares:
        - authelia@docker

  services:
    paperclip:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://10.8.0.2:3100"
EOF

echo "paperclip.yml generated"
```

Notes on the rendered route:

- The backticks around the host are escaped (`` \` ``) so the shell heredoc keeps them literal — Traefik's `Host()` matcher requires backticks.
- `passHostHeader: true` is required when the upstream service validates the Host header (Better Auth and most modern frameworks do).
- No `tls:` block needed — the `websecure` entrypoint already has TLS on by default (the wildcard cert covers all `*.${MY_DOMAIN}` subdomains).
- Middlewares cross provider boundaries via the `@<provider>` suffix — `authelia@docker` references the middleware defined by Docker labels on the Authelia container.

### Authelia — usually nothing to do

The Authelia config in this project uses:

```yaml
access_control:
  default_policy: 'one_factor'
```

with no `rules:` block. Any host routed through `authelia@docker` is automatically protected at one-factor, so **adding a new service that should use the default policy requires no Authelia change**.

Only edit `configuration.yml` if the new service needs a *different* policy than the default — for example, `two_factor` for something more sensitive, or `bypass` for a public health endpoint:

```yaml
access_control:
  default_policy: 'one_factor'
  rules:
    - domain: 'sensitive.example.com'
      policy: 'two_factor'
```

### Apply

```bash
docker compose up -d --build traefik_generate_dynamic proxy
docker exec compose-traefik_generate_dynamic-1 cat /dynamic/paperclip.yml   # sanity-check the render
docker compose logs -f proxy
```

In the Traefik logs, look for:

- `Provider connection established with file`
- `Configuration loaded from file: /dynamic/paperclip.yml`
- No errors about the middleware reference.

---

## Phase 5 — End-to-end verification

### Connectivity from inside Traefik's container

Make sure Traefik (in its bridge network) can actually reach the tunnel IP on the host:

```bash
docker run --rm --network container:traefik curlimages/curl -m 5 http://10.8.0.2:3100/api/health
```

If this fails but the same `curl` from the VPS host works, there's a Docker routing issue to investigate before continuing.

### Public path

```bash
curl -sI https://service.example.com
# Should return a 302 redirect to https://auth.example.com/?rd=...
```

### Browser flow

1. Open `https://service.example.com`
2. Traefik redirects to the Authelia portal
3. Log in via Authelia (with whatever policy was configured — typically 2FA)
4. Redirect back to `service.example.com`
5. The service's own login screen appears
6. Log in to the service
7. The service loads ✅

---

## Adding more services later

The pattern composes. For each additional home service:

1. Bind it to `10.8.0.2:<port>` on the Mac.
2. Extend `compose/traefik/entrypoint.sh` to render another `<service>.yml` block alongside `paperclip.yml` (same router + service skeleton, different hostname and upstream port).
3. Only if it needs a stricter or looser policy than the default: add an Authelia access control rule.
4. `docker compose up -d --build traefik_generate_dynamic` regenerates the files; Traefik picks them up via file watch.

No WireGuard changes, no firewall changes, no new DNS records (if you have a wildcard).

---

## Common pitfalls

| Symptom | Likely cause |
|---|---|
| No WireGuard handshake | VPS firewall blocking UDP 51820, or key typo |
| Handshake works, ping doesn't | `AllowedIPs` misconfigured on one side |
| Ping works, curl returns connection refused | Service not bound to `10.8.0.2` (check it's not on `127.0.0.1` only) |
| Tunnel drops after idle | `PersistentKeepalive` missing on home side |
| 502 Bad Gateway from Traefik | Traefik container can't route to host's tunnel IP; check `wg0` is up on the host |
| Redirect loop after login | `passHostHeader: true` missing, or service's expected base URL doesn't match the public URL exactly |
| Authelia portal loads but never redirects back | Cookie domain mismatch — Authelia's session cookies must cover both `auth.` and `service.` subdomains |
| Traefik logs: middleware `authelia@docker` does not exist | Authelia container started after Traefik tried to load the dynamic file; restart `proxy` |
| Tunnel needs GUI login on Mac before activating | On-Demand wasn't enabled, or the network condition didn't match; alternatively use a `launchd` daemon |

---

## Operational notes

- **Backups:** the tunnel config lives in the macOS keychain on the home side — export from WireGuard.app to a `.conf` and store encrypted. On the VPS, the keys are in `.env` and the rendered config in `../data/wireguard/wg_confs/wg0.conf`. Back both up.
- **Key rotation:** regenerate keys, swap one side at a time, verify handshake before swapping the other side.
- **Monitoring:** a simple cron on the VPS hitting `curl -sf http://10.8.0.2:3100/api/health` every few minutes is enough to catch tunnel drops.
- **Adding non-admin users on the Mac:** they don't need sudo. The tunnel is managed by the admin's WireGuard.app session (or a system-level daemon if you went that route); other users just consume the already-up `10.8.0.2` interface.
