#!/usr/bin/env bash

# ----------------------------------------------------------------------------
# "THE BEER-WARE LICENSE" (Revision 42):
# Tom van der Woerdt wrote this file. As long as you retain this notice you
# can do whatever you want with this stuff. If we meet some day, and you think
# this stuff is worth it, you can buy me a beer in return
# ----------------------------------------------------------------------------

set -eo pipefail

exec 0<&-
trap "echo exit=\$?" EXIT
for sig in HUP INT TERM; do trap "echo caught $sig" $sig; done
set -x

create_newroot() {
    # Download and extract our bootstrap filesystem
    tmptar="$(pwd)"
    bootstrapfile="archlinux-bootstrap-x86_64.tar.zst"
    for file in $bootstrapfile $bootstrapfile.sig; do
        curl -o "${tmptar}/${file}" "https://geo.mirror.pkgbuild.com/iso/latest/${file}"
    done

    # Verify download
    gpg --auto-key-locate clear,wkd -v --locate-external-key pierre@archlinux.org
    gpg --verify "${tmptar}/${bootstrapfile}.sig"

    # Extract
    mkdir /newroot-tmp
    pushd /newroot-tmp
    tar xf "$tmptar/$bootstrapfile" \
        --numeric-owner \
        --strip-components=1 root.x86_64/
    mkdir -p {old,dev,proc,sys,run,tmp}
    cp "$0" /newroot-tmp/install.sh
    popd

    # Make sure the bootstrap system is ready to do work
    /newroot-tmp/bin/arch-chroot /newroot-tmp /install.sh prepare_bootstrap

    # Move it all to a tmpfs (we didn't put it there right away because we likely have more
    # local storage available than we do memory)
    mkdir -p /newroot
    mount -t tmpfs none /newroot
    mv /newroot-tmp/* /newroot
}

prepare_bootstrap() {
    curl https://archlinux.org/mirrorlist/all/ | sed 's/^#//' > /etc/pacman.d/mirrorlist
    pacman-key --init
    pacman-key --populate
    sed -i /CheckSpace/d /etc/pacman.conf
    pacman --noconfirm --disable-sandbox -Syu lvm2 e2fsprogs dosfstools parted
    # Minimize size, since we're about to move it all into a tmpfs
    pacman --noconfirm --disable-sandbox -Scc
    rm -rf /usr/share/{i18n,locale,man,doc,gir-1.0,file,terminfo,hwdata,iana-etc,kbd} /var/cache/pacman/pkg
}

switchroot() {
    # Shutdown anything non-essential
    systemctl isolate rescue.target ||:
    for service in $(systemctl list-units --state=active --no-legend --plain | awk '{print $1}' | grep -E '(service|socket|timer)$' | grep -v make-it-arch); do
        systemctl stop -- $service ||:
    done
    sleep 1
    for service in $(systemctl list-units --state=active --no-legend --plain | awk '{print $1}' | grep -E '(service|socket|timer)$' | grep -v make-it-arch); do
        systemctl kill -- $service ||:
    done
    udevadm info --cleanup-db ||:
    auditctl -D ||:

    # Unmount unhelpful filesystems
    for filesystem in $(cat /proc/mounts | grep -Ev ' /(run|dev|sys|proc)' | awk '{print $2}' | tac); do
        if [[ "$filesystem" != "/" && "$filesystem" != "/newroot" ]]; then
            while ! umount $filesystem; do sleep 1; done
        fi
    done

    # Do the actual root switch
    mount --make-rprivate /
    cd /newroot
    pivot_root /newroot /newroot/old
    for i in dev proc sys run; do mount --move /old/$i /$i; done

    # Congrats, you run Arch (bootstrap edition) now
    systemctl daemon-reexec # load arch's systemd
    systemctl status ||:
}

switchroot_pt2() {
    # unmount
    while ! umount /old; do
        fuser -kvm -9 /old ||:
        for fs in $(lsns -t mnt -Q 'NPROCS == 0' -o NSFS --noheadings | grep . ||:); do
            umount $fs ||:
        done
        sleep 5
    done

    # fork a journald tailer so we see what's happening
    journalctl -f &

    # Start a somewhat usable system again
    systemctl isolate rescue.target

    # Basic necessities for installing Arch
    systemctl restart systemd-networkd systemd-resolved
}

create_filesystems() {
    BLKDEV="/dev/$(lsblk -dno NAME | grep -v loop | head -1)"
    dmsetup remove_all
    wipefs -a "$BLKDEV"*

    # Setup new partitions
    sfdisk "$BLKDEV" <<EOPT
    label: gpt

    # grub
    ${BLKDEV}1 : start=        2048, size=       2048, type=21686148-6449-6E6F-744E-656564454649
    # /boot/efi
    ${BLKDEV}2 : start=        4096, size=     258048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
    # lvm
    ${BLKDEV}3 : start=      262144,                   type=E6D6D379-F507-44C2-A23C-238F2A3DF928
EOPT

    mkfs.fat -F 32 "${BLKDEV}2"
    pvcreate "${BLKDEV}3" --yes
    vgcreate sysvg "${BLKDEV}3"
    lvcreate sysvg -L 5G --name root --yes
    mkfs.ext4 /dev/mapper/sysvg-root

    mkdir -p /mnt/root
    mount /dev/mapper/sysvg-root /mnt/root
    mkdir -p /mnt/root/boot/efi
    mount "$BLKDEV"2 /mnt/root/boot/efi
}

install_new_os() {
    pacstrap -K -G /mnt/root base
    genfstab -U /mnt/root > /mnt/root/etc/fstab
    cp "$0" /mnt/root/install.sh
    arch-chroot /mnt/root /install.sh final_installation
    ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/root/etc/resolv.conf
    rm /mnt/root/install.sh
    reboot
}
final_installation() {
    pacman-key --init
    pacman-key --populate
    pacman --noconfirm --disable-sandbox -Syu mkinitcpio grub lvm2 e2fsprogs cloud-init qemu-guest-agent openssh
    systemctl enable qemu-guest-agent
    systemctl enable cloud-init-main.service
    systemctl enable cloud-final.service
    systemctl enable systemd-networkd.service
    systemctl enable systemd-resolved.service
    sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
    pacman --noconfirm --disable-sandbox -S linux
    grub-install --target=i386-pc "/dev/$(lsblk -dno NAME | grep -v loop | head -1)"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable

    # Build a new kernel cmdline based on what's running now plus what Arch puts there
    ARCH_CMDLINE=$(source /etc/default/grub; echo $GRUB_CMDLINE_LINUX_DEFAULT)
    OUR_CMDLINE=$(for term in $(cat /proc/cmdline); do echo $term; done | grep console=)
    NEW_CMDLINE="$(echo $(for term in $ARCH_CMDLINE $OUR_CMDLINE; do echo $term; done | grep -v quiet))"
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="'"$NEW_CMDLINE"'"/' /etc/default/grub

    grub-mkconfig -o /boot/grub/grub.cfg
}

PHASE="$1"
if [[ "$PHASE" == "" ]]; then
    systemd-run \
        --unit=make-it-arch \
        --collect \
        --system \
        --property=IgnoreOnIsolate=yes \
        --property=StandardOutput=tty \
        --property=StandardError=tty \
        -- bash "$0" pt1
    sleep 86400
elif [[ "$PHASE" == "pt1" ]]; then
    create_newroot
    switchroot
    exec /usr/bin/bash /install.sh pt2
elif [[ "$PHASE" == "pt2" ]]; then
    switchroot_pt2
    create_filesystems
    install_new_os

elif [[ "$PHASE" == "prepare_bootstrap" ]]; then
    prepare_bootstrap
elif [[ "$PHASE" == "final_installation" ]]; then
    final_installation
else
    echo >&2 Unknown phase $PHASE
    exit 1
fi
