#!/bin/bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Can quyen root. Chay bang: su -c 'bash $0'"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Khong tim thay /etc/os-release."
  exit 1
fi

. /etc/os-release
if [[ ${ID:-} != debian ]]; then
  echo "Script nay chi danh cho Debian."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "==> Chuan bi kho phan mem Debian..."
/usr/bin/apt-get update
if ! /usr/bin/apt-cache show firmware-iwlwifi >/dev/null 2>&1; then
  debian_suite=${VERSION_CODENAME:-trixie}
  /usr/bin/cat > /etc/apt/sources.list.d/onemix3-non-free-firmware.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${debian_suite} ${debian_suite}-updates
Components: non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${debian_suite}-security
Components: non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  /usr/bin/apt-get update
fi

/usr/bin/apt-get install -y --no-install-recommends ca-certificates curl gnupg

echo "==> Them kho Google Chrome..."
/usr/bin/install -d -m 0755 /etc/apt/keyrings
/usr/bin/curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | /usr/bin/gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
/usr/bin/chmod 0644 /etc/apt/keyrings/google-chrome.gpg
/usr/bin/printf '%s\n' \
  'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' \
  > /etc/apt/sources.list.d/google-chrome.list
/usr/bin/apt-get update

echo "==> Cai GNOME Wayland toi gian..."
/usr/bin/apt-get install -y --no-install-recommends \
  sudo \
  gdm3 gnome-shell gnome-session gnome-control-center \
  nautilus gnome-console \
  network-manager network-manager-gnome \
  gnome-keyring libpam-gnome-keyring \
  pipewire-audio xdg-desktop-portal-gnome \
  power-profiles-daemon thermald iio-sensor-proxy \
  intel-microcode firmware-intel-graphics intel-media-va-driver \
  firmware-iwlwifi wireless-regdb wpasupplicant iw rfkill kmod \
  iproute2 pciutils \
  ibus ibus-unikey im-config \
  google-chrome-stable

# Neu may tung chay script cu, bo TLP de GNOME tu quan ly power profile.
if /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' tlp 2>/dev/null \
  | /usr/bin/grep -q '^ii'; then
  echo "==> Go TLP va tra quyen quan ly pin ve GNOME..."
  /usr/bin/apt-get purge -y tlp tlp-rdw || true
fi

/usr/bin/systemctl unmask power-profiles-daemon.service 2>/dev/null || true
/usr/bin/systemctl enable power-profiles-daemon.service

echo "==> Cau hinh tai khoan sudo va IBus Unikey..."
target_user=${SUDO_USER:-}
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(/usr/bin/logname 2>/dev/null || true)
fi
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(/usr/bin/getent passwd \
    | /usr/bin/awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }')
fi

if [[ -n ${target_user} && ${target_user} != root ]] \
  && /usr/bin/id "${target_user}" >/dev/null 2>&1; then
  /usr/sbin/usermod -aG sudo "${target_user}"
  /usr/sbin/runuser -u "${target_user}" -- /usr/bin/im-config -n ibus
else
  echo "CANH BAO: Khong tim thay user thuong de them vao nhom sudo."
fi

echo "==> Sua huong cam bien OneMix 3..."
/usr/bin/install -d -m 0755 /etc/udev/hwdb.d
/usr/bin/cat > /etc/udev/hwdb.d/61-onemix3-sensor.hwdb <<'EOF'
sensor:modalias:acpi:BOSC0200:*:dmi:*
 ACCEL_MOUNT_MATRIX=-1, 0, 0; 0, 1, 0; 0, 0, 1
EOF
/usr/bin/systemd-hwdb update
/usr/bin/udevadm trigger --subsystem-match=iio --action=change || true

echo "==> Cau hinh Intel AC-3165 cho do on dinh..."
/usr/bin/install -d -m 0755 /etc/NetworkManager/conf.d /etc/modprobe.d
/usr/bin/cat > /etc/NetworkManager/conf.d/10-onemix3-wifi.conf <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.powersave=2
EOF
/usr/bin/printf '%s\n' 'options iwlwifi power_save=0' \
  > /etc/modprobe.d/iwlwifi-onemix3.conf

# Tu phuc hoi Wi-Fi sau boot; chi dung khi da thay access point thuc su.
/usr/bin/install -m 0755 /dev/null /usr/local/sbin/onemix3-wifi-init
/usr/bin/cat > /usr/local/sbin/onemix3-wifi-init <<'EOF'
#!/bin/bash
set -u

/usr/bin/timeout 5s /usr/sbin/rfkill unblock all || true
/usr/bin/timeout 10s /usr/sbin/modprobe iwlwifi || true
/usr/bin/udevadm settle --timeout=10 || true
/usr/bin/timeout 8s /usr/bin/nmcli -w 5 radio wifi on || true

wifi_seen=0
wifi_ready=0
for recovery_try in 1 2; do
  for wifi_path in /sys/class/net/*; do
    [[ -d ${wifi_path}/wireless ]] || continue
    wifi_iface=${wifi_path##*/}
    wifi_seen=1
    /usr/bin/timeout 8s /usr/bin/nmcli -w 5 device set "${wifi_iface}" managed yes || true
    /usr/sbin/ip link set "${wifi_iface}" up || true
    if [[ -w ${wifi_path}/device/power/control ]]; then
      echo on > "${wifi_path}/device/power/control"
    fi

    wifi_state=$(/usr/bin/timeout 5s /usr/bin/nmcli -g GENERAL.STATE \
      device show "${wifi_iface}" 2>/dev/null || true)
    wifi_state_code=${wifi_state%% *}
    if [[ ${wifi_state_code} =~ ^[0-9]+$ ]] && ((wifi_state_code >= 30)); then
      if /usr/bin/timeout 12s /usr/bin/nmcli -w 8 \
        device wifi rescan ifname "${wifi_iface}"; then
        /usr/bin/sleep 3
        wifi_bssids=$(/usr/bin/timeout 8s /usr/bin/nmcli -g BSSID \
          device wifi list ifname "${wifi_iface}" 2>/dev/null || true)
        if [[ -n ${wifi_bssids} ]]; then
          wifi_ready=1
          break 2
        fi
      fi
    fi
  done

  if [[ ${recovery_try} -eq 1 ]]; then
    /usr/bin/systemctl restart NetworkManager
    /usr/bin/sleep 5
    /usr/bin/timeout 8s /usr/bin/nmcli -w 5 radio wifi on || true
  fi
done

if [[ ${wifi_ready} -eq 1 ]]; then
  echo "OneMix 3 Wi-Fi ready"
  /usr/bin/systemctl stop onemix3-wifi-init.timer 2>/dev/null || true
elif [[ ${wifi_seen} -eq 1 ]]; then
  echo "OneMix 3 Wi-Fi unavailable; retry scheduled"
else
  echo "OneMix 3 Wi-Fi interface missing; retry scheduled"
fi
exit 0
EOF

/usr/bin/cat > /etc/systemd/system/onemix3-wifi-init.service <<'EOF'
[Unit]
Description=Recover and scan OneMix 3 Intel Wi-Fi
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/onemix3-wifi-init
TimeoutStartSec=75
EOF

/usr/bin/cat > /etc/systemd/system/onemix3-wifi-init.timer <<'EOF'
[Unit]
Description=Retry OneMix 3 Wi-Fi initialization after boot

[Timer]
OnBootSec=8s
OnUnitInactiveSec=20s
AccuracySec=2s
Unit=onemix3-wifi-init.service

[Install]
WantedBy=timers.target
EOF

echo "==> Bat cac dich vu..."
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable NetworkManager gdm3 thermald \
  power-profiles-daemon onemix3-wifi-init.timer
/usr/bin/systemctl set-default graphical.target
/usr/bin/systemctl restart --no-block wpa_supplicant || true
/usr/bin/systemctl restart NetworkManager
/usr/bin/systemctl restart power-profiles-daemon || true

# Thu phuc hoi ngay trong lan cai dat nay.
/usr/bin/systemctl start onemix3-wifi-init.service || true

if [[ -n ${target_user} && ${target_user} != root ]] \
  && /usr/bin/id "${target_user}" >/dev/null 2>&1; then
  /usr/sbin/runuser -u "${target_user}" -- \
    /usr/bin/dbus-run-session -- /bin/bash -c '
      /usr/bin/gsettings set org.gnome.desktop.input-sources sources "[(\"xkb\", \"us\"), (\"ibus\", \"Unikey\")]"
      /usr/bin/gsettings set org.gnome.desktop.input-sources mru-sources "[(\"xkb\", \"us\"), (\"ibus\", \"Unikey\")]"
    '
fi

echo
echo "HOAN TAT. Reboot bang: sudo reboot"
echo "GNOME Power Mode: Settings > Power > Power Mode"
echo "Kiem tra Wayland: echo \$XDG_SESSION_TYPE"
echo "Danh sach Wi-Fi: nmcli device wifi list"
