#!/bin/bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Can quyen root. Hay chay bang: su -c 'bash $0'"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Khong tim thay /etc/os-release. Script nay chi danh cho Debian 13."
  exit 1
fi

. /etc/os-release
if [[ ${ID:-} != "debian" ]]; then
  echo "He dieu hanh hien tai khong phai Debian. Dung lai de tranh sua nham."
  exit 1
fi

echo "==> Cap nhat va cai GNOME Wayland toi gian + goi tiet kiem pin..."
export DEBIAN_FRONTEND=noninteractive
/usr/bin/apt-get update

if ! /usr/bin/apt-cache show firmware-iwlwifi >/dev/null 2>&1; then
  echo "==> Bat kho non-free-firmware cua Debian..."
  debian_suite=${VERSION_CODENAME:-trixie}
  /usr/bin/cat > /etc/apt/sources.list.d/debian-non-free-firmware.sources <<EOF
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

echo "==> Them kho Google Chrome chinh thuc..."
/usr/bin/install -d -m 0755 /etc/apt/keyrings
/usr/bin/curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | /usr/bin/gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
/usr/bin/chmod 0644 /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  > /etc/apt/sources.list.d/google-chrome.list
/usr/bin/apt-get update

/usr/bin/apt-get install -y --no-install-recommends \
  sudo \
  gdm3 gnome-shell gnome-session gnome-control-center \
  nautilus gnome-console network-manager network-manager-gnome \
  gnome-keyring libpam-gnome-keyring pipewire-audio \
  xdg-desktop-portal-gnome iio-sensor-proxy thermald \
  intel-microcode firmware-intel-graphics intel-media-va-driver \
  firmware-iwlwifi wireless-regdb wpasupplicant iw rfkill kmod \
  iproute2 pciutils \
  ibus ibus-unikey im-config \
  google-chrome-stable \
  tlp acpi

echo "==> Sua cam bien xoay nguoc 180 do tren OneMix 3..."
/usr/bin/install -d -m 0755 /etc/udev/hwdb.d
/usr/bin/cat > /etc/udev/hwdb.d/61-onemix3-sensor.hwdb <<'EOF'
# OneMix 3/3s/3 Pro Bosch accelerometer orientation.
# Rule local nay bo sung cho cac may co DMI khong khop rule systemd mac dinh.
sensor:modalias:acpi:BOSC0200:*:dmi:*
 ACCEL_MOUNT_MATRIX=-1, 0, 0; 0, 1, 0; 0, 0, 1
EOF
/usr/bin/systemd-hwdb update
/usr/bin/udevadm trigger --subsystem-match=iio --action=change || true

# Uu tien nguoi goi sudo, sau do nguoi dang nhap tren TTY, cuoi cung la
# tai khoan thuong dau tien (UID >= 1000). Khong bao gio them root.
target_user=${SUDO_USER:-}
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(/usr/bin/logname 2>/dev/null || true)
fi
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(/usr/bin/getent passwd | /usr/bin/awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }')
fi

if [[ -n ${target_user} && ${target_user} != root ]] && /usr/bin/id "${target_user}" >/dev/null 2>&1; then
  echo "==> Them ${target_user} vao nhom sudo..."
  /usr/sbin/usermod -aG sudo "${target_user}"
  echo "==> Chon IBus lam bo go cho ${target_user}..."
  /usr/sbin/runuser -u "${target_user}" -- /usr/bin/im-config -n ibus
else
  echo "CANH BAO: Khong tim thay tai khoan nguoi dung thuong de them vao nhom sudo."
fi

# TLP va power-profiles-daemon dieu khien cung cac tham so kernel.
# Khong cho ca hai chay dong thoi.
if /usr/bin/systemctl list-unit-files power-profiles-daemon.service >/dev/null 2>&1; then
  /usr/bin/systemctl disable --now power-profiles-daemon.service 2>/dev/null || true
  /usr/bin/systemctl mask power-profiles-daemon.service
fi

echo "==> Ghi cau hinh pin manh cho Intel Core m3..."
/usr/bin/install -d -m 0755 /etc/tlp.d
/usr/bin/install -m 0644 /dev/null /etc/tlp.d/01-onemix3-battery.conf
/usr/bin/cat > /etc/tlp.d/01-onemix3-battery.conf <<'EOF'
# OneMix 3: uu tien thoi luong pin. AC van giu hieu nang binh thuong.
TLP_ENABLE=1

CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0
CPU_MAX_PERF_ON_AC=100
CPU_MAX_PERF_ON_BAT=60

PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y

RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
PCIE_ASPM_ON_AC=default
# Giu ASPM mac dinh de tranh lam Intel AC-3165 chap chon khi dung pin.
PCIE_ASPM_ON_BAT=default
AHCI_RUNTIME_PM_ON_AC=on
AHCI_RUNTIME_PM_ON_BAT=auto

USB_AUTOSUSPEND=1
USB_EXCLUDE_AUDIO=1
USB_EXCLUDE_BTUSB=0
USB_EXCLUDE_PHONE=0
USB_EXCLUDE_PRINTER=0
USB_EXCLUDE_WWAN=0

DEVICES_TO_DISABLE_ON_BAT="bluetooth wwan"
DEVICES_TO_ENABLE_ON_AC="bluetooth"
RESTORE_DEVICE_STATE_ON_STARTUP=1
EOF

echo "==> Bat dich vu..."
/usr/bin/systemctl enable NetworkManager gdm3 thermald tlp
/usr/bin/systemctl set-default graphical.target
/usr/bin/systemctl restart tlp || /usr/sbin/tlp start

echo "==> Cau hinh va quet Wi-Fi Intel AC-3165..."
/usr/bin/install -d -m 0755 /etc/NetworkManager/conf.d
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

# Intel AC-3165 tren OneMix 3 co the mat ket noi khi power-save qua manh.
/usr/bin/cat > /etc/modprobe.d/iwlwifi-onemix3.conf <<'EOF'
options iwlwifi power_save=0
EOF

# Tu phuc hoi va quet Wi-Fi sau moi lan boot, khi firmware da duoc nap day du.
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

  # Lan dau chua san sang: phuc hoi NetworkManager giong wifi-fix.sh.
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
  echo "OneMix 3 Wi-Fi detected but unavailable"
else
  echo "OneMix 3 Wi-Fi interface not found"
fi
exit 0
EOF

/usr/bin/cat > /etc/systemd/system/onemix3-wifi-init.service <<'EOF'
[Unit]
Description=Initialize and scan OneMix 3 Intel Wi-Fi
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/onemix3-wifi-init
TimeoutStartSec=50
EOF

/usr/bin/cat > /etc/systemd/system/onemix3-wifi-init.timer <<'EOF'
[Unit]
Description=Run OneMix 3 Wi-Fi initialization shortly after boot

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
wifi_found=0
wifi_ready=0
wifi_pci_address=""
for wifi_path in /sys/class/net/*; do
  if [[ -d ${wifi_path}/wireless ]]; then
    wifi_iface=${wifi_path##*/}
    wifi_found=1
    /usr/bin/timeout 8s /usr/bin/nmcli -w 5 device set "${wifi_iface}" managed yes || true
    /usr/sbin/ip link set "${wifi_iface}" up || true

    if [[ -w ${wifi_path}/device/power/control ]]; then
      echo on > "${wifi_path}/device/power/control"
    fi
    wifi_device_path=$(/usr/bin/readlink -f "${wifi_path}/device" 2>/dev/null || true)
    wifi_pci_candidate=${wifi_device_path##*/}
    wifi_pci_candidate=${wifi_pci_candidate#0000:}
    if [[ ${wifi_pci_candidate} =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
      wifi_pci_address=${wifi_pci_candidate}
    fi

    wifi_state=""
    wifi_state_code=0
    for ((wifi_wait=0; wifi_wait<8; wifi_wait++)); do
      wifi_state=$(/usr/bin/timeout 5s /usr/bin/nmcli -g GENERAL.STATE device show "${wifi_iface}" 2>/dev/null || true)
      wifi_state_code=${wifi_state%% *}
      if [[ ${wifi_state_code} =~ ^[0-9]+$ ]] && ((wifi_state_code >= 30)); then
        break
      fi
      /usr/bin/sleep 2
    done

    if [[ ${wifi_state_code} =~ ^[0-9]+$ ]] && ((wifi_state_code >= 30)); then
      wifi_ready=1
      /usr/bin/timeout 12s /usr/bin/nmcli -w 8 device wifi rescan ifname "${wifi_iface}" || true
    else
      echo "Wi-Fi ${wifi_iface} dang unavailable; bo qua rescan. Firmware moi co the can reboot."
    fi
  fi
done

# Khong cho TLP autosuspend rieng card Wi-Fi, ke ca khi may dang dung pin.
if [[ -n ${wifi_pci_address} ]]; then
  /usr/bin/printf '%s\n' \
    '# Keep Intel Wi-Fi fully awake for connection stability.' \
    "RUNTIME_PM_DISABLE=\"${wifi_pci_address}\"" \
    > /etc/tlp.d/02-onemix3-wifi.conf
  /usr/bin/systemctl restart tlp || /usr/sbin/tlp start
fi

if [[ ${wifi_ready} -eq 1 ]]; then
  echo "Wi-Fi da san sang. Danh sach mang se hien trong GNOME Quick Settings."
  /usr/bin/nmcli device wifi list
elif [[ ${wifi_found} -eq 1 ]]; then
  echo "Wi-Fi da duoc nhan dien nhung chua san sang. Hay reboot de nap firmware/driver moi."
  /usr/bin/nmcli -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.REASON device show || true
  /usr/sbin/rfkill list || true
  /usr/bin/journalctl -k -b --no-pager \
    | /usr/bin/grep -iE 'iwlwifi|firmware' \
    | /usr/bin/tail -n 50 || true
else
  echo "CANH BAO: Chua thay interface Wi-Fi; xem loi bang: journalctl -k -b | grep -iE 'iwlwifi|firmware'"
  /usr/bin/lspci -nnk | /usr/bin/grep -A4 -iE 'network|wireless' || true
  /usr/bin/journalctl -k -b --no-pager \
    | /usr/bin/grep -iE 'iwlwifi|firmware' \
    | /usr/bin/tail -n 50 || true
fi

# Cau hinh GNOME cho tai khoan nguoi dung da xac dinh o tren.
if [[ -n ${target_user} && ${target_user} != root ]] && /usr/bin/id "${target_user}" >/dev/null 2>&1; then
  echo "==> Giam hieu ung va dat tu suspend sau 15 phut cho ${target_user}..."
  /usr/sbin/runuser -u "${target_user}" -- /usr/bin/dbus-run-session -- /bin/bash -c '
    /usr/bin/gsettings set org.gnome.desktop.interface enable-animations false
    /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power idle-dim true
    /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "suspend"
    /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 900
    /usr/bin/gsettings set org.gnome.desktop.input-sources sources "[(\"xkb\", \"us\"), (\"ibus\", \"Unikey\")]"
    /usr/bin/gsettings set org.gnome.desktop.input-sources mru-sources "[(\"xkb\", \"us\"), (\"ibus\", \"Unikey\")]"
  '
fi

echo
echo "HOAN TAT. Khoi dong lai bang: sudo reboot"
echo "Kiem tra sau reboot: sudo tlp-stat -s"
echo "Kiem tra Wayland: echo \$XDG_SESSION_TYPE"
echo "Kiem tra IBus: gsettings get org.gnome.desktop.input-sources sources"
echo "Chuyen Anh/Viet bang Super + Space"
echo "Cam bien OneMix 3 se co huong dung tu man hinh dang nhap GDM."
echo "Xem danh sach Wi-Fi: nmcli device wifi list"
echo "GNOME Keyring se luu mat khau Wi-Fi sau khi dang nhap lai."
