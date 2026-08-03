#!/usr/bin/env bash
set -Eeuo pipefail

# OneMix 3 / OneMix 3 Pro display fix for Debian 13 GNOME Wayland.
# Version: 2026-08-03-kernel-orientation-v1
#
# The firmware reports the portrait-mounted panel orientation incorrectly.
# Fix it before GDM starts by adding a DRM panel_orientation override to GRUB.
# GNOME and GDM then use rotation=normal, with 250% scale.

SCRIPT_VERSION="2026-08-03-kernel-orientation-v1"
SCALE="${SCALE:-2.5}"
PANEL_ORIENTATION="${PANEL_ORIENTATION:-left_side_up}"

case "$PANEL_ORIENTATION" in
  normal|upside_down|left_side_up|right_side_up) ;;
  *)
    echo "Invalid PANEL_ORIENTATION: $PANEL_ORIENTATION" >&2
    echo "Use normal, upside_down, left_side_up, or right_side_up." >&2
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

echo "OneMix display setup: $SCRIPT_VERSION"
echo "Kernel panel orientation: $PANEL_ORIENTATION"
echo "GNOME/GDM scale: $SCALE"

packages=(python3 grub2-common dconf-cli)
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

# Detect the connected internal panel connector, normally eDP-1.
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
  echo "Could not detect the internal eDP/DSI connector." >&2
  ls -1 /sys/class/drm >&2 || true
  exit 1
fi

kernel_arg="video=${connector}:panel_orientation=${PANEL_ORIENTATION}"
echo "Connector: $connector"
echo "Kernel argument: $kernel_arg"

# Back up and update GRUB without duplicating old panel-orientation arguments.
grub_file=/etc/default/grub
grub_backup="${grub_file}.onemix-backup.$(date +%Y%m%d-%H%M%S)"
sudo cp -a "$grub_file" "$grub_backup"

tmp_grub="$(mktemp)"
trap 'rm -f "$tmp_grub"' EXIT

python3 - "$grub_file" "$tmp_grub" "$connector" "$kernel_arg" <<'PY'
import re
import shlex
import sys

source, destination, connector, new_arg = sys.argv[1:]
text = open(source, encoding='utf-8').read().splitlines()
key = 'GRUB_CMDLINE_LINUX_DEFAULT'
found = False
output = []

for line in text:
    match = re.match(r'^(\s*' + re.escape(key) + r'\s*=\s*)(.*)$', line)
    if not match:
        output.append(line)
        continue

    found = True
    prefix, raw = match.groups()
    try:
        parsed = shlex.split(raw, posix=True)
        value = parsed[0] if len(parsed) == 1 else raw.strip().strip('"\'')
    except ValueError:
        value = raw.strip().strip('"\'')

    tokens = shlex.split(value, posix=True)
    cleaned = []
    for token in tokens:
        if token.startswith(f'video={connector}:') and 'panel_orientation=' in token:
            continue
        cleaned.append(token)
    cleaned.append(new_arg)

    value = ' '.join(cleaned)
    value = value.replace('\\', '\\\\').replace('"', '\\"')
    output.append(f'{prefix}"{value}"')

if not found:
    output.append(f'{key}="{new_arg}"')

open(destination, 'w', encoding='utf-8').write('\n'.join(output) + '\n')
PY

sudo install -m 0644 "$tmp_grub" "$grub_file"
sudo update-grub

# The kernel override supplies the physical panel rotation, so persistent
# Mutter configuration must use normal rotation rather than adding another
# 90/270-degree transform.
monitor_file="$HOME/.config/monitors.xml"
if [[ ! -s "$monitor_file" ]]; then
  echo "Missing $monitor_file." >&2
  echo "Open Settings -> Displays, press Apply once, then rerun this script." >&2
  exit 1
fi

cp -a "$monitor_file" "$monitor_file.onemix-backup.$(date +%Y%m%d-%H%M%S)"

tmp_monitor="$(mktemp)"
python3 - "$monitor_file" "$tmp_monitor" "$SCALE" <<'PY'
import sys
import xml.etree.ElementTree as ET

source, destination, scale = sys.argv[1:]
tree = ET.parse(source)
root = tree.getroot()
logical_monitors = root.findall('.//logicalmonitor')
if not logical_monitors:
    raise SystemExit('No logicalmonitor found in monitors.xml')

for logical in logical_monitors:
    scale_node = logical.find('scale')
    if scale_node is None:
        scale_node = ET.SubElement(logical, 'scale')
    scale_node.text = scale

    transform = logical.find('transform')
    if transform is None:
        transform = ET.SubElement(logical, 'transform')

    rotation = transform.find('rotation')
    if rotation is None:
        rotation = ET.SubElement(transform, 'rotation')
    rotation.text = 'normal'

    flipped = transform.find('flipped')
    if flipped is None:
        flipped = ET.SubElement(transform, 'flipped')
    flipped.text = 'no'

tree.write(destination, encoding='utf-8', xml_declaration=True)
PY

install -m 0600 "$tmp_monitor" "$monitor_file"
rm -f "$tmp_monitor"

# Debian GDM reads greeter settings from /etc/gdm3/greeter.dconf-defaults.
# Enable fractional scaling and lock auto-rotation in that actual database.
greeter_file=/etc/gdm3/greeter.dconf-defaults
greeter_backup="${greeter_file}.onemix-backup.$(date +%Y%m%d-%H%M%S)"
sudo cp -a "$greeter_file" "$greeter_backup"

tmp_greeter="$(mktemp)"
python3 - "$greeter_file" "$tmp_greeter" <<'PY'
import re
import sys

source, destination = sys.argv[1:]
lines = open(source, encoding='utf-8').read().splitlines()
settings = {
    'org/gnome/mutter': {
        'experimental-features': "['scale-monitor-framebuffer']",
    },
    'org/gnome/settings-daemon/peripherals/touchscreen': {
        'orientation-lock': 'true',
    },
}

# Remove existing copies of the managed keys, preserving all unrelated lines.
current = None
cleaned = []
for line in lines:
    section = re.match(r'^\s*\[([^]]+)\]\s*$', line)
    if section:
        current = section.group(1)
        cleaned.append(line)
        continue
    key_match = re.match(r'^\s*([A-Za-z0-9_-]+)\s*=.*$', line)
    if current in settings and key_match and key_match.group(1) in settings[current]:
        continue
    cleaned.append(line)

for section, values in settings.items():
    cleaned.extend(['', f'[{section}]'])
    for key, value in values.items():
        cleaned.append(f'{key}={value}')

open(destination, 'w', encoding='utf-8').write('\n'.join(cleaned) + '\n')
PY

sudo install -m 0644 "$tmp_greeter" "$greeter_file"
rm -f "$tmp_greeter"

# Remove obsolete dconf snippets created by earlier versions of this script.
sudo rm -f \
  /etc/dconf/db/gdm.d/00-onemix-display \
  /etc/dconf/db/gdm.d/locks/00-onemix-display

# Stop the sensor from applying another rotation after the kernel property.
if systemctl list-unit-files 2>/dev/null | grep -q '^iio-sensor-proxy\.service'; then
  sudo systemctl mask --now iio-sensor-proxy.service || true
fi

# Install the same normal-rotation configuration for GDM.
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

# Debian recompiles this database when GDM starts; compile it now as well.
if [[ -x /usr/share/gdm/generate-config ]]; then
  sudo /usr/share/gdm/generate-config
fi

echo
echo "Installed kernel argument:"
grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file"

echo
echo "Persistent desktop/GDM monitor values:"
grep -E '<scale>|<rotation>|<flipped>' "$monitor_file" || true

echo
echo "Configuration written successfully."
echo "A FULL REBOOT is required because panel_orientation is a kernel option."
echo "The script did not reboot automatically. Run: sudo reboot"
