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

cat > /dynamic/t3-2.yml <<EOF
http:
  routers:
    t3-2:
      rule: "Host(\`t3-2.${MY_DOMAIN}\`)"
      entryPoints:
        - websecure
      service: t3-2
      middlewares:
        - authelia@docker

  services:
    t3-2:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://10.8.0.2:3773"
EOF

echo "t3-2.yml generated"

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

echo "t3-1.yml generated"
