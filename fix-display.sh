#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display fix for Debian 13 GNOME Wayland.
# - Uses the panel's native 1600x2560 mode so the image fills the display.
# - Rotates the portrait-mounted panel to landscape.
# - Uses 4/3 fractional scaling, giving a 1920x1200 logical desktop.
# - Copies the resulting monitor configuration to GDM.

ROTATION="${1:-90}"           # 90 = rotate right; correct when 270 is upside down.
SCALE="${SCALE:-1.3333333333333333}"
TARGET_LOGICAL="1920x1200"

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
  echo "The script will ask for sudo only when it needs system access." >&2
  exit 1
fi

if [[ ${XDG_SESSION_TYPE:-} != wayland ]]; then
  echo "Warning: this is intended for a GNOME Wayland session." >&2
fi

if [[ ${XDG_CURRENT_DESKTOP:-} != *GNOME* ]]; then
  echo "Warning: GNOME was not detected in XDG_CURRENT_DESKTOP." >&2
fi

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required." >&2
  exit 1
}

sudo -v

if ! command -v gdctl >/dev/null 2>&1; then
  echo "Installing gdctl..."
  sudo apt-get update
  sudo apt-get install -y mutter-common-bin
fi

# Enable Mutter's fractional monitor scaling without removing other features.
if gsettings list-keys org.gnome.mutter 2>/dev/null | grep -qx experimental-features; then
  current_features="$(gsettings get org.gnome.mutter experimental-features)"
  if [[ "$current_features" != *"scale-monitor-framebuffer"* ]]; then
    merged_features="$({ python3 - "$current_features" <<'PY'
import ast
import sys

raw = sys.argv[1].strip()
if raw.startswith("@as "):
    raw = raw[4:]
try:
    values = list(ast.literal_eval(raw))
except Exception:
    values = []
if "scale-monitor-framebuffer" not in values:
    values.append("scale-monitor-framebuffer")
print("[" + ", ".join(repr(v) for v in values) + "]")
PY
    })"
    gsettings set org.gnome.mutter experimental-features "$merged_features"
  fi
fi

# Prevent the accelerometer from immediately changing the chosen orientation.
if gsettings list-schemas | grep -qx org.gnome.settings-daemon.peripherals.touchscreen; then
  gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true || true
fi

show_output="$(gdctl show)"

# Prefer Mutter's explicit built-in-display label.
connector="$(printf '%s\n' "$show_output" \
  | sed -nE 's/.*Monitor ([^ ]+) \(Built-in display\).*/\1/p' \
  | head -n1)"

# Fall back to an active eDP/DSI connector from sysfs.
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
  echo "Run 'gdctl show -m' and retry with the connector available." >&2
  exit 1
fi

echo "Internal display: $connector"
echo "Rotation: $ROTATION degrees"
echo "Scale: $SCALE (logical target: $TARGET_LOGICAL)"

config_dir="$HOME/.config"
monitor_file="$config_dir/monitors.xml"
mkdir -p "$config_dir"

if [[ -f "$monitor_file" ]]; then
  cp -a "$monitor_file" "$monitor_file.backup.$(date +%Y%m%d-%H%M%S)"
fi

common_args=(
  --layout-mode logical
  --logical-monitor
  --primary
  --scale "$SCALE"
  --transform "$ROTATION"
  --monitor "$connector"
)

# Verify first so a rejected scale/rotation cannot replace the working setup.
if ! gdctl set --verify "${common_args[@]}"; then
  echo >&2
  echo "Mutter rejected this display configuration." >&2
  echo "Available modes and supported scales:" >&2
  gdctl show -m >&2
  exit 1
fi

gdctl set --persistent "${common_args[@]}"

# Mutter normally writes this immediately, but allow a moment on slower systems.
for _ in {1..20}; do
  [[ -s "$monitor_file" ]] && break
  sleep 0.1
done

if [[ ! -s "$monitor_file" ]]; then
  echo "The display changed, but Mutter did not create $monitor_file." >&2
  echo "Open Settings -> Displays, press Apply once, then rerun this script." >&2
  exit 1
fi

# Current Mutter/GDM can read a global monitor configuration from /etc/xdg.
sudo install -D -m 0644 "$monitor_file" /etc/xdg/monitors.xml

# Keep the Debian GDM user copy too, for compatibility with GDM installations
# that still read the per-user path.
gdm_user=""
for candidate in Debian-gdm gdm; do
  if id "$candidate" >/dev/null 2>&1; then
    gdm_user="$candidate"
    break
  fi
done

if [[ -n "$gdm_user" ]]; then
  gdm_group="$(id -gn "$gdm_user")"
  gdm_home="$(getent passwd "$gdm_user" | cut -d: -f6)"
  [[ -n "$gdm_home" ]] || gdm_home=/var/lib/gdm3

  sudo install -d -m 0700 -o "$gdm_user" -g "$gdm_group" "$gdm_home/.config"
  sudo install -m 0600 -o "$gdm_user" -g "$gdm_group" \
    "$monitor_file" "$gdm_home/.config/monitors.xml"

  # Fractional scale must also be understood by the GDM session. This is
  # best-effort because some systems do not expose a writable GDM dconf DB.
  if command -v dbus-run-session >/dev/null 2>&1; then
    sudo -H -u "$gdm_user" dbus-run-session -- \
      gsettings set org.gnome.mutter experimental-features \
      "['scale-monitor-framebuffer']" >/dev/null 2>&1 || true
  fi
fi

echo
echo "Done. The desktop now uses the native panel fullscreen with a $TARGET_LOGICAL logical workspace."
echo "Log out once to make the GDM login screen use the same rotation and scale."
echo "No reboot or automatic GDM restart was performed."
