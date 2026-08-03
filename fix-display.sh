#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display setup for Debian 13 GNOME Wayland.
# Kernel fixes the physical panel orientation; GNOME and GDM use normal
# rotation at 200% scale. Text scaling is reset to 100% to avoid double zoom.

VERSION="2026-08-03-scale-200-v1"
SCALE="${SCALE:-2.0}"
PANEL_ORIENTATION="${PANEL_ORIENTATION:-left_side_up}"

case "$PANEL_ORIENTATION" in
  normal|upside_down|left_side_up|right_side_up) ;;
  *)
    echo "Invalid PANEL_ORIENTATION: $PANEL_ORIENTATION" >&2
    exit 2
    ;;
esac

if [[ ${EUID} -eq 0 ]]; then
  echo "Run this script as your normal GNOME user, not with sudo." >&2
  exit 1
fi

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required." >&2
  exit 1
}

sudo -v

echo "OneMix display setup: $VERSION"
echo "Scale: $SCALE (200% by default)"
echo "Panel orientation: $PANEL_ORIENTATION"

packages=(python3 grub2-common dconf-cli mutter-common-bin)
missing=()
for package in "${packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
    missing+=("$package")
  fi
done

if ((${#missing[@]})); then
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
fi

connector=""
for status_file in /sys/class/drm/card*-eDP-*/status /sys/class/drm/card*-DSI-*/status; do
  [[ -e "$status_file" ]] || continue
  if [[ "$(cat "$status_file")" == connected ]]; then
    drm_name="$(basename "$(dirname "$status_file")")"
    connector="${drm_name#*-}"
    break
  fi
done

if [[ -z "$connector" ]]; then
  echo "Could not detect the internal display connector." >&2
  exit 1
fi

kernel_arg="video=${connector}:panel_orientation=${PANEL_ORIENTATION}"
echo "Connector: $connector"
echo "Kernel argument: $kernel_arg"

# Keep the working kernel-level panel orientation in GRUB.
grub_file=/etc/default/grub
sudo cp -a "$grub_file" "${grub_file}.onemix-backup.$(date +%Y%m%d-%H%M%S)"
tmp_grub="$(mktemp)"
trap 'rm -f "$tmp_grub"' EXIT

python3 - "$grub_file" "$tmp_grub" "$connector" "$kernel_arg" <<'PY'
import re
import shlex
import sys

source, destination, connector, new_arg = sys.argv[1:]
lines = open(source, encoding='utf-8').read().splitlines()
key = 'GRUB_CMDLINE_LINUX_DEFAULT'
found = False
result = []

for line in lines:
    match = re.match(r'^(\s*' + re.escape(key) + r'\s*=\s*)(.*)$', line)
    if not match:
        result.append(line)
        continue

    found = True
    prefix, raw = match.groups()
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        raw = raw[1:-1]

    try:
        tokens = shlex.split(raw)
    except ValueError:
        tokens = raw.split()

    tokens = [
        token for token in tokens
        if not (token.startswith(f'video={connector}:') and 'panel_orientation=' in token)
    ]
    tokens.append(new_arg)
    value = ' '.join(tokens).replace('\\', '\\\\').replace('"', '\\"')
    result.append(f'{prefix}"{value}"')

if not found:
    result.append(f'{key}="{new_arg}"')

open(destination, 'w', encoding='utf-8').write('\n'.join(result) + '\n')
PY

sudo install -m 0644 "$tmp_grub" "$grub_file"
sudo update-grub

# Prevent text/accessibility scaling from making 200% look larger than 200%.
gsettings set org.gnome.desktop.interface text-scaling-factor 1.0
if gsettings list-keys org.gnome.desktop.interface 2>/dev/null | grep -qx scaling-factor; then
  gsettings reset org.gnome.desktop.interface scaling-factor || true
fi

# Enable fractional monitor scaling without discarding unrelated features.
if gsettings list-keys org.gnome.mutter 2>/dev/null | grep -qx experimental-features; then
  current="$(gsettings get org.gnome.mutter experimental-features)"
  if [[ "$current" != *scale-monitor-framebuffer* ]]; then
    merged="$(python3 - "$current" <<'PY'
import ast
import sys
raw = sys.argv[1].strip()
if raw.startswith('@as '):
    raw = raw[4:]
try:
    values = list(ast.literal_eval(raw))
except Exception:
    values = []
if 'scale-monitor-framebuffer' not in values:
    values.append('scale-monitor-framebuffer')
print('[' + ', '.join(repr(v) for v in values) + ']')
PY
)"
    gsettings set org.gnome.mutter experimental-features "$merged"
  fi
fi

# Kernel supplies the physical panel orientation, so Mutter must use transform 0.
args=(
  --layout-mode logical
  --logical-monitor
  --primary
  --scale "$SCALE"
  --transform 0
  --monitor "$connector"
)

if ! gdctl set --verify "${args[@]}"; then
  echo "Mutter rejected scale $SCALE for this display." >&2
  gdctl show -m >&2
  exit 1
fi

gdctl set --persistent "${args[@]}"

monitor_file="$HOME/.config/monitors.xml"
for _ in {1..100}; do
  [[ -s "$monitor_file" ]] && grep -Eq '<scale>2(\.0+)?</scale>' "$monitor_file" && break
  sleep 0.1
done

if [[ ! -s "$monitor_file" ]] || ! grep -Eq '<scale>2(\.0+)?</scale>' "$monitor_file"; then
  echo "GNOME did not save a 200% monitors.xml." >&2
  grep -E '<scale>|<rotation>' "$monitor_file" >&2 || true
  exit 1
fi

# Lock sensor rotation; the kernel property is now the single source of truth.
if systemctl list-unit-files 2>/dev/null | grep -q '^iio-sensor-proxy\.service'; then
  sudo systemctl mask --now iio-sensor-proxy.service || true
fi

# Configure Debian's GDM greeter database.
greeter_file=/etc/gdm3/greeter.dconf-defaults
sudo cp -a "$greeter_file" "${greeter_file}.onemix-backup.$(date +%Y%m%d-%H%M%S)"
tmp_greeter="$(mktemp)"

python3 - "$greeter_file" "$tmp_greeter" <<'PY'
import re
import sys

source, destination = sys.argv[1:]
lines = open(source, encoding='utf-8').read().splitlines()
managed = {
    'org/gnome/mutter': {
        'experimental-features': "['scale-monitor-framebuffer']",
    },
    'org/gnome/settings-daemon/peripherals/touchscreen': {
        'orientation-lock': 'true',
    },
    'org/gnome/desktop/interface': {
        'text-scaling-factor': '1.0',
    },
}

current = None
cleaned = []
for line in lines:
    section = re.match(r'^\s*\[([^]]+)\]\s*$', line)
    if section:
        current = section.group(1)
        cleaned.append(line)
        continue
    key = re.match(r'^\s*([A-Za-z0-9_-]+)\s*=.*$', line)
    if current in managed and key and key.group(1) in managed[current]:
        continue
    cleaned.append(line)

for section, values in managed.items():
    cleaned.extend(['', f'[{section}]'])
    cleaned.extend(f'{key}={value}' for key, value in values.items())

open(destination, 'w', encoding='utf-8').write('\n'.join(cleaned) + '\n')
PY

sudo install -m 0644 "$tmp_greeter" "$greeter_file"
rm -f "$tmp_greeter"

gdm_user=""
for candidate in Debian-gdm gdm; do
  if id "$candidate" >/dev/null 2>&1; then
    gdm_user="$candidate"
    break
  fi
done

if [[ -z "$gdm_user" ]]; then
  echo "Could not find the GDM system user." >&2
  exit 1
fi

gdm_group="$(id -gn "$gdm_user")"
gdm_home="$(getent passwd "$gdm_user" | cut -d: -f6)"
[[ -n "$gdm_home" ]] || gdm_home=/var/lib/gdm3

sudo rm -f \
  /etc/xdg/monitors.xml \
  /var/lib/gdm3/.config/monitors.xml \
  /var/lib/gdm/.config/monitors.xml \
  "$gdm_home/.config/monitors.xml"

sudo install -D -m 0644 "$monitor_file" /etc/xdg/monitors.xml
sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" "$gdm_home/.config"
sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
  "$monitor_file" "$gdm_home/.config/monitors.xml"

if [[ -x /usr/share/gdm/generate-config ]]; then
  sudo /usr/share/gdm/generate-config
fi

echo
echo "Applied values:"
echo "  monitor scale: 200%"
echo "  text scale: 100%"
echo "  logical workspace on a 2560x1600 panel: approximately 1280x800"

echo
if grep -Fq "$kernel_arg" /proc/cmdline; then
  echo "Kernel orientation is already active."
  echo "Desktop scale has changed now."
  echo "To reload the login screen, save your work and run: sudo systemctl restart gdm3"
else
  echo "Kernel orientation is not active in this boot. Run: sudo reboot"
fi
