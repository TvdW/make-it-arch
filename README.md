# Make it Arch!

Cloud providers don't always offer it, but I run Arch, btw.

This script can be used together with cloud-init to convert a running machine (Debian, Ubuntu, CentOS, etc) to ArchLinux.

**THIS SCRIPT WILL WIPE YOUR ROOT DEVICE.** For obvious reasons, do not run it on your personal device, or any device that has information you wish to keep.

## Usage

```yaml
#cloud-config
runcmd:
# Upgrade the machine to Arch Linux if we don't already have it
- grep -q ID=arch /etc/os-release || (curl -o /root/make-it-arch.sh https://raw.githubusercontent.com/TvdW/make-it-arch/refs/heads/main/install.sh && chmod +x /root/make-it-arch.sh && bash /root/make-it-arch.sh)

# Now, run the rest of your setup
- systemctl enable --now sshd
```

For any use case that benefits from remaining stable and reproducible, substitute the branch name (`main`) with a Git hash, so that changes to the script will not affect your setup.

## How does it work?

The script will:
1. Download the Arch Linux bootstrap tarball and GPG-verify it
1. Extract the tarball onto a temporary in-memory filesystem
1. Stop running processes on the system by first going into systemd's `rescue.target` and then manually stopping the rest
1. `pivot_root` to the new in-memory Arch installation
1. Re-execute systemd, and stop all remaining processes
1. Unmount all old filesystems, except `/dev`, `/run`, `/proc`, and `/sys`, which are moved instead
1. Create new filesystems on the local device
1. Use `pacstrap` and `pacman` to install a small Arch Linux installation containing a kernel, `grub`, and `cloud-init`
1. Reboot onto the fresh Arch Linux installation

## Compatibility

The script should work with any `x86_64` Linux distribution that runs systemd. I've tested the code with:

* Debian 12
* Ubuntu 22.04
* Ubuntu 24.04
* Ubuntu 26.04
