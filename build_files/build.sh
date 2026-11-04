
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
  gnome-shell-extension-pop-shell
  gnome-shell-extension-vertical-workspaces
)

dnf5 install -y "${packages[@]}"

# ============================================================
# Starship
# ============================================================

# Install from the Fedora COPR, then disable the repository.
dnf5 -y copr enable atim/starship
dnf5 install -y starship
dnf5 -y copr disable atim/starship

# ============================================================
# Services
# ============================================================

systemctl enable docker.service
