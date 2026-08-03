#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display fix for Debian 13 GNOME Wayland.
# Version: 2026-08-03-gdm-v2
# - Rotates the built-in portrait panel to landscape.
# - Keeps the native panel mode fullscreen.
# - Uses 250% scaling.
# - Recreates monitors.xml before copying it to GDM, preventing stale settings.

SCRIPT_VERSION="2026-08-03-gdm-v2"
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
printf 'Requested rotation: %s degrees\n' "$ROTATION"
printf 'Requested scale: %s (250%%)\n' "$SCALE"

sudo -v

if ! command -v gdctl >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y mutter-common-bin
fi

if ! command -v dconf >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y dconf-cli
fi

# Enable fractional scaling for the current GNOME user.
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

# Stop the accelerometer from overriding the selected rotation.
if gsettings list-schemas | grep -qx org.gnome.settings-daemon.peripherals.touchscreen; then
  gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true || true
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

# Verify before removing the old persistent file.
if ! gdctl set --verify "${args[@]}"; then
  echo "Mutter rejected this scale or rotation." >&2
  gdctl show -m >&2
  exit 1
fi

config_dir="$HOME/.config"
monitor_file="$config_dir/monitors.xml"
backup_file=""
mkdir -p "$config_dir"

if [[ -f "$monitor_file" ]]; then
  backup_file="$monitor_file.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$monitor_file" "$backup_file"
fi

# Important: remove the old file first. The previous script saw the existing
# file and copied it to GDM before Mutter had finished writing the new values.
rm -f "$monitor_file"

if ! gdctl set --persistent "${args[@]}"; then
  [[ -n "$backup_file" ]] && cp -a "$backup_file" "$monitor_file"
  echo "Failed to apply the display configuration." >&2
  exit 1
fi

# Wait for Mutter to create a genuinely new file containing scale 2.5.
for _ in {1..100}; do
  if [[ -s "$monitor_file" ]] && grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file"; then
    break
  fi
  sleep 0.1
done

if [[ ! -s "$monitor_file" ]]; then
  [[ -n "$backup_file" ]] && cp -a "$backup_file" "$monitor_file"
  echo "Mutter did not create a new monitors.xml." >&2
  exit 1
fi

if ! grep -Eq '<scale>2\.5(0*)?</scale>' "$monitor_file"; then
  echo "The new monitors.xml does not contain scale 2.5; refusing to copy it to GDM." >&2
  grep -E '<scale>|<rotation>' "$monitor_file" >&2 || true
  exit 1
fi

# Configure fractional scaling in the GDM dconf database.
sudo install -d -m 0755 /etc/dconf/profile /etc/dconf/db/gdm.d

if [[ ! -f /etc/dconf/profile/gdm ]]; then
  sudo tee /etc/dconf/profile/gdm >/dev/null <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
fi

sudo tee /etc/dconf/db/gdm.d/00-onemix-display >/dev/null <<'EOF'
[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
EOF
sudo dconf update

# Replace every known stale GDM monitor file with the newly generated file.
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

sudo rm -f \
  /etc/xdg/monitors.xml \
  /var/lib/gdm3/.config/monitors.xml \
  /var/lib/gdm/.config/monitors.xml \
  "$gdm_home/.config/monitors.xml"

sudo install -D -m 0644 "$monitor_file" /etc/xdg/monitors.xml
sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" "$gdm_home/.config"
sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
  "$monitor_file" "$gdm_home/.config/monitors.xml"

# Debian normally uses /var/lib/gdm3. Install there explicitly as well when
# it differs from the passwd database home.
if [[ "$gdm_home" != /var/lib/gdm3 ]]; then
  sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" /var/lib/gdm3/.config
  sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
    "$monitor_file" /var/lib/gdm3/.config/monitors.xml
fi

echo
echo "Fresh desktop configuration:"
grep -E '<scale>|<rotation>|<flipped>' "$monitor_file" || true

echo
echo "Fresh GDM configuration:"
sudo grep -E '<scale>|<rotation>|<flipped>' "$gdm_home/.config/monitors.xml" || true

echo
echo "Done: rotation $ROTATION, scale 250%, logical workspace $TARGET_LOGICAL."
echo "Log out once to start a new GDM greeter with the fresh configuration."
echo "No reboot and no automatic GDM restart were performed."
