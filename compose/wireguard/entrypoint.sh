#!/bin/sh
set -e

: "${WG_PRIVATE_KEY:?WG_PRIVATE_KEY must be set}"
: "${WG_PEER_PUBLIC_KEY:?WG_PEER_PUBLIC_KEY must be set}"
: "${WG_PEER_PRESHARED_KEY:?WG_PEER_PRESHARED_KEY must be set}"
: "${WG_PEER2_PUBLIC_KEY:?WG_PEER2_PUBLIC_KEY must be set}"
: "${WG_PEER2_PRESHARED_KEY:?WG_PEER2_PRESHARED_KEY must be set}"

mkdir -p /config/wg_confs

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

chmod 600 /config/wg_confs/wg0.conf
echo "wg0.conf generated"
