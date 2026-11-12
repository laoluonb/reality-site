#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

usage() {
  cat <<'HELP'
Usage: sudo bash install.sh DOMAIN [--email EMAIL] [--repo OWNER/REPO] [--ref REF]

Supports Debian 12+ and Ubuntu 22.04+ with systemd.
DNS A/AAAA must point directly to this server. TCP 80 must be publicly reachable.
Keeps TCP 443 available for REALITY; serves HTTPS on 127.0.0.1:8443.
Without --repo, uses the site/ directory next to this script.
HELP
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
[[ $# -gt 0 ]] || { usage; exit 1; }
domain=${1,,}
shift
email=""
repo=""
ref="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email|--repo|--ref)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      case "$1" in
        --email) email=$2 ;;
        --repo) repo=$2 ;;
        --ref) ref=$2 ;;
      esac
      shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Run with sudo or as root."
[[ ${#domain} -le 253 && $domain =~ ^[a-z0-9.-]+$ && $domain == *.* && $domain != *..* && $domain != *. ]] || die "Provide a valid domain, without https://, port, or path."
IFS='.' read -r -a labels <<< "$domain"
for label in "${labels[@]}"; do
  [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid DNS label."
done
[[ ${labels[-1]} =~ [a-z] ]] || die "Use a DNS domain, not an IP."
case "$domain" in
  example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|*.invalid|*.test|*.localhost|localhost)
    die "Replace the example domain with a real domain you own." ;;
esac
[[ -z $email || $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Invalid email address."
[[ -z $repo || $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/REPO."
[[ $ref =~ ^[A-Za-z0-9_.-]+$ ]] || die "--ref must be a simple branch, tag, or commit."
[[ -f /etc/os-release ]] || die "Unsupported OS."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:*) [[ ${VERSION_ID%%.*} -ge 12 ]] || die "Debian 12+ required." ;;
  ubuntu:*) [[ ${VERSION_ID%%.*} -ge 22 ]] || die "Ubuntu 22.04+ required." ;;
  *) die "This installer supports Debian and Ubuntu only." ;;
esac
[[ -d /run/systemd/system ]] || die "A running systemd installation is required."
command -v flock >/dev/null || die "Install util-linux (flock) first."
exec 9>/run/reality-site-install.lock
flock -n 9 || die "Another installation is running."

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=/var/www/reality-site
config=/etc/nginx/sites-available/reality-site.conf
enabled=/etc/nginx/sites-enabled/reality-site.conf
marker='# Managed by reality-site installer.'
work=$(mktemp -d)
config_changed=0
had_config=0
had_link=0
cleanup() {
  status=$?
  if [[ $status -ne 0 && $config_changed -eq 1 ]]; then
    printf '\nRestoring previous nginx configuration.\n' >&2
    if [[ $had_config -eq 1 ]]; then
      cp -p "$work/previous.conf" "$config"
    else
      rm -f "$config"
    fi
    if [[ $had_link -eq 0 ]]; then rm -f "$enabled"; fi
    if nginx -t; then systemctl reload nginx || true; fi
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
if [[ -e $config ]]; then
  grep -Fxq "$marker" "$config" || die "$config exists and is not managed by this installer."
  grep -Fqx "# Domain: $domain" "$config" || die "This installation already serves another domain."
  cp -p "$config" "$work/previous.conf"
  had_config=1
fi
if [[ -e $enabled || -L $enabled ]]; then
  [[ -L $enabled && $(readlink "$enabled") == "$config" ]] || die "Existing nginx site link conflicts."
  had_link=1
fi
if command -v ss >/dev/null; then
  for port in 80 8443; do
    listeners=$(ss -H -ltnp "sport = :$port")
    if [[ -n $listeners ]] && printf '%s\n' "$listeners" | grep -qv '"nginx"'; then
      die "Port $port is occupied by another service. Resolve this before installing."
    fi
    if [[ $port == 8443 && -n $listeners && $had_config -eq 0 ]]; then
      die "Port 8443 is already in use. Choose a free server or adjust the existing service."
    fi
  done
fi
if command -v nginx >/dev/null; then
  nginx -t || die "Existing nginx configuration is invalid."
  # Refuse a second virtual host with the same domain rather than silently overriding it.
  while IFS= read -r existing; do
    [[ $(readlink -f "$existing") == "$config" ]] && continue
    if grep -Fq "$domain" "$existing"; then
      die "Domain already appears in $existing. Merge that configuration manually."
    fi
  done < <(find -L /etc/nginx/sites-enabled /etc/nginx/conf.d -type f 2>/dev/null || true)
fi

printf 'Installing nginx and Certbot...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot curl ca-certificates openssl iproute2
mkdir -p "$work/site/assets" "$root/public" "$root/acme/.well-known/acme-challenge"
if [[ -n $repo ]]; then
  for asset in index.html styles.css assets/landscape.jpg; do
    curl --fail --show-error --silent --location --retry 3 \
      --proto '=https' --proto-redir '=https' \
      "https://raw.githubusercontent.com/$repo/$ref/site/$asset" \
      --output "$work/site/$asset"
  done
else
  [[ -f "$script_dir/site/index.html" && -f "$script_dir/site/styles.css" && -s "$script_dir/site/assets/landscape.jpg" ]] || die "Missing site files. Extract the full project or supply --repo OWNER/REPO."
  cp "$script_dir/site/index.html" "$work/site/index.html"
  cp "$script_dir/site/styles.css" "$work/site/styles.css"
  cp "$script_dir/site/assets/landscape.jpg" "$work/site/assets/landscape.jpg"
fi
getent ahosts "$domain" >/dev/null || die "Domain does not resolve. Configure public DNS first."
mkdir -p "$root/public/assets"
install -m 0644 "$work/site/index.html" "$root/public/index.html"
install -m 0644 "$work/site/styles.css" "$root/public/styles.css"
install -m 0644 "$work/site/assets/landscape.jpg" "$root/public/assets/landscape.jpg"
chmod 0755 /var/www "$root" "$root/public" "$root/public/assets" "$root/acme" "$root/acme/.well-known" "$root/acme/.well-known/acme-challenge"

write_config() {
  local include_tls=$1
  cat <<EOF
$marker
# Domain: $domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $root/acme;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://$domain\$request_uri; }
}
EOF
  if [[ $include_tls == yes ]]; then
    cat <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $domain;
    server_tokens off;
    root $root/public;
    index index.html;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:RealitySite:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
}
EOF
  fi
}
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
if [[ $had_config -eq 0 ]]; then
  write_config no > "$work/nginx.conf"
  config_changed=1
  install -m 0644 "$work/nginx.conf" "$config"
  if [[ $had_link -eq 0 ]]; then ln -s "$config" "$enabled"; fi
elif [[ $had_link -eq 0 ]]; then
  config_changed=1
  ln -s "$config" "$enabled"
fi
nginx -t
systemctl enable --now nginx
systemctl reload nginx
account_args=(--register-unsafely-without-email)
if [[ -n $email ]]; then account_args=(--email "$email"); fi
printf '\nRequesting certificate. DNS must point here; public TCP 80 must reach nginx.\n'
certbot certonly --webroot -w "$root/acme" \
  --domain "$domain" --cert-name "$domain" --non-interactive --agree-tos \
  --keep-until-expiring "${account_args[@]}"
write_config yes > "$work/nginx.conf"
config_changed=1
install -m 0644 "$work/nginx.conf" "$config"
nginx -t
systemctl reload nginx
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reality-site-reload <<'HOOK'
#!/bin/sh
set -eu
/usr/sbin/nginx -t
systemctl reload nginx
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reality-site-reload
systemctl enable --now certbot.timer

printf '\nChecking local HTTPS, certificate and HTTP/2...\n'
curl --fail --silent --show-error --noproxy '*' --tlsv1.3 --tls-max 1.3 \
  --resolve "$domain:8443:127.0.0.1" "https://$domain:8443/" --output /dev/null
openssl s_client -connect 127.0.0.1:8443 -servername "$domain" \
  -alpn h2 -tls1_3 </dev/null > "$work/tls-check.txt" 2>&1
grep -q 'ALPN protocol: h2' "$work/tls-check.txt" || die "HTTP/2 negotiation failed."
config_changed=0
cat <<EOF

Website ready on 127.0.0.1:8443 with a publicly trusted certificate.

Set these fields in the EXISTING Xray REALITY configuration:
  target (or old dest): "127.0.0.1:8443"
  serverNames: ["$domain"]
  inbound port: 443
  client serverName / SNI: "$domain"

This installer does not install Xray or change its configuration.
Until REALITY is configured, https://$domain on public port 443 may not work.
Keep TCP 80 reachable for certificate renewal. TCP 8443 stays local only.
Certificate renewal: systemctl status certbot.timer
Renewal test: certbot renew --dry-run
Website files: $root/public
Nginx configuration: $config
EOF
