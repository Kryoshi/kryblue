# kryblue

Customised Fedora Silverblue image built using [ublue-os/image-template](https://github.com/ublue-os/image-template). Built on top of the silverblue-main package (no Nvidia).

# Installation

- Install official [Fedora Silverblue ISO](https://fedoraproject.org/atomic-desktops/silverblue/download)
- Rebase to the unsigned base ublue image `rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/silverblue-main:44`
- Rebase to the signed custom image `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/kryoshi/kryzite-os:latest`
