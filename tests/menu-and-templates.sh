#!/usr/bin/env bash
# Installer definitions and test doubles are loaded dynamically.
# shellcheck disable=SC2034,SC2154,SC2329
set -Eeuo pipefail

repository_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repository_dir/install.sh"
# Load definitions without running the installer or writing to system paths.
# shellcheck disable=SC1090
source <(sed '/^\[\[ \${1:-} != --help/,$d' "$installer")
script_path=$installer
test_root=$(mktemp -d "$repository_dir/.test-reality-site.XXXXXX")
case "$test_root" in "$repository_dir"/.test-reality-site.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$test_root"' EXIT
managed_config="$test_root/nginx.conf"
site_root="$test_root/site"
mkdir -p "$site_root/public/assets"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for value in notes.mydomain.com xn--fsqu00a.com; do
  valid_domain "$value" || fail "Valid domain rejected: $value"
done
for value in '' example.com https://mydomain.com mydomain.com:443 127.0.0.1 a..com -a.com a-.com a.com. $'a.com\ninjected'; do
  if valid_domain "$value"; then fail "Invalid domain accepted: $value"; fi
done
valid_email '' || fail 'Optional email rejected'
valid_email mail@mydomain.com || fail 'Valid email rejected'
if valid_email 'invalid;email'; then fail 'Invalid email accepted'; fi

declare -A observed=()
for ((i=0; i<300; i++)); do
  select_template random
  valid_template "$selected_template" || fail 'Random template is invalid'
  observed[$selected_template]=1
  select_template random coast
  [[ $selected_template != coast ]] || fail 'Random replacement repeated the current template'
done
[[ ${#observed[@]} -eq 4 ]] || fail 'Random selection did not reach all templates'
for item in "${template_ids[@]}"; do
  select_template "$item"
  [[ $selected_template == "$item" ]] || fail 'Fixed template selection changed'
  folder=$(template_source "$item")
  for asset in index.html styles.css assets/landscape.jpg; do
    [[ -s $repository_dir/$folder/$asset ]] || fail "Missing template asset: $folder/$asset"
  done
done
printf 'PASS: domain/email validation, random selection and template assets\n'

printf '%s\n' '# Managed by reality-site installer.' '# Domain: notes.mydomain.com' > "$managed_config"
load_managed_site
[[ $managed_template == fieldnotes && $managed_repo == laoluonb/reality-site ]] || fail 'Legacy configuration was not recognized'
bash() {
  printf '%s\n' "$*" >> "$test_root/actions"
  if [[ ${2:-} == --check ]]; then return 77; fi
}
menu_loop <<< $'x\n4\n5\n7\n8\n9\n0\n' > "$test_root/menu.log"
grep -q -- '--show-reality' "$test_root/actions" || fail 'Menu did not dispatch REALITY settings'
grep -q -- '--randomize-site' "$test_root/actions" || fail 'Menu did not continue after a failed action'
grep -q -- '--public-site' "$test_root/actions" || fail 'Public website menu action missing'
grep -q -- '--private-site' "$test_root/actions" || fail 'Private website menu action missing'
grep -q '操作未完成' "$test_root/menu.log" || fail 'Menu hid a failed action'
before_actions=$(wc -l < "$test_root/actions")
install_wizard <<< $'https://bad\nnotes.mydomain.com\nbad-email\nmail@mydomain.com\nn\n' > "$test_root/wizard.log"
[[ $(wc -l < "$test_root/actions") -eq $before_actions ]] || fail 'Cancelled wizard started installation'
grep -q '邮箱格式不正确' "$test_root/wizard.log" || fail 'Wizard accepted an invalid email'
printf 'PASS: legacy configuration, menu recovery and cancelled installation\n'

printf '%s\n' 'server {' '    listen 127.0.0.1:8443 ssl http2;' '    server_name notes.mydomain.com;' '}' > "$test_root/private.conf"
render_website_access public < "$test_root/private.conf" > "$test_root/public.conf"
grep -Fq 'listen 0.0.0.0:8443 ssl http2;' "$test_root/public.conf" || fail 'Public IPv4 listener missing'
grep -Fq 'listen [::]:8443 ssl http2;' "$test_root/public.conf" || fail 'Public IPv6 listener missing'
render_website_access public < "$test_root/public.conf" > "$test_root/public-again.conf"
cmp "$test_root/public.conf" "$test_root/public-again.conf" || fail 'Public mode is not idempotent'
render_website_access private < "$test_root/public.conf" > "$test_root/private-again.conf"
cmp "$test_root/private.conf" "$test_root/private-again.conf" || fail 'Private mode did not restore original config'
if render_website_access public < /dev/null > "$test_root/empty.conf"; then fail 'Missing managed listener accepted'; fi
printf 'PASS: website listener switching, idempotence and round-trip restoration\n'

unset -f bash
lock_site() { :; }
# The Windows Git runtime used for local checks does not ship chmod.
if ! command -v chmod >/dev/null; then chmod() { :; }; fi
curl() {
  local url="" output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      https://*) url=$1; shift ;;
      --output) output=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n $url && -n $output ]] || return 2
  if [[ ${fail_download:-no} == yes && $url == */styles.css ]]; then return 22; fi
  local remote_path=${url#"https://raw.githubusercontent.com/$managed_repo/$managed_ref/"}
  cp "$repository_dir/$remote_path" "$output"
}
printf 'old index\n' > "$site_root/public/index.html"
printf 'old css\n' > "$site_root/public/styles.css"
printf 'old image\n' > "$site_root/public/assets/landscape.jpg"
printf 'keep this file\n' > "$site_root/public/custom.txt"
printf 'fieldnotes\n' > "$site_root/template"
fail_download=yes
set +e
( set -e; update_site ) > "$test_root/failed-update.log" 2>&1
failed_status=$?
set -e
[[ $failed_status -ne 0 ]] || fail 'Failed download was reported as successful'
[[ $(< "$site_root/public/index.html") == 'old index' ]] || fail 'Failed update changed the live website'
[[ $(< "$site_root/template") == fieldnotes ]] || fail 'Failed update changed template state'
if compgen -G "$site_root/.update.*" >/dev/null; then fail 'Failed update left staging files behind'; fi
fail_download=no
mv() {
  if [[ ${fail_publish:-no} == yes && ${2:-} == "$site_root/template" ]]; then return 55; fi
  command mv "$@"
}
fail_publish=yes
set +e
( set -e; update_site random ) > "$test_root/failed-publish.log" 2>&1
failed_status=$?
set -e
[[ $failed_status -ne 0 ]] || fail 'Failed publication was reported as successful'
[[ $(< "$site_root/public/index.html") == 'old index' ]] || fail 'Failed publication did not restore the website'
[[ $(< "$site_root/template") == fieldnotes ]] || fail 'Failed publication changed template state'
if compgen -G "$site_root/.update.*" >/dev/null; then fail 'Failed publication left staging files behind'; fi
unset -f mv
( update_site random ) > "$test_root/successful-update.log"
new_template=$(< "$site_root/template")
[[ $new_template != fieldnotes ]] || fail 'Random replacement kept current template'
new_folder=$(template_source "$new_template")
cmp "$repository_dir/$new_folder/index.html" "$site_root/public/index.html" || fail 'Wrong template was deployed'
[[ $(< "$site_root/public/custom.txt") == 'keep this file' ]] || fail 'Update removed unrelated website files'
( update_site ) > "$test_root/keep-template.log"
[[ $(< "$site_root/template") == "$new_template" ]] || fail 'Ordinary update changed template'
if compgen -G "$site_root/.update.*" >/dev/null; then fail 'Successful update left staging files behind'; fi
printf 'PASS: failed download/publication rollback, random replacement and stable ordinary updates\n'
