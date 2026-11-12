#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -Eeuo pipefail
umask 022

usage() {
  cat <<'HELP'
菜单模式：sudo bash install.sh
也支持：  sudo sh install.sh（自动交给 Bash 执行）

Usage: sudo bash install.sh DOMAIN [--email EMAIL] [--repo OWNER/REPO] [--ref REF]
       [--template random|fieldnotes|architecture|garden|coast]
       sudo bash install.sh --status|--update-site|--check|--renew-test|--show-reality|--randomize-site

Supports Debian 12+ and Ubuntu 22.04+ with systemd.
DNS A/AAAA must point directly to this server. TCP 80 must be publicly reachable.
Keeps TCP 443 available for REALITY; serves HTTPS on 127.0.0.1:8443.
Without --repo, uses local site/ files, or downloads from laoluonb/reality-site.
HELP
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
script_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
default_repo=laoluonb/reality-site
template_ids=(fieldnotes architecture garden coast)
managed_config=/etc/nginx/sites-available/reality-site.conf
site_root=/var/www/reality-site

valid_template() {
  case "$1" in fieldnotes|architecture|garden|coast) return 0 ;; *) return 1 ;; esac
}
template_name() {
  case "$1" in
    fieldnotes) printf '山间手记' ;; architecture) printf '构筑笔记' ;;
    garden) printf '叶间日常' ;; coast) printf '海岸来信' ;;
  esac
}
template_source() {
  if [[ $1 == fieldnotes ]]; then printf 'site'; else printf 'templates/%s' "$1"; fi
}
select_template() {
  local requested=$1 exclude=${2:-} item
  local -a choices=()
  if [[ $requested != random ]]; then
    valid_template "$requested" || die "未知模板：$requested"
    selected_template=$requested
    return
  fi
  for item in "${template_ids[@]}"; do
    if [[ $item != "$exclude" ]]; then choices+=("$item"); fi
  done
  selected_template=${choices[RANDOM % ${#choices[@]}]}
}
valid_domain() {
  local candidate=$1 label
  local -a parts
  [[ ${#candidate} -le 253 && $candidate =~ ^[a-z0-9.-]+$ && $candidate == *.* && $candidate != *..* && $candidate != *. ]] || return 1
  IFS='.' read -r -a parts <<< "$candidate"
  for label in "${parts[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  [[ ${parts[-1]} =~ [a-z] ]] || return 1
  case "$candidate" in
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|*.invalid|*.test|*.localhost|localhost) return 1 ;;
  esac
}
valid_email() { [[ -z $1 || $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
require_root() { [[ $EUID -eq 0 ]] || die "请使用 sudo bash install.sh，或以 root 身份运行。"; }
load_managed_site() {
  [[ -f $managed_config ]] || die "尚未安装网站，请先在菜单选择 1。"
  grep -Fxq '# Managed by reality-site installer.' "$managed_config" || die "检测到其他程序管理的配置，已停止操作。"
  managed_domain=$(awk '/^# Domain: / {print $3; exit}' "$managed_config")
  managed_repo=$(awk '/^# Repository: / {print $3; exit}' "$managed_config")
  managed_ref=$(awk '/^# Ref: / {print $3; exit}' "$managed_config")
  managed_repo=${managed_repo:-$default_repo}
  managed_ref=${managed_ref:-main}
  managed_template=$(awk '/^# Template: / {print $3; exit}' "$managed_config")
  if [[ -f $site_root/template ]]; then read -r managed_template < "$site_root/template" || true; fi
  managed_template=${managed_template:-fieldnotes}
  valid_domain "$managed_domain" || die "已安装配置中的域名无效。"
  valid_template "$managed_template" || die "已安装模板记录无效。"
  [[ $managed_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $managed_ref =~ ^[A-Za-z0-9_.-]+$ ]] || die "已安装配置中的仓库或版本无效。"
}
lock_site() {
  command -v flock >/dev/null || die "请先安装 util-linux。"
  exec 9>/run/reality-site-install.lock
  flock -n 9 || die "另一个安装或更新操作正在进行，请稍后再试。"
}
show_reality() {
  load_managed_site
  cat <<EOF

REALITY 需要对应以下设置：
  对外监听端口：443
  target（旧版为 dest）："127.0.0.1:8443"
  serverNames：["$managed_domain"]
  客户端 SNI：$managed_domain
  普通浏览器访问：https://$managed_domain

请在现有配置中调整这些字段，并保留原有 UUID、密钥和 shortIds。
本脚本不安装或修改 Xray；面板重新生成配置后，要再次检查 target。
EOF
}
show_status() {
  if [[ ! -f $managed_config ]]; then printf '网站尚未安装，请选择菜单 1。\n'; return; fi
  load_managed_site
  printf '\n域名：%s\n网站目录：%s/public\nHTTPS 监听：127.0.0.1:8443\n' "$managed_domain" "$site_root"
  printf '当前模板：%s（%s）\n' "$(template_name "$managed_template")" "$managed_template"
  printf '\nNginx 状态：\n'
  systemctl is-active nginx || true
  printf '\n证书续期定时器：\n'
  systemctl list-timers certbot.timer --no-pager || true
  if [[ -f /etc/letsencrypt/live/$managed_domain/fullchain.pem ]]; then
    printf '\n证书有效期：\n'
    openssl x509 -in "/etc/letsencrypt/live/$managed_domain/fullchain.pem" -noout -dates
  fi
  if command -v ss >/dev/null; then
    printf '\n80 / 443 / 8443 端口监听情况：\n'
    ss -ltnp '( sport = :80 or sport = :443 or sport = :8443 )'
  fi
}
check_site() {
  load_managed_site
  nginx -t
  printf '\n正在检查本机网站的 HTTPS 证书和 TLS 1.3……\n'
  curl --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 15 \
    --tlsv1.3 --tls-max 1.3 --resolve "$managed_domain:8443:127.0.0.1" \
    "https://$managed_domain:8443/" --output /dev/null
  local handshake
  handshake=$(timeout 15 openssl s_client -connect 127.0.0.1:8443 -servername "$managed_domain" -alpn h2 -tls1_3 </dev/null 2>&1)
  grep -q 'ALPN protocol: h2' <<< "$handshake" || die "HTTP/2 协商失败。"
  printf '本机 HTTPS、证书、TLS 1.3 和 HTTP/2 检查通过。\n'
  printf '公网 443 还需要你现有的 REALITY 服务正确转发到 127.0.0.1:8443。\n'
}
update_site() {
  load_managed_site
  lock_site
  [[ -d $site_root/public && ! -L $site_root/public ]] || die "网站目录不存在，或是符号链接，请手动检查。"
  local update_tmp asset source_path
  select_template "$managed_template"
  if [[ ${1:-keep} == random ]]; then select_template random "$managed_template"; fi
  source_path=$(template_source "$selected_template")
  update_tmp=$(mktemp -d "$site_root/.update.XXXXXX")
  # Keep the live website intact until all replacement files are downloaded.
  trap 'status=$?; if [[ $status -ne 0 && -d $update_tmp/previous ]]; then rm -rf -- "$site_root/public"; mv "$update_tmp/previous" "$site_root/public"; fi; rm -rf -- "$update_tmp"' EXIT
  cp -a "$site_root/public" "$update_tmp/public"
  mkdir -p "$update_tmp/public/assets"
  printf '正在从 %s（%s）部署模板：%s……\n' "$managed_repo" "$managed_ref" "$(template_name "$selected_template")"
  for asset in index.html styles.css assets/landscape.jpg; do
    curl --fail --show-error --silent --location --retry 3 --retry-all-errors \
      --connect-timeout 15 --max-time 120 --proto '=https' --proto-redir '=https' \
      "https://raw.githubusercontent.com/$managed_repo/$managed_ref/$source_path/$asset" \
      --output "$update_tmp/public/$asset"
    [[ -s $update_tmp/public/$asset ]] || die "下载的文件为空：$asset"
    chmod 0644 "$update_tmp/public/$asset"
  done
  printf '%s\n' "$selected_template" > "$update_tmp/template"
  chmod 0644 "$update_tmp/template"
  mv "$site_root/public" "$update_tmp/previous"
  mv "$update_tmp/public" "$site_root/public"
  mv "$update_tmp/template" "$site_root/template"
  trap - EXIT
  rm -rf -- "$update_tmp"
  printf '网页部署完成：%s。证书和 REALITY 配置保持不变。\n' "$(template_name "$selected_template")"
}
install_wizard() {
  local input_domain="" input_email="" answer=""
  local current_domain="" source_repo=$default_repo source_ref=main
  if [[ -f $managed_config ]]; then
    load_managed_site
    current_domain=$managed_domain
    source_repo=$managed_repo
    source_ref=$managed_ref
  fi
  printf '\n安装向导：输入 q 可返回菜单。\n'
  while true; do
    read -r -p "网站域名${current_domain:+ [$current_domain]}：" input_domain || return 0
    [[ $input_domain != q && $input_domain != Q ]] || return 0
    input_domain=${input_domain:-$current_domain}
    input_domain=${input_domain,,}
    if valid_domain "$input_domain"; then break; fi
    printf '请输入你拥有的真实域名，不带 https://、端口和路径。\n'
  done
  if [[ -n $current_domain && $current_domain != "$input_domain" ]]; then
    printf '当前已安装域名为 %s，本向导不直接替换域名。\n' "$current_domain"
    return 0
  fi
  while true; do
    read -r -p '证书通知邮箱（可留空，输入 q 返回）：' input_email || return 0
    [[ $input_email != q && $input_email != Q ]] || return 0
    if valid_email "$input_email"; then break; fi
    printf '邮箱格式不正确，请重新输入。\n'
  done
  cat <<EOF

请确认：
  域名：$input_domain
  邮箱：${input_email:-不提供}
  域名 A/AAAA 已直接解析到这台服务器，且未开启 CDN 代理。
  公网 TCP 80 可访问；本机 8443 空闲，或已由本脚本的网站使用。
  网站将监听 127.0.0.1:8443，443 留给现有 REALITY。
  将从 4 套模板中随机部署一套，安装完成后显示结果。
  接下来会申请证书并同意 Let's Encrypt 服务条款。
EOF
  read -r -p '开始安装？[y/N]：' answer || return 0
  [[ $answer == y || $answer == Y ]] || { printf '已返回菜单。\n'; return 0; }
  local -a args=("$input_domain" --email "$input_email" --ref "$source_ref")
  if [[ ! -d $(dirname -- "$script_path")/site ]]; then args+=(--repo "$source_repo"); fi
  if bash "$script_path" "${args[@]}"; then
    printf '\n安装完成。可以选择菜单 4 查看 REALITY 设置。\n'
  else
    printf '\n安装失败。请查看上方错误；修正 DNS、端口或环境后可重新安装。\n'
  fi
}
menu_main() {
  require_root
  [[ -t 0 ]] || die "菜单需要交互终端，请先下载脚本，再运行 sudo bash install.sh。"
  menu_loop
}
menu_loop() {
  local choice=""
  while true; do
    cat <<'MENU'

========== REALITY 目标网站管理 ==========
  1. 安装 / 重新配置网站（引导输入）
  2. 更新网页（不重新申请证书）
  3. 查看网站状态和证书有效期
  4. 查看 REALITY 对应设置
  5. 检查 HTTPS / TLS 1.3 / HTTP/2
  6. 测试证书自动续期
  7. 随机更换网站模板（不更换证书）
  0. 退出
MENU
    read -r -p '请选择 [0-7]：' choice || return 0
    case "$choice" in
      1) install_wizard ;;
      2|3|4|5|6|7)
        local action=""
        case "$choice" in
          2) action=--update-site ;; 3) action=--status ;; 4) action=--show-reality ;;
          5) action=--check ;; 6) action=--renew-test ;;
          7) action=--randomize-site ;;
        esac
        if bash "$script_path" "$action"; then
          :
        else
          printf '\n操作未完成，请根据上方提示处理后重试。\n'
        fi ;;
      0) return 0 ;;
      *) printf '请输入 0 到 7。\n' ;;
    esac
  done
}
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
if [[ $# -eq 0 || ${1:-} == --menu ]]; then
  [[ $# -le 1 ]] || die "--menu 不接受额外参数。"
  menu_main
  exit 0
fi
case "$1" in
  --status|--update-site|--check|--renew-test|--show-reality|--randomize-site)
    [[ $# -eq 1 ]] || die "该操作不接受额外参数。"
    require_root
    case "$1" in
      --status) show_status ;;
      --update-site) update_site ;;
      --randomize-site) update_site random ;;
      --check) check_site ;;
      --renew-test) load_managed_site; lock_site; certbot renew --cert-name "$managed_domain" --dry-run ;;
      --show-reality) show_reality ;;
    esac
    exit 0 ;;
esac
domain=${1,,}
shift
email=""
repo=""
ref="main"
requested_template=random
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email|--repo|--ref|--template)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      case "$1" in
        --email) email=$2 ;;
        --repo) repo=$2 ;;
        --ref) ref=$2 ;;
        --template) requested_template=$2 ;;
      esac
      shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_root
valid_domain "$domain" || die "请输入有效的真实域名，不带 https://、端口或路径。"
valid_email "$email" || die "邮箱格式不正确。"
[[ -z $repo || $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/REPO."
[[ $ref =~ ^[A-Za-z0-9_.-]+$ ]] || die "--ref must be a simple branch, tag, or commit."
select_template "$requested_template"
source_path=$(template_source "$selected_template")
[[ -f /etc/os-release ]] || die "Unsupported OS."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:*) [[ ${VERSION_ID%%.*} -ge 12 ]] || die "Debian 12+ required." ;;
  ubuntu:*) [[ ${VERSION_ID%%.*} -ge 22 ]] || die "Ubuntu 22.04+ required." ;;
  *) die "This installer supports Debian and Ubuntu only." ;;
esac
[[ -d /run/systemd/system ]] || die "A running systemd installation is required."
lock_site

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z $repo && ! -d $script_dir/$source_path ]]; then repo=$default_repo; fi
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
printf '本次部署模板：%s（%s）\n' "$(template_name "$selected_template")" "$selected_template"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot curl ca-certificates openssl iproute2
mkdir -p "$work/site/assets" "$root/public" "$root/acme/.well-known/acme-challenge"
if [[ -n $repo ]]; then
  for asset in index.html styles.css assets/landscape.jpg; do
    curl --fail --show-error --silent --location --retry 3 --retry-all-errors \
      --connect-timeout 15 --max-time 120 --proto '=https' --proto-redir '=https' \
      "https://raw.githubusercontent.com/$repo/$ref/$source_path/$asset" \
      --output "$work/site/$asset"
  done
else
  [[ -f "$script_dir/$source_path/index.html" && -f "$script_dir/$source_path/styles.css" && -s "$script_dir/$source_path/assets/landscape.jpg" ]] || die "Missing template files. Extract the full project or supply --repo OWNER/REPO."
  cp "$script_dir/$source_path/index.html" "$work/site/index.html"
  cp "$script_dir/$source_path/styles.css" "$work/site/styles.css"
  cp "$script_dir/$source_path/assets/landscape.jpg" "$work/site/assets/landscape.jpg"
fi
getent ahosts "$domain" >/dev/null || die "Domain does not resolve. Configure public DNS first."
mkdir -p "$root/public/assets"
install -m 0644 "$work/site/index.html" "$root/public/index.html"
install -m 0644 "$work/site/styles.css" "$root/public/styles.css"
install -m 0644 "$work/site/assets/landscape.jpg" "$root/public/assets/landscape.jpg"
chmod 0755 "$root" "$root/public" "$root/public/assets" "$root/acme" "$root/acme/.well-known" "$root/acme/.well-known/acme-challenge"

write_config() {
  local include_tls=$1
  cat <<EOF
$marker
# Domain: $domain
# Repository: ${repo:-$default_repo}
# Ref: $ref
# Template: $selected_template
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
  --connect-timeout 5 --max-time 15 \
  --resolve "$domain:8443:127.0.0.1" "https://$domain:8443/" --output /dev/null
timeout 15 openssl s_client -connect 127.0.0.1:8443 -servername "$domain" \
  -alpn h2 -tls1_3 </dev/null > "$work/tls-check.txt" 2>&1
grep -q 'ALPN protocol: h2' "$work/tls-check.txt" || die "HTTP/2 negotiation failed."
printf '%s\n' "$selected_template" > "$work/template"
install -m 0644 "$work/template" "$root/template"
config_changed=0
cat <<EOF

Website ready on 127.0.0.1:8443 with a publicly trusted certificate.
当前模板：$(template_name "$selected_template")（$selected_template）

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
