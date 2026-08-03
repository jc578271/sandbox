#!/usr/bin/env bash
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
apt-get update
apt-get install -y --no-install-recommends \
  sudo \
  gdm3 gnome-shell gnome-session gnome-control-center \
  nautilus gnome-console network-manager pipewire-audio \
  xdg-desktop-portal-gnome iio-sensor-proxy thermald \
  intel-microcode firmware-intel-graphics intel-media-va-driver \
  tlp acpi

# Uu tien nguoi goi sudo, sau do nguoi dang nhap tren TTY, cuoi cung la
# tai khoan thuong dau tien (UID >= 1000). Khong bao gio them root.
target_user=${SUDO_USER:-}
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(logname 2>/dev/null || true)
fi
if [[ -z ${target_user} || ${target_user} == root ]]; then
  target_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }')
fi

if [[ -n ${target_user} && ${target_user} != root ]] && id "${target_user}" >/dev/null 2>&1; then
  echo "==> Them ${target_user} vao nhom sudo..."
  usermod -aG sudo "${target_user}"
else
  echo "CANH BAO: Khong tim thay tai khoan nguoi dung thuong de them vao nhom sudo."
fi

# TLP va power-profiles-daemon dieu khien cung cac tham so kernel.
# Khong cho ca hai chay dong thoi.
if systemctl list-unit-files power-profiles-daemon.service >/dev/null 2>&1; then
  systemctl disable --now power-profiles-daemon.service 2>/dev/null || true
  systemctl mask power-profiles-daemon.service
fi

echo "==> Ghi cau hinh pin manh cho Intel Core m3..."
install -d -m 0755 /etc/tlp.d
install -m 0644 /dev/null /etc/tlp.d/01-onemix3-battery.conf
cat > /etc/tlp.d/01-onemix3-battery.conf <<'EOF'
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
WIFI_PWR_ON_BAT=on
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y

RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
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
systemctl enable NetworkManager gdm3 thermald tlp
systemctl set-default graphical.target
systemctl restart tlp || tlp start

# Cau hinh GNOME cho tai khoan nguoi dung da xac dinh o tren.
if [[ -n ${target_user} && ${target_user} != root ]] && id "${target_user}" >/dev/null 2>&1; then
  echo "==> Giam hieu ung va dat tu suspend sau 15 phut cho ${target_user}..."
  runuser -u "${target_user}" -- dbus-run-session -- bash -c '
    gsettings set org.gnome.desktop.interface enable-animations false
    gsettings set org.gnome.settings-daemon.plugins.power idle-dim true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "suspend"
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 900
  '
fi

echo
echo "HOAN TAT. Khoi dong lai bang: sudo reboot"
echo "Kiem tra sau reboot: sudo tlp-stat -s"
echo "Kiem tra Wayland: echo \$XDG_SESSION_TYPE"
