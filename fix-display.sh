#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display fix for Debian 13 GNOME Wayland.
# Version: 2026-08-03-gdm-v3
# - Desktop: rotate right, fullscreen native mode, scale 250%.
# - GDM: use the same monitors.xml and disable sensor-based auto rotation.

SCRIPT_VERSION="2026-08-03-gdm-v3"
ROTATION="${1:-90}"
SCALE="${SCALE:-2.5}"
TARGET_LOGICAL="1024x640"

case "$ROTATION" in
  left) ROTATION=270 ;;
  right) ROTATION=90 ;;
  inverted|upside-down) ROTATION=180 ;;
  normal|90|180|270) ;;
  *)
    echo "Usage: $0 [left|right|normal|90|180|270]" >&2
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

printf 'OneMix display setup: %s\n' "$SCRIPT_VERSION"
printf 'Rotation: %s degrees\n' "$ROTATION"
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

# Disable sensor-driven auto rotation system-wide. On this device the sensor
# can rotate the GDM greeter a second time after monitors.xml is applied.
if systemctl list-unit-files 2>/dev/null | grep -q '^iio-sensor-proxy\.service'; then
  sudo systemctl mask --now iio-sensor-proxy.service || true
fi

# Lock rotation for the current desktop session too.
if gsettings list-schemas | grep -qx org.gnome.settings-daemon.peripherals.touchscreen; then
  gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true || true
fi

# Enable fractional scaling for the current user without discarding other
# experimental Mutter features.
if gsettings list-keys org.gnome.mutter 2>/dev/null | grep -qx experimental-features; then
  current_features="$(gsettings get org.gnome.mutter experimental-features)"
  if [[ "$current_features" != *scale-monitor-framebuffer* ]]; then
    merged_features="$(python3 - "$current_features" <<'PY'
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
    gsettings set org.gnome.mutter experimental-features "$merged_features"
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
  echo "Mutter rejected this scale or rotation." >&2
  gdctl show -m >&2
  exit 1
fi

config_dir="$HOME/.config"
monitor_file="$config_dir/monitors.xml"
mkdir -p "$config_dir"

if [[ -f "$monitor_file" ]]; then
  cp -a "$monitor_file" "$monitor_file.backup.$(date +%Y%m%d-%H%M%S)"
fi

rm -f "$monitor_file"
gdctl set --persistent "${args[@]}"

for _ in {1..100}; do
  if [[ -s "$monitor_file" ]] && grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file"; then
    break
  fi
  sleep 0.1
done

if [[ ! -s "$monitor_file" ]]; then
  echo "Mutter did not create a new monitors.xml." >&2
  exit 1
fi

if ! grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file"; then
  echo "The new monitors.xml does not contain scale 2.5." >&2
  grep -E '<scale>|<rotation>|<flipped>' "$monitor_file" >&2 || true
  exit 1
fi

# Configure GDM's own dconf database. GDM uses a separate profile from the
# logged-in user, so orientation-lock must be set there as well.
sudo install -d -m 0755 \
  /etc/dconf/profile \
  /etc/dconf/db/gdm.d \
  /etc/dconf/db/gdm.d/locks

sudo tee /etc/dconf/profile/gdm >/dev/null <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF

sudo tee /etc/dconf/db/gdm.d/00-onemix-display >/dev/null <<'EOF'
[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']

[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=true
EOF

sudo tee /etc/dconf/db/gdm.d/locks/00-onemix-display >/dev/null <<'EOF'
/org/gnome/settings-daemon/peripherals/touchscreen/orientation-lock
EOF

sudo dconf update

gdm_user=""
for candidate in Debian-gdm gdm; do
  if id "$candidate" >/dev/null 2>&1; then
    gdm_user="$candidate"
    break
  fi
done

if [[ -z "$gdm_user" ]]; then
  echo "Could not find the Debian GDM user." >&2
  exit 1
fi

gdm_group="$(id -gn "$gdm_user")"
gdm_home="$(getent passwd "$gdm_user" | cut -d: -f6)"
[[ -n "$gdm_home" ]] || gdm_home=/var/lib/gdm3

# Remove stale monitor and dconf user caches that can override the system GDM
# database. The files are recreated automatically by GDM.
sudo rm -f \
  /etc/xdg/monitors.xml \
  /var/lib/gdm3/.config/monitors.xml \
  /var/lib/gdm/.config/monitors.xml \
  "$gdm_home/.config/monitors.xml" \
  "$gdm_home/.config/dconf/user"

sudo install -D -m 0644 "$monitor_file" /etc/xdg/monitors.xml
sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" "$gdm_home/.config"
sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
  "$monitor_file" "$gdm_home/.config/monitors.xml"

if [[ "$gdm_home" != /var/lib/gdm3 ]]; then
  sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" /var/lib/gdm3/.config
  sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
    "$monitor_file" /var/lib/gdm3/.config/monitors.xml
fi

echo
echo "Desktop configuration:"
grep -E '<scale>|<rotation>|<flipped>' "$monitor_file" || true

echo
echo "GDM configuration:"
sudo grep -E '<scale>|<rotation>|<flipped>' "$gdm_home/.config/monitors.xml" || true

echo
echo "Configuration complete: rotation $ROTATION, scale 250%, logical $TARGET_LOGICAL."
echo "IMPORTANT: GDM is already running, so log out alone may reuse the old greeter."
echo "Save your work, then run: sudo systemctl restart gdm3"
echo "That command immediately ends the current graphical session."
