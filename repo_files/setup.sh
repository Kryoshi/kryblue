#!/usr/bin/env bash
# Kryblue / Kryzite: repeatable user setup after an Atomic OS installation.
# Usage: ./setup.sh [all|git|docker|starship|gnome|flatpaks|streaming|remove-streaming|status]
# Run as your normal desktop user, not with sudo.
set -Eeuo pipefail

GIT_NAME="${KRY_GIT_NAME:-Kryoshi}"
GIT_EMAIL="${KRY_GIT_EMAIL:-63922550+Kryoshi@users.noreply.github.com}"
FLATPAKS_URL="${KRY_FLATPAKS_URL:-https://raw.githubusercontent.com/Kryoshi/kryzite-os/main/repo_files/flatpaks}"
MANIFEST_TEMP=""
cleanup() { if [[ -n "$MANIFEST_TEMP" ]]; then rm -f "$MANIFEST_TEMP"; fi; }
trap cleanup EXIT

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$1" >&2; return 1; }; }

setup_git() {
  log 'Git identity and GitHub authentication'
  need git
  need gh

  local changed=0 key current i
  local -a keys=(user.name user.email init.defaultBranch pull.rebase)
  local -a values=("$GIT_NAME" "$GIT_EMAIL" main false)

  # Only update settings that differ from Kryblue's desired defaults.
  for i in "${!keys[@]}"; do
    key="${keys[$i]}"
    current="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ "$current" != "${values[$i]}" ]]; then
      git config --global "$key" "${values[$i]}"
      log "Updated Git setting: $key"
      changed=1
    fi
  done

  # Set VS Code only when no global editor preference exists.
  if command -v code >/dev/null 2>&1 &&
     ! git config --global --get core.editor >/dev/null 2>&1; then
    git config --global core.editor 'code --wait'
    log 'Configured VS Code as Git editor'
    changed=1
  fi

  # Keep GitHub CLI's HTTPS protocol setting without rewriting it each run.
  if [[ "$(gh config get git_protocol --host github.com 2>/dev/null || true)" != https ]]; then
    gh config set git_protocol https --host github.com
    changed=1
  fi

  # Only prompt for authentication if the existing session is invalid/missing.
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    if [[ ! -t 0 ]]; then
      warn 'Git identity is configured, but interactive GitHub login is required.'
      warn 'Run: gh auth login --hostname github.com --git-protocol https --web'
      return 1
    fi
    gh auth login --hostname github.com --git-protocol https --web
    changed=1
  fi

  # `gh auth setup-git` is needed only if the gh credential helper is absent.
  if ! git config --global --get-all 'credential.https://github.com.helper' 2>/dev/null |
       grep -Fq 'gh auth git-credential'; then
    gh auth setup-git --hostname github.com
    log 'Configured GitHub CLI as Git credential helper'
    changed=1
  fi

  if (( changed )); then
    log "Git configuration updated for $GIT_NAME <$GIT_EMAIL>"
  else
    log 'Git and GitHub CLI already configured; skipping'
  fi
}

setup_docker() {
  log 'Docker Engine'
  need docker
  local user
  user="$(id -un)"

  if id -nG "$user" | tr ' ' '\n' | grep -Fxq docker &&
     systemctl is-enabled --quiet docker.service; then
    log 'Docker already configured; skipping'
    return 0
  fi

  need sudo
  if ! getent group docker >/dev/null; then
    sudo groupadd docker
  fi
  if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -Fxq docker; then
    sudo usermod -aG docker "$(id -un)"
    warn 'Docker group added. Log out and back in for group membership to take effect.'
  fi
  if ! systemctl is-enabled --quiet docker.service; then
    sudo systemctl enable --now docker.service
  fi
}

setup_starship() {
  log 'Starship prompt'
  need starship
  mkdir -p "$HOME/.config"
  if [[ ! -e "$HOME/.config/starship.toml" ]]; then
    starship preset tokyo-night -o "$HOME/.config/starship.toml"
  else
    log 'Existing starship.toml preserved'
  fi

  touch "$HOME/.bashrc"
  if ! grep -Fq '# >>> Kryblue Starship >>>' "$HOME/.bashrc" && \
     ! grep -Fq 'starship init bash' "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'BASHRC'

# >>> Kryblue Starship >>>
if [[ $- == *i* ]] && command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi
# <<< Kryblue Starship <<<
BASHRC
  fi
}

setup_gnome() {
  log 'Minimise button'
  gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,close'

  gnome-extensions enable shatter-shell@adilhanney.com

  log 'Ptyxis opacity (GNOME only)'
  if ! command -v gsettings >/dev/null 2>&1 || \
     ! gsettings list-schemas | grep -Fxq org.gnome.Ptyxis; then
    log 'Ptyxis settings are not available; skipped'
    return
  fi
  local profile
  profile="$(gsettings get org.gnome.Ptyxis default-profile-uuid | tr -d "'\n")"
  if [[ -z "$profile" ]]; then
    log 'No Ptyxis default profile yet; skipped'
    return
  fi
  gsettings set "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$profile/" opacity 0.9
}

# Replace Fedora-origin Flatpak apps with Flathub equivalents without
# deleting their app data. Never force-remove a remote with installed refs.
migrate_fedora_remote() {
  local scope="$1" app remaining pin
  local -a apps=()

  # Idempotent: nothing to migrate if Fedora's remote is already gone.
  if ! flatpak "--$scope" remotes --columns=name | grep -Fxq fedora; then
    return 0
  fi

  # Snapshot IDs first: Flatpak commands must not consume the loop input.
  mapfile -t apps < <(
    flatpak "--$scope" list --app --columns=application,origin |
      awk -F '\t' '$2 == "fedora" { print $1 }'
  )

  log "Found ${#apps[@]} Fedora Flatpak apps in $scope scope"

  for app in "${apps[@]}"; do
    if ! flatpak "--$scope" remote-info flathub "$app" >/dev/null 2>&1; then
      warn "No matching Flathub application for $scope app $app; keeping Fedora version"
      continue
    fi

    log "Switching $scope app $app to Flathub"

    # Uninstall first to avoid Flatpak's 'Update is older than current version'
    # OSTree timestamp check when changing the remote for the same app ID.
    # No --delete-data: retain ~/.var/app settings and application data.
    if ! flatpak "--$scope" uninstall --app --noninteractive -y "$app" </dev/null; then
      warn "Could not uninstall $scope app $app; keeping Fedora version"
      continue
    fi

    if flatpak "--$scope" install --app --noninteractive -y flathub "$app" </dev/null; then
      log "Migrated $scope app $app to Flathub"
    else
      warn "Flathub installation failed for $scope app $app; restoring Fedora version"
      if ! flatpak "--$scope" install --app --noninteractive -y fedora "$app" </dev/null; then
        warn "RESTORE FAILED: $app is uninstalled; reinstall it manually"
      fi
    fi
  done

  # Don't unpin Fedora runtimes if Fedora-origin apps are still installed.
  remaining="$(flatpak "--$scope" list --app --columns=application,origin |
    awk -F '\t' '$2 == "fedora" { print $1 }')"
  if [[ -z "$remaining" ]]; then
    # Fedora images can pin Platform runtimes, preventing --unused cleanup.
    # Remove only Fedora Platform family pins; leave unrelated pins untouched.
    while IFS= read -r pin; do
      case "$pin" in
        runtime/org.fedoraproject.Platform/*|runtime/org.fedoraproject.Platform.*/*)
          log "Removing obsolete $scope Fedora runtime pin: $pin"
          flatpak "--$scope" pin --remove "$pin" ||
            warn "Could not remove runtime pin: $pin"
          ;;
      esac
    done < <(flatpak "--$scope" pin)
  fi

  # Uninstall only runtimes/extensions no longer needed by installed apps.
  if ! flatpak "--$scope" uninstall --unused --noninteractive -y </dev/null; then
    warn "Could not complete unused-runtime cleanup for $scope scope"
  fi

  # Include all refs: deleting a remote with installed runtimes would
  # strand those references without updates.
  remaining="$(flatpak "--$scope" list --all --columns=application,origin |
    awk -F '\t' '$2 == "fedora" { print $1 }')"
  if [[ -n "$remaining" ]]; then
    warn "Fedora $scope remote still has installed refs and was NOT deleted:"
    printf '%s\n' "$remaining" >&2
    warn 'Review these refs, then rerun: ./setup.sh flatpaks'
    return 0
  fi

  if flatpak "--$scope" remote-delete fedora </dev/null; then
    log "Removed $scope Fedora Flatpak remote"
  else
    warn "Could not remove $scope Fedora remote; no forced deletion attempted"
  fi
}

setup_flatpaks() {
  log 'Flathub applications from shared GitHub manifest'
  need flatpak
  need curl
  flatpak --system remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak --system remote-modify --enable --no-filter --subset= flathub
  if flatpak --user remotes --columns=name | grep -Fxq flathub; then
    flatpak --user remote-modify --enable --no-filter --subset= flathub
  fi
  local manifest app
  manifest="$(mktemp)"
  MANIFEST_TEMP="$manifest"
  curl --fail --silent --show-error --location --retry 3 \
    "$FLATPAKS_URL" --output "$manifest"
  [[ -s "$manifest" ]] || { warn 'Flatpak manifest is empty'; return 1; }
  # Migrate first so manifest installs never hit Fedora-vs-Flathub
  # OSTree timestamp conflicts for already-installed app IDs.
  migrate_fedora_remote system
  migrate_fedora_remote user
  while IFS= read -r app || [[ -n "$app" ]]; do
    app="${app%%#*}"
    app="${app#"${app%%[![:space:]]*}"}"
    app="${app%"${app##*[![:space:]]}"}"
    [[ -z "$app" ]] && continue
    if [[ ! "$app" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]+$ ]]; then
      warn "Invalid Flatpak ID in manifest: $app"
      return 1
    fi
    flatpak --system install --noninteractive -y flathub "$app"
  done < "$manifest"
  log 'Flatpak sync complete; no unrelated apps were removed'
}

streaming_confirm() {
  local answer
  if [[ ! -t 0 ]]; then
    warn 'This action requires an interactive terminal.'
    return 1
  fi
  read -r -p "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

streaming_group_member() {
  id -nG "$(id -un)" | tr ' ' '\n' | grep -Fxq "$1"
}

# Fedora Atomic can expose vendor groups through /usr/lib/group without an
# /etc/group entry. Some usermod/gpasswd operations then fail to persist.
# Create a local entry only when required, retaining the vendor GID.
streaming_ensure_group() {
  local group="$1" user="$2" state_dir="$3" entry

  if ! getent group "$group" >/dev/null; then
    if [[ "$group" == input ]]; then
      warn 'Required system group input was not found'
      return 1
    fi
    sudo groupadd --system "$group"
    touch "$state_dir/group-created.$group"
  fi

  if ! grep -q "^${group}:" /etc/group; then
    entry="$(getent group "$group")" || return 1
    printf '%s\n' "$entry" | sudo tee -a /etc/group >/dev/null
    touch "$state_dir/group-local-entry-created.$group"
  fi

  if ! id -nG "$user" | tr ' ' '\n' | grep -Fxq "$group"; then
    sudo gpasswd -a "$user" "$group"
    if ! id -nG "$user" | tr ' ' '\n' | grep -Fxq "$group"; then
      warn "Membership in $group did not persist"
      return 1
    fi
    touch "$state_dir/member-added.$group"
    return 10  # Inform caller that a new login is needed.
  fi
  return 0
}

setup_streaming() {
  log 'Punktfunk streaming (Kryblue RPM image)'
  local user state_dir group rc changed=0 zone service marker
  local config_dir="$HOME/.config/punktfunk"
  local config_file="$HOME/.config/punktfunk/host.env"
  local desktop_dropin="$HOME/.config/systemd/user/punktfunk-host.service.d/desktop-session.conf"
  local desktop_template=/usr/share/punktfunk/punktfunk-host-desktop-session.conf
  user="$(id -un)"
  state_dir="$HOME/.local/state/kryblue/streaming"

  need sudo
  need rpm
  need systemctl
  need getent

  # Packages are owned by build_files/build.sh, never installed from setup.sh.
  local -a packages=(punktfunk punktfunk-web punktfunk-scripting punktfunk-gamescope)
  for group in "${packages[@]}"; do
    if ! rpm -q "$group" >/dev/null 2>&1; then
      warn "Missing image package: $group"
      warn 'Deploy a Kryblue image containing Punktfunk before running this task.'
      return 1
    fi
  done
  need punktfunk-host
  need punktfunk-gamescope

  if [[ -f /var/lib/extensions/punktfunk.raw ]]; then
    warn 'An old Punktfunk sysext image is still present; remove it before enabling RPM services.'
    return 1
  fi

  mkdir -p "$state_dir" "$config_dir"

  # Controller access: do not join the self-update or loginless groups.
  for group in input punktfunk; do
    if streaming_ensure_group "$group" "$user" "$state_dir"; then
      :
    else
      rc=$?
      if (( rc == 10 )); then
        changed=1
      else
        return "$rc"
      fi
    fi
  done

  # Punktfunk can report updates, but Kryblue applies them through OCI builds.
  if grep -q '^PUNKTFUNK_UPDATE_APPLY=' "$config_file" 2>/dev/null; then
    if ! grep -q '^PUNKTFUNK_UPDATE_APPLY=0$' "$config_file"; then
      sed -i 's/^PUNKTFUNK_UPDATE_APPLY=.*/PUNKTFUNK_UPDATE_APPLY=0/' "$config_file"
      log 'Disabled console-managed Punktfunk updates'
    fi
  else
    printf '%s\n' 'PUNKTFUNK_UPDATE_APPLY=0' >> "$config_file"
    log 'Disabled console-managed Punktfunk updates'
  fi

  # Tie the host to the GNOME graphical session so desktop restarts are safe.
  if [[ -f "$desktop_template" ]]; then
    mkdir -p "$(dirname "$desktop_dropin")"
    if ! cmp -s "$desktop_template" "$desktop_dropin"; then
      install -m 0644 "$desktop_template" "$desktop_dropin"
      log 'Installed Punktfunk GNOME session drop-in'
    fi
  else
    warn 'Punktfunk GNOME desktop-session drop-in not found; leaving the packaged unit unchanged'
  fi

  systemctl --user daemon-reload
  if [[ -f "$desktop_dropin" ]]; then
    systemctl --user reenable punktfunk-host.service
  else
    systemctl --user enable punktfunk-host.service
  fi
  systemctl --user enable punktfunk-web.service

  # RPMs already contain the udev rules; do not copy them to /etc or trigger
  # devices to compensate for the old sysext activation race.
  if [[ ! -f /usr/lib/udev/rules.d/60-punktfunk.rules ]]; then
    warn 'Punktfunk USB/IP udev rule is missing from the deployed image'
  fi
  if [[ ! -e /dev/uinput ]]; then
    warn '/dev/uinput is missing; virtual controllers may not work'
  elif [[ "$(stat -c '%G' /dev/uinput)" != input ]]; then
    warn '/dev/uinput is not owned by input; check udev permissions'
  fi

  # The deployed image provides the firewalld service definitions. Record only
  # additions made by this script so removal leaves existing rules untouched.
  if command -v firewall-cmd >/dev/null 2>&1 &&
     sudo firewall-cmd --state >/dev/null 2>&1; then
    zone="$(sudo firewall-cmd --get-default-zone)"
    local fw_changed=0
    for service in punktfunk-native punktfunk-web; do
      marker="$state_dir/fw-service.$zone.$service"
      if ! sudo firewall-cmd --permanent --zone="$zone" \
           --query-service="$service" >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone="$zone" --add-service="$service"
        touch "$marker"
        fw_changed=1
      fi
    done
    if (( fw_changed )); then
      sudo firewall-cmd --reload
    fi
  else
    warn 'Firewalld is not running; configure network access manually if required'
  fi

  if (( changed )); then
    warn 'Log out and back in (or reboot) before Punktfunk starts with the new controller groups.'
    log 'Punktfunk user services enabled; they will start at the next login.'
  else
    systemctl --user start punktfunk-host.service punktfunk-web.service
    log 'Punktfunk user services started'
  fi
  log 'Configure the host and Gamescope Spawn in the Punktfunk WebUI.'
  log 'Punktfunk package updates will arrive only through Kryblue image deployments.'
}

remove_streaming() {
  log 'Remove Punktfunk user setup (RPM packages remain in Kryblue)'
  local user state_dir zone service marker
  user="$(id -un)"
  state_dir="$HOME/.local/state/kryblue/streaming"
  need sudo
  need systemctl

  if sudo systemctl is-active --quiet punktfunk-door.service 2>/dev/null ||
     sudo test -s /var/lib/punktfunk-seats/owner; then
    warn 'Disable Profiles -> Reachable without logging in and remove extra seats first.'
    return 1
  fi

  if ! streaming_confirm 'Stop Punktfunk and delete your host config, pairings, and Kryblue-managed integration?'; then
    log 'Removal cancelled'
    return 0
  fi

  # The image still owns the RPMs, system groups and vendor udev rules.
  # Only disable user services; never run dnf, rpm-ostree or the sysext installer.
  local unit
  for unit in punktfunk-host punktfunk-web punktfunk-scripting; do
    if ! systemctl --user disable --now "$unit.service" 2>/dev/null; then
      warn "Could not disable $unit.service (it may already be absent)"
    fi
  done

  if command -v firewall-cmd >/dev/null 2>&1 &&
     sudo firewall-cmd --state >/dev/null 2>&1; then
    local fw_changed=0
    for marker in "$state_dir"/fw-service.*; do
      [[ -f "$marker" ]] || continue
      zone="${marker##*/fw-service.}"
      service="${zone#*.}"
      zone="${zone%.*}"
      if sudo firewall-cmd --permanent --zone="$zone" \
           --query-service="$service" >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone="$zone" --remove-service="$service"
        fw_changed=1
      fi
      rm -f -- "$marker"
    done
    if (( fw_changed )); then
      sudo firewall-cmd --reload
    fi
  else
    warn 'Firewalld is not running; Kryblue-managed firewall rules may remain'
  fi

  # The dedicated group grants USB/IP access. Retain the shared input group.
  if [[ -f "$state_dir/member-added.punktfunk" ]] &&
     streaming_group_member punktfunk; then
    if ! sudo gpasswd -d "$user" punktfunk; then
      warn 'Could not remove Punktfunk group membership'
    fi
  fi

  rm -rf -- "$HOME/.config/punktfunk"
  rm -f -- "$HOME/.config/autostart/io.unom.punktfunk.tray.desktop"
  local dropin
  for dropin in "$HOME"/.config/systemd/user/punktfunk-*.service.d; do
    [[ -d "$dropin" ]] && rm -rf -- "$dropin"
  done
  systemctl --user daemon-reload

  # Retain firewall tracking markers if firewalld was unavailable; the user
  # can rerun removal later to clean those rules.
  local pending_firewall=0
  for marker in "$state_dir"/fw-service.*; do
    [[ -f "$marker" ]] && pending_firewall=1
  done
  if (( pending_firewall )); then
    warn 'Retaining Kryblue state for firewall rules that could not be removed'
  else
    rm -rf -- "$state_dir"
  fi

  log 'Punktfunk user configuration removed; the image-managed RPMs remain installed.'
  warn 'Log out and back in if Punktfunk group membership was changed.'
}

show_streaming_status() {
  log 'Punktfunk image packages'
  local package unit group
  for package in punktfunk punktfunk-web punktfunk-scripting punktfunk-gamescope; do
    rpm -q "$package" 2>/dev/null || printf '%s: not installed\n' "$package"
  done

  log 'Punktfunk user services'
  for unit in punktfunk-host punktfunk-web punktfunk-scripting; do
    printf '%s: enabled=' "$unit"
    systemctl --user is-enabled "$unit.service" 2>/dev/null || true
    printf '   active='
    systemctl --user is-active "$unit.service" 2>/dev/null || true
  done

  log 'Punktfunk controller and session access'
  for group in input punktfunk; do
    printf 'Group %-16s: ' "$group"
    if streaming_group_member "$group"; then
      printf 'member\n'
    else
      printf 'not a member\n'
    fi
  done
  printf 'Lingering: '
  loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true
  if [[ -e /dev/uinput ]]; then
    stat -c '/dev/uinput: %U:%G %a' /dev/uinput
  fi
  local node
  for node in /sys/devices/platform/vhci_hcd.*/{attach,detach}; do
    [[ -e "$node" ]] && stat -c '%n: %U:%G %a' "$node"
  done
}

show_status() {
  log 'Git author'
  git config --global --get user.name || true
  git config --global --get user.email || true

  log 'GitHub authentication'
  gh auth status --hostname github.com || true

  log 'Flatpak remotes'
  flatpak remotes || true

  log 'Docker group (may require re-login)'
  id -nG || true

  show_streaming_status
}

if [[ "${1:-}" != "-h" && "${1:-}" != "--help" && "${1:-}" != "help" && "$(id -u)" -eq 0 ]]; then
  printf 'Run as your normal desktop user, not with sudo.\n' >&2
  exit 1
fi

case "${1:-all}" in
  all)
    setup_git
    setup_docker
    setup_starship
    setup_gnome
    setup_flatpaks
    setup_streaming
    log 'Finished. Reboot if streaming or Docker group memberships changed.'
    ;;
  git) setup_git ;;
  docker) setup_docker ;;
  starship) setup_starship ;;
  gnome) setup_gnome ;;
  flatpaks) setup_flatpaks ;;
  streaming) setup_streaming ;;
  remove-streaming) remove_streaming ;;
  status) show_status ;;
  -h|--help|help)
    printf 'Usage: %s [all|git|docker|starship|gnome|flatpaks|streaming|remove-streaming|status]\n' "$0"
    ;;
  *)
    printf 'Unknown task: %s\n' "$1" >&2
    exit 2
    ;;
esac
