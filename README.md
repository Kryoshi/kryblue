# kryblue

Custom Fedora Atomic desktop image based on [Universal Blue's Silverblue Main](https://github.com/ublue-os/main), built using [ublue-os/image-template](https://github.com/ublue-os/image-template).

Designed as a minimal, general-purpose Silverblue workstation with additional development tools, gaming support, and GNOME customizations. Primarily intended for AMD hardware.

## Installation

### 1. Install Fedora Silverblue

Download and install the official [Fedora Silverblue ISO](https://fedoraproject.org/atomic-desktops/silverblue/download).

Prefer the same Fedora major version as the image's `Containerfile` (currently Fedora 44).

Intended storage layout:

| Drive      | Purpose                                          | Mount point |
| ---------- | ------------------------------------------------ | ----------- |
| 512 GB SSD | OS, boot partitions, system applications, Docker | `/`         |
| 2 TB SSD   | Home directories, games, projects, personal data | `/var/home` |

On Fedora Atomic, `/home` is a symlink to `/var/home`.

Keep the drives as separate filesystems. Back up important files before changing partitions.

### 2. Switch to Kryblue

Once the image has been successfully built and published to GHCR, run:

```bash
sudo bootc switch ghcr.io/kryoshi/kryblue:latest
sudo reboot
```

Verify the installation:

```bash
bootc status
```

If `bootc` is unavailable on the initial Fedora installation, first rebase to the unsigned Universal Blue base:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/silverblue-main:44
sudo reboot
```

Then switch to Kryblue using `bootc switch` as shown above.

**Note:** The initial `bootc switch` does not enforce Cosign signature verification by default. Enforcing signatures requires a trusted public key and container signature policy configured for the custom image.

### 3. Post-installation

Clone the repository and run the setup script:

```bash
git clone https://github.com/Kryoshi/kryblue.git
cd kryblue
bash repo_files/setup.sh
```

The script configures:

- Git identity and GitHub authentication
- Docker Engine and user permissions
- Starship and Ptyxis preferences
- Flathub applications from the shared GitHub manifest
- Migration away from Fedora Flatpaks

Log out and back in after setup to apply Docker group membership.

The setup script can be rerun to synchronize applications or restore configuration.

```bash
# Synchronize Flatpak applications
bash repo_files/setup.sh flatpaks

# Check system configuration
bash repo_files/setup.sh status
```

## Updates

Update the installed image:

```bash
sudo bootc upgrade
sudo reboot
```

Check the current deployment:

```bash
bootc status
```

The image uses the `latest` tag, while the Fedora major version is controlled by the `Containerfile`.

## Rollback

If an update causes problems, boot into the previous deployment from the boot menu, or run:

```bash
sudo rpm-ostree rollback
sudo reboot
```

## Building

The custom image is automatically built and published to GitHub Container Registry using GitHub Actions.

System packages and configuration are defined in `Containerfile` and `build_files/build.sh`.

User-specific settings and Flatpak applications are managed separately through `postinstall.sh`.
