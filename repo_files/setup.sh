#!/usr/bin/env bash
# Kryblue / Kryzite: repeatable user setup after an Atomic OS installation.
# Usage: ./setup.sh [all|git|docker|starship|ptyxis|flatpaks|sunshine|status]
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

  log 'Maximise button'
  gsettings set org.gnome.desktop.wm.preferences button-layout ':maximize,close'
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

setup_sunshine() {
  log 'Sunshine game streaming'
  need sunshine
  systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
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

  log 'Sunshine'
  rpm -q Sunshine || true

  log 'Sunshine service'
  printf 'Enabled: '
  systemctl --user is-enabled app-dev.lizardbyte.app.Sunshine.service || true
  printf 'Active:  '
  systemctl --user is-active app-dev.lizardbyte.app.Sunshine.service || true
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
    setup_sunshine
    log 'Finished. Re-login if your Docker group membership changed.'
    ;;
  git) setup_git ;;
  docker) setup_docker ;;
  starship) setup_starship ;;
  gnome) setup_gnome ;;
  flatpaks) setup_flatpaks ;;
  sunshine) setup_sunshine ;;
  status) show_status ;;
  -h|--help|help)
    printf 'Usage: %s [all|git|docker|starship|ptyxis|flatpaks|sunshine|status]\n' "$0"
    ;;
  *)
    printf 'Unknown task: %s\n' "$1" >&2
    exit 2
    ;;
esac
