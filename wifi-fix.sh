#!/bin/bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: /usr/bin/su -c '/bin/bash wifi-fix.sh'"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "==> Installing Intel Wi-Fi support..."
/usr/bin/apt-get update

if ! /usr/bin/apt-cache show firmware-iwlwifi >/dev/null 2>&1; then
  . /etc/os-release
  debian_suite=${VERSION_CODENAME:-trixie}
  /usr/bin/cat > /etc/apt/sources.list.d/wifi-non-free-firmware.sources <<EOF
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

/usr/bin/apt-get install -y --no-install-recommends \
  network-manager network-manager-gnome \
  gnome-keyring libpam-gnome-keyring \
  firmware-iwlwifi wireless-regdb \
  wpasupplicant iw rfkill kmod iproute2 pciutils

echo "==> Giving Wi-Fi control to NetworkManager..."
/usr/bin/install -d -m 0755 /etc/NetworkManager/conf.d
/usr/bin/printf '%s\n' \
  '[main]' \
  'plugins=ifupdown,keyfile' \
  '' \
  '[ifupdown]' \
  'managed=true' \
  '' \
  '[device]' \
  'wifi.scan-rand-mac-address=yes' \
  '' \
  '[connection]' \
  'wifi.powersave=2' \
  > /etc/NetworkManager/conf.d/10-wifi-fix.conf

/usr/bin/install -d -m 0755 /etc/modprobe.d
/usr/bin/printf '%s\n' 'options iwlwifi power_save=0' \
  > /etc/modprobe.d/iwlwifi-onemix3.conf

echo "==> Installing automatic Wi-Fi recovery for every boot..."
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

    wifi_state=$(/usr/bin/timeout 5s /usr/bin/nmcli -g GENERAL.STATE device show "${wifi_iface}" 2>/dev/null || true)
    wifi_state_code=${wifi_state%% *}
    if [[ ${wifi_state_code} =~ ^[0-9]+$ ]] && ((wifi_state_code >= 30)); then
      if /usr/bin/timeout 12s /usr/bin/nmcli -w 8 device wifi rescan ifname "${wifi_iface}"; then
        wifi_ready=1
        break 2
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
  echo "OneMix 3 Wi-Fi detected but unavailable; retry scheduled"
else
  echo "OneMix 3 Wi-Fi interface not found; retry scheduled"
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
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable onemix3-wifi-init.timer

/usr/bin/timeout 5s /usr/sbin/rfkill unblock all || true
/usr/bin/timeout 10s /usr/sbin/modprobe iwlwifi || true
/usr/bin/udevadm settle --timeout=10 || true

/usr/bin/systemctl enable NetworkManager
/usr/bin/systemctl restart --no-block wpa_supplicant || true
/usr/bin/systemctl restart NetworkManager
/usr/bin/sleep 5
/usr/bin/timeout 8s /usr/bin/nmcli -w 5 radio wifi on || true

wifi_iface=""
if [[ -d /sys/class/net/wlp2s0 ]]; then
  wifi_iface=wlp2s0
else
  for wifi_path in /sys/class/net/*; do
    if [[ -d ${wifi_path}/wireless ]]; then
      wifi_iface=${wifi_path##*/}
      break
    fi
  done
fi

if [[ -z ${wifi_iface} ]]; then
  echo "ERROR: No Wi-Fi interface found."
  /usr/bin/lspci -nnk | /usr/bin/grep -A4 -iE 'network|wireless' || true
  /usr/bin/journalctl -k -b --no-pager \
    | /usr/bin/grep -iE 'iwlwifi|firmware' \
    | /usr/bin/tail -n 50 || true
  exit 2
fi

echo "==> Using interface ${wifi_iface}..."
/usr/bin/timeout 8s /usr/bin/nmcli -w 5 device set "${wifi_iface}" managed yes || true
/usr/sbin/ip link set "${wifi_iface}" up || true
/usr/bin/timeout 8s /usr/bin/nmcli -w 5 radio wifi on || true

wifi_state=""
wifi_state_code=0
for ((wifi_wait=0; wifi_wait<10; wifi_wait++)); do
  wifi_state=$(/usr/bin/timeout 5s /usr/bin/nmcli -g GENERAL.STATE device show "${wifi_iface}" 2>/dev/null || true)
  wifi_state_code=${wifi_state%% *}
  if [[ ${wifi_state_code} =~ ^[0-9]+$ ]] && ((wifi_state_code >= 30)); then
    break
  fi
  /usr/bin/sleep 2
done

if ! [[ ${wifi_state_code} =~ ^[0-9]+$ ]] || ((wifi_state_code < 30)); then
  echo "ERROR: ${wifi_iface} is still unavailable."
  /usr/bin/nmcli -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.REASON device show "${wifi_iface}" || true
  /usr/sbin/rfkill list || true
  /usr/bin/journalctl -k -b --no-pager \
    | /usr/bin/grep -iE 'iwlwifi|firmware' \
    | /usr/bin/tail -n 50 || true
  echo "Reboot once, then run this script again."
  exit 3
fi

echo "==> Scanning Wi-Fi networks..."
/usr/bin/timeout 12s /usr/bin/nmcli -w 8 device wifi rescan ifname "${wifi_iface}" || true
/usr/bin/sleep 2
/usr/bin/nmcli device wifi list ifname "${wifi_iface}"

echo
echo "Connect with:"
echo "nmcli device wifi connect \"WIFI_NAME\" password \"PASSWORD\" ifname ${wifi_iface}"
echo "Reboot or log out/in once so GDM can unlock GNOME Keyring automatically."
