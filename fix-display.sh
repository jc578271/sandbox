#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display fix for Debian 13 GNOME Wayland.
# Version: 2026-08-03-gdm-v4
# Desktop and GDM intentionally use opposite rotations because the OneMix
# panel orientation is interpreted differently by the GDM greeter.

SCRIPT_VERSION="2026-08-03-gdm-v4"
ROTATION="${1:-90}"
SCALE="${SCALE:-2.5}"
TARGET_LOGICAL="1024x640"

case "$ROTATION" in
  left) ROTATION=270 ;;
  right) ROTATION=90 ;;
  inverted|upside-down) ROTATION=180 ;;
  normal) ROTATION=0 ;;
  0|90|180|270) ;;
  *)
    echo "Usage: $0 [left|right|normal|0|90|180|270]" >&2
    exit 2
    ;;
esac

case "$ROTATION" in
  0) GDM_ROTATION=180 ;;
  90) GDM_ROTATION=270 ;;
  180) GDM_ROTATION=0 ;;
  270) GDM_ROTATION=90 ;;
esac

if [[ ${EUID} -eq 0 ]]; then
  echo "Run this script as your normal GNOME user, not with sudo." >&2
  exit 1
fi

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required." >&2
  exit 1
}

printf 'OneMix display setup: %s\n' "$SCRIPT_VERSION"
printf 'Desktop rotation: %s degrees\n' "$ROTATION"
printf 'GDM rotation: %s degrees\n' "$GDM_ROTATION"
printf 'Scale: %s (250%%)\n' "$SCALE"

sudo -v

packages=(mutter-common-bin dconf-cli python3)
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

# Prevent the accelerometer from changing either session after configuration.
if systemctl list-unit-files 2>/dev/null | grep -q '^iio-sensor-proxy\.service'; then
  sudo systemctl mask --now iio-sensor-proxy.service || true
fi
if gsettings list-schemas | grep -qx org.gnome.settings-daemon.peripherals.touchscreen; then
  gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true || true
fi

# Enable fractional scaling for the current desktop user.
if gsettings list-keys org.gnome.mutter 2>/dev/null | grep -qx experimental-features; then
  current="$(gsettings get org.gnome.mutter experimental-features)"
  if [[ "$current" != *scale-monitor-framebuffer* ]]; then
    merged="$(python3 - "$current" <<'PY'
import ast, sys
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

show_output="$(gdctl show)"
connector="$(printf '%s\n' "$show_output" \
  | sed -nE 's/.*Monitor ([^ ]+) \(Built-in display\).*/\1/p' \
  | head -n1)"

if [[ -z "$connector" ]]; then
  for status_file in /sys/class/drm/card*-eDP-*/status /sys/class/drm/card*-DSI-*/status; do
    [[ -e "$status_file" ]] || continue
    if [[ "$(cat "$status_file")" == connected ]]; then
      drm_name="$(basename "$(dirname "$status_file")")"
      connector="${drm_name#*-}"
      break
    fi
  done
fi

if [[ -z "$connector" ]]; then
  echo "Could not detect the internal display connector." >&2
  gdctl show -m >&2
  exit 1
fi
printf 'Internal display: %s\n' "$connector"

args=(
  --layout-mode logical
  --logical-monitor
  --primary
  --scale "$SCALE"
  --transform "$ROTATION"
  --monitor "$connector"
)

if ! gdctl set --verify "${args[@]}"; then
  echo "Mutter rejected this scale or desktop rotation." >&2
  gdctl show -m >&2
  exit 1
fi

monitor_file="$HOME/.config/monitors.xml"
mkdir -p "$HOME/.config"
[[ -f "$monitor_file" ]] && cp -a "$monitor_file" "$monitor_file.backup.$(date +%Y%m%d-%H%M%S)"
rm -f "$monitor_file"
gdctl set --persistent "${args[@]}"

for _ in {1..100}; do
  [[ -s "$monitor_file" ]] && grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file" && break
  sleep 0.1
done

if [[ ! -s "$monitor_file" ]] || ! grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file"; then
  echo "Mutter did not create a valid 250% monitors.xml." >&2
  exit 1
fi

# Create a separate GDM XML. The login greeter on this OneMix needs the
# opposite 180-degree landscape transform from the desktop session.
gdm_monitor_file="$(mktemp)"
trap 'rm -f "$gdm_monitor_file"' EXIT

python3 - "$monitor_file" "$gdm_monitor_file" "$GDM_ROTATION" <<'PY'
import sys
import xml.etree.ElementTree as ET

source, destination, degrees = sys.argv[1:]
rotation_by_degrees = {
    '0': 'normal',
    '90': 'right',
    '180': 'upside_down',
    '270': 'left',
}
rotation = rotation_by_degrees[degrees]

tree = ET.parse(source)
root = tree.getroot()
logical_monitors = root.findall('.//logicalmonitor')
if not logical_monitors:
    raise SystemExit('No logicalmonitor found in monitors.xml')

for logical in logical_monitors:
    transform = logical.find('transform')
    if transform is None:
        transform = ET.SubElement(logical, 'transform')
    rotation_node = transform.find('rotation')
    if rotation_node is None:
        rotation_node = ET.SubElement(transform, 'rotation')
    rotation_node.text = rotation
    flipped = transform.find('flipped')
    if flipped is None:
        flipped = ET.SubElement(transform, 'flipped')
    flipped.text = 'no'

tree.write(destination, encoding='utf-8', xml_declaration=True)
PY

# GDM has its own dconf profile.
sudo install -d -m 0755 /etc/dconf/profile /etc/dconf/db/gdm.d /etc/dconf/db/gdm.d/locks
sudo tee /etc/dconf/profile/gdm >/dev/null <<'EOF_GDM_PROFILE'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF_GDM_PROFILE
sudo tee /etc/dconf/db/gdm.d/00-onemix-display >/dev/null <<'EOF_GDM_CONF'
[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']

[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=true
EOF_GDM_CONF
sudo tee /etc/dconf/db/gdm.d/locks/00-onemix-display >/dev/null <<'EOF_GDM_LOCK'
/org/gnome/settings-daemon/peripherals/touchscreen/orientation-lock
EOF_GDM_LOCK
sudo dconf update

gdm_user=""
for candidate in Debian-gdm gdm; do
  if id "$candidate" >/dev/null 2>&1; then
    gdm_user="$candidate"
    break
  fi
done
[[ -n "$gdm_user" ]] || { echo "Could not find the GDM user." >&2; exit 1; }

gdm_group="$(id -gn "$gdm_user")"
gdm_home="$(getent passwd "$gdm_user" | cut -d: -f6)"
[[ -n "$gdm_home" ]] || gdm_home=/var/lib/gdm3

# Remove all stale copies. /etc/xdg is deliberately populated with the
# GDM-specific transform, while the logged-in user keeps ~/.config/monitors.xml.
sudo rm -f \
  /etc/xdg/monitors.xml \
  /var/lib/gdm3/.config/monitors.xml \
  /var/lib/gdm/.config/monitors.xml \
  "$gdm_home/.config/monitors.xml" \
  "$gdm_home/.config/dconf/user"

sudo install -D -m 0644 "$gdm_monitor_file" /etc/xdg/monitors.xml
sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" "$gdm_home/.config"
sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
  "$gdm_monitor_file" "$gdm_home/.config/monitors.xml"

if [[ "$gdm_home" != /var/lib/gdm3 ]]; then
  sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" /var/lib/gdm3/.config
  sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
    "$gdm_monitor_file" /var/lib/gdm3/.config/monitors.xml
fi

echo
echo "Desktop monitors.xml:"
grep -E '<scale>|<rotation>|<flipped>' "$monitor_file" || true

echo
echo "GDM monitors.xml (intentionally opposite rotation):"
grep -E '<scale>|<rotation>|<flipped>' "$gdm_monitor_file" || true

echo
echo "Done. Desktop rotation=$ROTATION, GDM rotation=$GDM_ROTATION, scale=250%."
echo "Save your work, then restart GDM: sudo systemctl restart gdm3"
