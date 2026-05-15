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
