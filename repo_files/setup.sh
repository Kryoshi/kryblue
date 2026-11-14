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

  # Git commit author != GitHub authentication. Both are configured here.
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main
  git config --global pull.rebase false
  if command -v code >/dev/null 2>&1; then
    git config --global core.editor 'code --wait'
  fi

  # GitHub CLI supplies HTTPS credentials; no SSH key or saved PAT required.
  gh config set git_protocol https --host github.com
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    if [[ ! -t 0 ]]; then
      warn 'Git identity is set, but interactive GitHub login is required.'
      warn 'Run: gh auth login --hostname github.com --git-protocol https --web'
      return 1
    fi
    gh auth login --hostname github.com --git-protocol https --web
  fi
  gh auth setup-git --hostname github.com
  log "Git configured for $GIT_NAME <$GIT_EMAIL>"
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

  log 'Minimise button'
  gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,close'

  gnome-extensions enable shatter-shell@adilhanney.com
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

# Offer to replace the initial plaintext password. Punktfunk swaps plaintext
# for a salted hash on the first successful Web Console sign-in. No marker needed.
setup_streaming_password() {
  local config_dir="$HOME/.config/punktfunk"
  local pwfile="$config_dir/web-password"
  local password confirm escaped tmp

  if [[ ! -s "$pwfile" ]]; then
    warn 'Punktfunk password file not initialized yet; skipping password prompt.'
    return 0
  fi

  # Do not overwrite an already initialized (hashed) password.
  # Current Punktfunk uses PUNKTFUNK_UI_PASSWORD_HASH for the stored hash.
  if grep -q '^PUNKTFUNK_UI_PASSWORD_HASH=' "$pwfile"; then
    return 0
  fi

  # Password has to still be in the initial plaintext form.
  if ! grep -q '^PUNKTFUNK_UI_PASSWORD=' "$pwfile"; then
    warn 'Unknown Punktfunk password-file format; leaving it unchanged.'
    return 0
  fi

  # In loginless (door) mode credentials may have moved to the system seat.
  # Set the password before activating this mode in the Web Console.
  if sudo test -s /var/lib/punktfunk-seats/owner; then
    warn 'Loginless mode already active; manage the console password through Punktfunk.'
    return 0
  fi

  if ! streaming_confirm 'Set a memorable Punktfunk Web Console password now?'; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn 'Password setup requires an interactive terminal.'
    return 1
  fi

  read -r -s -p 'New password (12+ characters): ' password || return 1
  printf '\n'
  read -r -s -p 'Confirm password: ' confirm || return 1
  printf '\n'

  if [[ "$password" != "$confirm" ]]; then
    warn 'Passwords do not match; existing password unchanged.'
    return 1
  fi
  if (( ${#password} < 12 )); then
    warn 'Use at least 12 characters; existing password unchanged.'
    return 1
  fi

  # systemd EnvironmentFile syntax: quote and escape \ and ".
  escaped=${password//\\/\\\\}
  escaped=${escaped//\"/\\\"}

  # Write mode-600 credentials via an atomic replacement in the same dir.
  (umask 077; mkdir -p "$config_dir") || return 1
  tmp="$(umask 077; mktemp "$config_dir/.web-password.XXXXXX")" || return 1
  if ! printf 'PUNKTFUNK_UI_PASSWORD="%s"\n' "$escaped" > "$tmp" ||
     ! mv -f -- "$tmp" "$config_dir/web-password"; then
    rm -f -- "$tmp"
    warn 'Could not save Web Console password.'
    return 1
  fi
  chmod 600 "$config_dir/web-password"
  unset password confirm escaped

  if systemctl --user is-active --quiet punktfunk-web.service; then
    systemctl --user restart punktfunk-web.service || return 1
  else
    log 'Web Console not running; password will apply on its next start.'
  fi

  log 'Punktfunk Web Console password configured. Sign in once to let Punktfunk hash it.'
}

setup_streaming() {
  log 'Punktfunk streaming (Fedora Atomic sysext)'
  need curl
  need sudo
  need systemctl
  need loginctl
  need getent

  if ! command -v punktfunk-sysext >/dev/null 2>&1 ||
     ! command -v punktfunk-host >/dev/null 2>&1; then
    if ! streaming_confirm 'Install Punktfunk stable via its official guided installer?'; then
      log 'Punktfunk installation skipped'
      return 0
    fi

    local installer
    installer="$(mktemp)"
    if ! curl -fsSL --retry 3 https://punktfunk.unom.io/install.sh -o "$installer"; then
      rm -f "$installer"
      warn 'Could not download the Punktfunk installer'
      return 1
    fi

    log "Downloaded upstream installer to $installer"
    if streaming_confirm 'Review the downloaded installer first?'; then
      if command -v less >/dev/null 2>&1; then
        less "$installer"
      else
        cat "$installer"
      fi
    fi
    if ! sh "$installer" --host --channel stable --linger --no-gamestream --no-console-cert; then
      rm -f "$installer"
      warn 'Punktfunk installation failed'
      return 1
    fi
    rm -f "$installer"
  else
    log 'Punktfunk sysext already installed; not reinstalling or updating'
  fi

  command -v punktfunk-host >/dev/null 2>&1 || {
    warn 'Punktfunk host is not available after installation'
    return 1
  }

  local group changed=0
  for group in input punktfunk punktfunk-update; do
    if ! getent group "$group" >/dev/null; then
      warn "Expected group missing: $group; check sysext install and group setup"
      return 1
    fi
    if ! streaming_group_member "$group"; then
      sudo usermod -aG "$group" "$(id -un)"
      log "Added $(id -un) to $group"
      changed=1
    fi
  done

  if [[ "$(loginctl show-user "$(id -un)" -p Linger --value)" != yes ]]; then
    sudo loginctl enable-linger "$(id -un)"
    log 'Systemd lingering enabled'
  else
    log 'Lingering already enabled'
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    local zone service
    zone="$(sudo firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1; exit}')"
    zone="${zone:-$(sudo firewall-cmd --get-default-zone)}"
    log "Configuring Punktfunk ports in firewalld zone: $zone"
    sudo firewall-cmd --reload
    for service in punktfunk-native punktfunk-web; do
      if ! sudo firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone="$zone" --add-service="$service"
      fi
    done
    if [[ -f "$HOME/.config/punktfunk/host.env" ]] &&
       grep -Eq '^PUNKTFUNK_MGMT_BIND=[^#[:space:]]+:47991[[:space:]]*$' "$HOME/.config/punktfunk/host.env"; then
      if ! sudo firewall-cmd --permanent --zone="$zone" --query-port=47991/tcp >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone="$zone" --add-port=47991/tcp
      fi
    fi
    sudo firewall-cmd --reload
  else
    warn 'Firewalld is not running; firewall setup skipped'
  fi

  if sudo test -s /var/lib/punktfunk-seats/owner; then
    log 'Loginless door mode already configured; leaving its service layout intact'
  else
    systemctl --user enable --now punktfunk-host.service punktfunk-web.service
    log 'Punktfunk user services are enabled'
  fi

  setup_streaming_password

  if (( changed )); then
    warn 'Reboot required for new group memberships and loginless streaming permissions.'
  fi
  log 'For loginless sessions: after reboot, open Punktfunk Web Console -> Profiles -> Reachable without logging in, and enable it.'
}

remove_streaming() {
  log 'Remove Punktfunk sysext and system integration (keep user settings)'
  need sudo
  need systemctl

  # The loginless door must be switched off in the Web Console so that
  # identity, keys and pairing data move back to ~/.config/punktfunk.
  if sudo systemctl is-active --quiet punktfunk-door.service 2>/dev/null ||
     sudo test -s /var/lib/punktfunk-seats/owner; then
    warn 'Reachable without logging in is still active.'
    warn 'In the Punktfunk Web Console, open Profiles, turn it off,'
    warn 'remove any extra seat profiles, and then retry uninstall.'
    return 1
  fi

  if ! streaming_confirm 'Remove Punktfunk, its services, groups, firewall access and lingering?'; then
    log 'Removal cancelled'
    return 0
  fi

  local unit
  for unit in punktfunk-host punktfunk-web punktfunk-scripting punktfunk-kde-session; do
    systemctl --user disable --now "$unit.service" 2>/dev/null || true
  done

  # Firewall service definitions can disappear with the sysext, so clean first.
  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    local zone service
    for zone in $(sudo firewall-cmd --get-zones); do
      for service in punktfunk-native punktfunk-web punktfunk-gamestream; do
        if sudo firewall-cmd --permanent --zone="$zone" --query-service="$service" >/dev/null 2>&1; then
          sudo firewall-cmd --permanent --zone="$zone" --remove-service="$service"
        fi
      done
      if sudo firewall-cmd --permanent --zone="$zone" --query-port=47991/tcp >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --zone="$zone" --remove-port=47991/tcp
      fi
    done
    sudo firewall-cmd --reload
  fi

  # Stop system-level loginless/seat services before removing sysext units.
  for unit in punktfunk-door punktfunk-web-door punktfunk-seats; do
    sudo systemctl disable --now "$unit.service" 2>/dev/null || true
  done

  if command -v punktfunk-sysext >/dev/null 2>&1; then
    sudo punktfunk-sysext remove
  fi

  sudo rm -f /etc/modules-load.d/punktfunk.conf /etc/udev/rules.d/60-punktfunk.rules
  rm -f "$HOME/.config/autostart/io.unom.punktfunk.tray.desktop"
  local dropin group
  for dropin in "$HOME"/.config/systemd/user/punktfunk-*.service.d; do
    [[ -d "$dropin" ]] && rm -rf -- "$dropin"
  done
  systemctl --user daemon-reload

  for group in punktfunk punktfunk-update; do
    if getent group "$group" >/dev/null; then
      sudo gpasswd -d "$(id -un)" "$group" >/dev/null 2>&1 || true
    fi
  done
  # The door's system account may remain after switching loginless off.
  # userdel (without -r) intentionally preserves /var/lib/punktfunk data.
  if getent passwd punktfunk >/dev/null; then
    sudo userdel punktfunk || warn 'Could not remove Punktfunk system user'
  fi
  for group in punktfunk-games punktfunk-door punktfunk-update punktfunk; do
    if getent group "$group" >/dev/null; then
      sudo groupdel "$group" || warn "Could not remove group $group (check group usage)"
    fi
  done

  if streaming_group_member input && streaming_confirm 'Also remove your input group membership (may affect other software)?'; then
    sudo gpasswd -d "$(id -un)" input
  fi

  if [[ "$(loginctl show-user "$(id -un)" -p Linger --value)" == yes ]]; then
    warn 'Disabling lingering may stop other user services after you log out.'
    if streaming_confirm 'Disable lingering for your user?'; then
      sudo loginctl disable-linger "$(id -un)"
    fi
  fi

  log 'Punktfunk removed; ~/.config/punktfunk was preserved.'
  warn 'Reboot to apply removed group memberships and device rules.'
}

show_streaming_status() {
  log 'Punktfunk sysext'
  if command -v punktfunk-sysext >/dev/null 2>&1; then
    systemd-sysext list --no-pager 2>/dev/null | grep -i punktfunk || true
  else
    printf 'Not installed\n'
  fi
  log 'Punktfunk services'
  local unit
  for unit in punktfunk-host punktfunk-web; do
    printf '%s: enabled=' "$unit"
    systemctl --user is-enabled "$unit.service" 2>/dev/null || true
    printf '   active='
    systemctl --user is-active "$unit.service" 2>/dev/null || true
  done
  printf 'Lingering: '
  loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true
  printf 'Update group: '
  if streaming_group_member punktfunk-update; then
    printf 'member\n'
  else
    printf 'not a member\n'
  fi
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
    log 'Finished. Re-login if your Docker group membership changed.'
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
