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

# Run the official, checksum-verifying Punktfunk guided installer without
# piping an unaudited network response directly into a shell.
run_punktfunk_installer() {
  local installer rc
  need curl
  installer="$(mktemp "${TMPDIR:-/tmp}/punktfunk-install.XXXXXXXX.sh")" || return 1
  if ! curl -fsSL --retry 3 https://punktfunk.unom.io/install.sh -o "$installer"; then
    rm -f -- "$installer"
    warn 'Could not download the Punktfunk guided installer'
    return 1
  fi
  if sh "$installer" "$@"; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$installer"
  return "$rc"
}

# Fedora Atomic can expose vendor groups through /usr/lib/group without an
# /etc/group entry.  Some usermod/gpasswd operations then fail to persist.
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
    return 10  # Inform caller that reboot is needed.
  fi
  return 0
}

setup_streaming() {
  log 'Punktfunk streaming (Fedora Atomic sysext)'
  local user state_dir group had_input=0 had_linger=0 changed=0 rc
  user="$(id -un)"
  state_dir="$HOME/.local/state/kryblue/streaming"
  need sudo
  need loginctl
  need systemctl
  need getent
  if [[ ! -e /run/ostree-booted ]]; then
    warn 'This setup expects Fedora Atomic (an OSTree booted system) for the sysext install.'
    return 1
  fi
  mkdir -p "$state_dir"

  streaming_group_member input && had_input=1 || true
  [[ "$(loginctl show-user "$user" -p Linger --value)" == yes ]] && had_linger=1 || true

  if ! command -v punktfunk-sysext >/dev/null 2>&1; then
    log 'Punktfunk not installed; showing the official guided install plan'
    log 'Review carefully: Kryblue must use the Fedora Atomic sysext, not DNF layering.'
    run_punktfunk_installer --dry-run --host --channel stable \
      --linger --punktfunk-group --no-gamestream --no-console-cert

    if ! streaming_confirm 'Continue with the official interactive Punktfunk installer?'; then
      log 'Streaming installation cancelled'
      return 0
    fi
    # Upstream handles sysext download, service setup, firewall, port conflicts
    # with Sunshine, and the interactive first-use console password.
    run_punktfunk_installer --host --channel stable \
      --linger --punktfunk-group --no-gamestream --no-console-cert
  else
    log 'Punktfunk already installed; keeping the installed version and settings'
  fi

  if ! command -v punktfunk-host >/dev/null 2>&1 ||
     ! command -v punktfunk-sysext >/dev/null 2>&1; then
    warn 'Punktfunk sysext is not merged; check: sudo systemd-sysext status'
    return 1
  fi

  # The guided installer may use usermod. Repair Atomic group persistence and
  # ensure the update permission needed for loginless owner sessions.
  for group in input punktfunk punktfunk-update; do
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
  if (( ! had_input )) && streaming_group_member input; then
    touch "$state_dir/member-added.input"
    changed=1
  fi

  # If upstream enabled lingering, record that this setup introduced it.
  if [[ "$(loginctl show-user "$user" -p Linger --value)" != yes ]]; then
    sudo loginctl enable-linger "$user"
  fi
  if (( ! had_linger )) &&
     [[ "$(loginctl show-user "$user" -p Linger --value)" == yes ]]; then
    touch "$state_dir/linger-enabled"
  fi

  # The sysext normally supplies the udev rule; don't create a duplicate.
  if [[ ! -f /usr/lib/udev/rules.d/60-punktfunk.rules &&
        ! -f /etc/udev/rules.d/60-punktfunk.rules ]]; then
    warn 'Punktfunk udev rule missing; check controller support after reboot'
  else
    sudo udevadm control --reload-rules
    sudo udevadm trigger --action=add --subsystem-match=misc
  fi
  if [[ ! -e /dev/uinput ]]; then
    warn '/dev/uinput is missing; virtual controllers may not work'
  elif [[ "$(stat -c '%G' /dev/uinput)" != input ]]; then
    warn '/dev/uinput is not owned by input; check udev permissions'
  fi

  # Do not enable user services here: loginless/door mode uses a different
  # service arrangement. The guided installer already enables the normal host.
  if sudo test -s /var/lib/punktfunk-seats/owner; then
    log 'Loginless door mode is configured; leaving its services unchanged'
  fi

  if (( changed )); then
    warn 'Reboot before using newly granted controller/loginless permissions.'
  fi
  log 'For loginless streaming: open Web Console -> Profiles -> Reachable without logging in after reboot.'
  log 'To update Punktfunk later, use: sudo punktfunk-sysext update'
}

remove_streaming() {
  log 'Remove Punktfunk and system integration (preserve user configuration)'
  local user state_dir zone service group members marker
  local purge_port=0
  user="$(id -un)"
  state_dir="$HOME/.local/state/kryblue/streaming"
  need sudo
  need systemctl
  need loginctl

  # The door must release credentials/identity back to the user's home first.
  if sudo systemctl is-active --quiet punktfunk-door.service 2>/dev/null ||
     sudo test -s /var/lib/punktfunk-seats/owner; then
    warn 'Disable Profiles -> Reachable without logging in and remove extra seats first.'
    warn 'Verify credentials returned to ~/.config/punktfunk before uninstalling.'
    return 1
  fi

  if ! streaming_confirm 'Uninstall Punktfunk and its system components?'; then
    log 'Removal cancelled'
    return 0
  fi

  # Remove Punktfunk-specific firewall services. Keep unrelated numeric
  # ports unless the user explicitly approves their removal.
  if command -v firewall-cmd >/dev/null 2>&1 &&
     sudo firewall-cmd --state >/dev/null 2>&1; then
    log 'Removing Punktfunk-named firewall services (native, web, gamestream)'
    streaming_confirm 'Remove untracked TCP 47991 firewall rules too?' &&
      purge_port=1 || true

    for zone in $(sudo firewall-cmd --get-zones); do
      for service in punktfunk-native punktfunk-web punktfunk-gamestream; do
        marker="$state_dir/fw-service.$zone.$service"
        if sudo firewall-cmd --permanent --zone="$zone" \
             --query-service="$service" >/dev/null 2>&1; then
          sudo firewall-cmd --permanent --zone="$zone" --remove-service="$service"
        fi
        rm -f -- "$marker"
      done
      marker="$state_dir/fw-port.$zone.47991-tcp"
      if [[ -f "$marker" ]] || (( purge_port )); then
        if sudo firewall-cmd --permanent --zone="$zone" \
             --query-port=47991/tcp >/dev/null 2>&1; then
          sudo firewall-cmd --permanent --zone="$zone" --remove-port=47991/tcp
        fi
        rm -f -- "$marker"
      fi
    done
    sudo firewall-cmd --reload
  else
    warn 'Firewalld not running; check for remaining Punktfunk firewall rules'
  fi

  # Upstream handles stopping services and uninstalling the sysext; do not
  # delete its image/files manually before that process completes.
  if command -v punktfunk-sysext >/dev/null 2>&1; then
    run_punktfunk_installer --uninstall
  else
    log 'Punktfunk sysext already absent; cleaning remaining integration'
  fi

  # Upstream lists these as remaining after sysext removal.
  sudo rm -f /etc/modules-load.d/punktfunk.conf \
    /etc/udev/rules.d/60-punktfunk.rules
  sudo udevadm control --reload-rules
  rm -f "$HOME/.config/autostart/io.unom.punktfunk.tray.desktop"
  local dropin
  for dropin in "$HOME"/.config/systemd/user/punktfunk-*.service.d; do
    [[ -d "$dropin" ]] && rm -rf -- "$dropin"
  done
  systemctl --user daemon-reload
  sudo systemctl daemon-reload

  # Only remove the Punktfunk-specific account and groups, never arbitrary
  # nonempty groups or other users' memberships.
  if getent passwd punktfunk >/dev/null 2>&1; then
    sudo userdel punktfunk || warn 'Punktfunk system account could not be removed'
  fi
  for group in punktfunk punktfunk-update punktfunk-door punktfunk-games; do
    if getent group "$group" >/dev/null; then
      sudo gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
      members="$(getent group "$group" | cut -d: -f4)"
      if [[ -z "$members" ]]; then
        sudo groupdel "$group" || warn "Could not remove Punktfunk group: $group"
      else
        warn "Keeping group $group: other members remain ($members)"
      fi
    fi
  done

  # The input group is shared. A prior setup may have added the membership;
  # ask rather than revoking it silently, including on older installations.
  if getent group input >/dev/null 2>&1 && streaming_group_member input; then
    if streaming_confirm 'Remove your input-group membership? (may affect other apps)'; then
      sudo gpasswd -d "$user" input
      rm -f -- "$state_dir/member-added.input"
    fi
  fi
  if [[ -f "$state_dir/group-local-entry-created.input" ||
        -f "$state_dir/input-local-entry-created" ]] &&
     grep -q '^input:' /etc/group; then
    members="$(awk -F: '$1=="input" {print $4}' /etc/group)"
    if [[ -z "$members" ]]; then
      if streaming_confirm 'Remove the Kryblue-created local input-group override?'; then
        sudo groupdel input
        rm -f -- "$state_dir/group-local-entry-created.input" \
          "$state_dir/input-local-entry-created"
      fi
    else
      warn 'Keeping the local input-group override: members remain'
    fi
  fi

  # Lingering is shared with other user services (including Docker-related
  # workflows). Always ask before disabling it.
  if [[ "$(loginctl show-user "$user" -p Linger --value)" == yes ]]; then
    warn 'Disabling lingering may stop unrelated user services when you log out.'
    if streaming_confirm 'Disable lingering for your account?'; then
      sudo loginctl disable-linger "$user"
      rm -f -- "$state_dir/linger-enabled"
    fi
  fi

  # Keep any state files for cleanup that was declined/failed. User settings,
  # identity, console password, paired clients and plugins remain untouched.
  rmdir "$state_dir" 2>/dev/null || true
  log 'Punktfunk removed; ~/.config/punktfunk has been preserved.'
  warn 'Reboot after changing group membership or udev/device rules.'
}

show_streaming_status() {
  log 'Punktfunk sysext'
  if command -v punktfunk-sysext >/dev/null 2>&1; then
    systemd-sysext list --no-pager 2>/dev/null | grep -i punktfunk || true
  else
    printf 'Not installed\n'
  fi

  log 'Punktfunk user services'
  local unit
  for unit in punktfunk-host punktfunk-web; do
    printf '%s: enabled=' "$unit"
    systemctl --user is-enabled "$unit.service" 2>/dev/null || true
    printf '   active='
    systemctl --user is-active "$unit.service" 2>/dev/null || true
  done

  log 'Punktfunk loginless streaming'
  printf 'Door enabled: '
  systemctl is-enabled punktfunk-door.service 2>/dev/null || true
  printf 'Door active:  '
  systemctl is-active punktfunk-door.service 2>/dev/null || true
  printf 'Lingering:    '
  loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true
  for unit in input punktfunk punktfunk-update; do
    printf 'Group %-16s: ' "$unit"
    if streaming_group_member "$unit"; then
      printf 'member\n'
    else
      printf 'not a member\n'
    fi
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
