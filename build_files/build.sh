
#!/usr/bin/env bash
set -euo pipefail

# Copy files included by the current Universal Blue template
cp -a /ctx/system_files/. /

# ============================================================
# Repositories
# ============================================================

# RPM Fusion is already available in Universal Blue main images.

# Docker CE
curl -fsSL --retry 3 \
  https://download.docker.com/linux/fedora/docker-ce.repo \
  -o /etc/yum.repos.d/docker-ce.repo

rpm --import https://download.docker.com/linux/fedora/gpg

# Visual Studio Code
rpm --import https://packages.microsoft.com/keys/microsoft.asc

cat > /etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO

# ============================================================
# Packages
# ============================================================

packages=(
  # Development
  git
  gh
  just
  code

  # Docker Engine + Dev Containers
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin

  # Gaming
  steam
  steam-devices
  gamescope
  gamemode
  mangohud
  protontricks

  # GNOME Extensions
  gnome-shell-extension-appindicator
  gnome-shell-extension-blur-my-shell
  gnome-shell-extension-caffeine
  gnome-shell-extension-frippery-move-clock
  gnome-shell-extension-vertical-workspaces
  
  # Hardware monitoring and system info
  vulkan-tools
  glx-utils
  lm_sensors
  fastfetch
)

dnf5 install -y "${packages[@]}"

# ============================================================
# Shatter Shell (Pop Shell replacement)
# ============================================================

# Bootstrap the Terra repository and signing keys
dnf5 install -y --nogpgcheck \
  --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
  terra-release terra-gpg-keys

# Install Shatter Shell
dnf5 install -y --enablerepo=terra \
  gnome-shell-extension-shatter-shell

# Remove Terra repository from the final image
dnf5 remove -y terra-release

# ============================================================
# Nerd Font — JetBrains Mono
# ============================================================

NERD_FONT_VERSION="v3.5.1"
NERD_FONT_DIR="/usr/share/fonts/JetBrainsMonoNerdFont"

mkdir -p "$NERD_FONT_DIR"

curl -fsSL --retry 3 \
  "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONT_VERSION}/JetBrainsMono.tar.xz" \
  -o /tmp/JetBrainsMono.tar.xz

tar -xJf /tmp/JetBrainsMono.tar.xz \
  -C "$NERD_FONT_DIR"

rm -f /tmp/JetBrainsMono.tar.xz

fc-cache -f "$NERD_FONT_DIR"

# ============================================================
# Starship
# ============================================================

# Install from the Fedora COPR, then remove
dnf5 -y copr enable atim/starship
dnf5 install -y starship
dnf5 -y copr remove atim/starship

# ============================================================
# CoolerControl
# ============================================================

# Install from the official CoolerControl COPR, then remove
dnf5 -y copr enable codifryed/CoolerControl
dnf5 install -y coolercontrold coolercontrol
dnf5 -y copr remove codifryed/CoolerControl

# ============================================================
# Sunshine - Moonlight game streaming host
# ============================================================

# Install from official LizardByte stable COPR, then remove
dnf5 -y copr enable lizardbyte/stable
dnf5 install -y Sunshine
dnf5 -y copr remove lizardbyte/stable

# ============================================================
# Remove unwanted base applications
# ============================================================

unwanted_packages=(
  firefox
  firefox-langpacks
  gnome-tour
  gnome-contacts
  malcontent-control
  yelp
  gnome-characters
)

# Only remove packages that are actually installed
installed_packages=()

for package in "${unwanted_packages[@]}"; do
  if rpm -q "$package" &>/dev/null; then
    installed_packages+=("$package")
  fi
done

if ((${#installed_packages[@]})); then
  dnf5 remove -y "${installed_packages[@]}"
fi

# ============================================================
# Services
# ============================================================

systemctl enable docker.service
systemctl enable coolercontrold.service
