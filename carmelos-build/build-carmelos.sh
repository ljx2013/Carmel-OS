#!/bin/bash
# ─────────────────────────────────────────────────────────────
# CarmelOS manual build script
# Sandbox forbids mount (no cap_sys_admin), so live-build's
# lb_chroot can't run. We drive the chroot phase with plain
# `chroot` (native speed, cap_sys_chroot is present) and only
# fall back to proot for initramfs generation (needs /proc).
# ─────────────────────────────────────────────────────────────
set -e
export LC_ALL=C

BUILD=/workspace/carmelos-build
CHROOT=$BUILD/chroot
CFG=$BUILD/config
OUT=$BUILD/binary
ISO=$BUILD/CarmelOS.iso
PROXY=http://127.0.0.1:18080

# fast: plain chroot (shares net namespace so 127.0.0.1 proxy works)
run_chroot() {
  chroot "$CHROOT" env \
    http_proxy=$PROXY https_proxy=$PROXY \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    "$@"
}
# slow but provides /proc: proot (only for initramfs)
run_proot() {
  proot -r "$CHROOT" -b /dev:/dev -b /proc:/proc -b /sys:/sys \
    -b /etc/resolv.conf:/etc/resolv.conf -b /tmp:/tmp -w / \
    env http_proxy=$PROXY https_proxy=$PROXY \
        DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root "$@"
}
stage() { echo; echo "════════ $* ════════"; }

# ensure DNS resolution works inside the chroot
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# ── Stage 1: install packages (fast chroot) ──────────────────
stage "1/7  apt-get install (via chroot)"
PKGS=$(grep -vE '^\s*#|^\s*$' "$CFG/package-lists/carmelos-desktop.list.chroot" | tr '\n' ' ')
echo "Packages: $PKGS"

# Fake update-initramfs / update-grub during install so the kernel
# postinst doesn't fail on the missing /proc filesystem. We regenerate
# the initrd for real (via proot) in stage 5.
UI_REAL="$CHROOT/usr/sbin/update-initramfs"
if [ -x "$UI_REAL" ] && [ ! -e "$UI_REAL.real" ]; then
  mv "$UI_REAL" "$UI_REAL.real"
fi
printf '#!/bin/sh\necho "[carmelos] (fake) update-initramfs $*"\nexit 0\n' > "$UI_REAL"
chmod +x "$UI_REAL"
if [ -e "$CHROOT/usr/sbin/update-grub" ] && [ ! -e "$CHROOT/usr/sbin/update-grub.real" ]; then
  mv "$CHROOT/usr/sbin/update-grub" "$CHROOT/usr/sbin/update-grub.real"
  printf '#!/bin/sh\necho "[carmelos] (fake) update-grub $*"\nexit 0\n' > "$CHROOT/usr/sbin/update-grub"
  chmod +x "$CHROOT/usr/sbin/update-grub"
fi

run_chroot apt-get update
# dpkg will warn about /dev/pts (no pty) — harmless; ignore that stderr noise
run_chroot apt-get install -y --no-install-recommends $PKGS || {
  echo "apt-get install returned non-zero, retrying once to resolve ordering issues"
  run_chroot apt-get install -y --no-install-recommends $PKGS
}
run_chroot apt-get -f install -y

# restore real update-initramfs
[ -e "$UI_REAL.real" ] && mv "$UI_REAL.real" "$UI_REAL"
[ -e "$CHROOT/usr/sbin/update-grub.real" ] && mv "$CHROOT/usr/sbin/update-grub.real" "$CHROOT/usr/sbin/update-grub"

# ── Stage 2: copy branding / includes into chroot ─────────────
stage "2/7  copying CarmelOS branding into chroot"
cp -aT "$CFG/includes.chroot/." "$CHROOT/"

# ── Stage 3: run the branding hook inside the chroot ──────────
stage "3/7  running branding hook (sudoers, locale, caches, greeter)"
cp -f "$CFG/hooks/normal/carmelos-branding.hook.chroot" "$CHROOT/carmelos-branding.hook"
run_chroot bash /carmelos-branding.hook || echo "(hook had non-fatal warnings)"
run_chroot rm -f /carmelos-branding.hook

# ── Stage 4: live-boot configuration ─────────────────────────
stage "4/7  configuring live-boot"
cat > "$CHROOT/etc/live.conf" <<'LIVECONF'
LIVE_USERNAME="carmel"
LIVE_USER_FULLNAME="Carmel"
LIVE_HOSTNAME="carmelos"
LIVE_LOCALES="en_US.UTF-8"
LIVE_KEYBOARD_LAYOUTS="us"
LIVE_NOCONFIGURATIONS="false"
LIVECONF
mkdir -p "$CHROOT/etc/initramfs-tools/conf.d"
echo "BOOT=live" > "$CHROOT/etc/initramfs-tools/conf.d/live-boot"
grep -q "^overlay$"  "$CHROOT/etc/initramfs-tools/modules" || echo "overlay"  >> "$CHROOT/etc/initramfs-tools/modules"
grep -q "^squashfs$" "$CHROOT/etc/initramfs-tools/modules" || echo "squashfs" >> "$CHROOT/etc/initramfs-tools/modules"
# loop module too (live-boot mounts the squashfs via loop on some setups)
grep -q "^loop$"     "$CHROOT/etc/initramfs-tools/modules" || echo "loop"     >> "$CHROOT/etc/initramfs-tools/modules"

# ── Stage 5: (re)generate initramfs via proot (needs /proc) ───
stage "5/7  regenerating initramfs (live-boot aware, via proot)"
KVER=$(ls "$CHROOT/lib/modules" 2>/dev/null | sort -V | tail -1)
echo "kernel version: $KVER"
run_proot update-initramfs -u -k "$KVER" || run_proot update-initramfs -c -k "$KVER"

# ── Stage 6: cleanup chroot to shrink the ISO ─────────────────
stage "6/7  cleaning chroot"
run_chroot apt-get clean
run_chroot apt-get autoremove -y 2>/dev/null || true
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb
rm -rf "$CHROOT/tmp/"* "$CHROOT/var/tmp/"*
rm -rf "$CHROOT/usr/share/doc" "$CHROOT/usr/share/man" "$CHROOT/usr/share/info"
rm -f  "$CHROOT/var/log/"*.log "$CHROOT/var/log/apt/"* "$CHROOT/var/log/journal/"* 2>/dev/null || true
[ -d "$CHROOT/home/carmel" ] && chown -R 1000:1000 "$CHROOT/home/carmel" 2>/dev/null || true

# ── Stage 7: build squashfs + assemble hybrid ISO ─────────────
stage "7/7  building squashfs and ISO"
rm -rf "$OUT" "$ISO"
mkdir -p "$OUT/live" "$OUT/isolinux" "$OUT/boot/grub" "$OUT/EFI/BOOT"

mksquashfs "$CHROOT" "$OUT/live/filesystem.squashfs" -comp xz -Xbcj x86 -noappend

VMLINUZ=$(ls "$CHROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls  "$CHROOT"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
echo "kernel: $(basename "$VMLINUZ")  initrd: $(basename "$INITRD")"
cp "$VMLINUZ" "$OUT/live/vmlinuz"
cp "$INITRD"  "$OUT/live/initrd.img"

# isolinux (BIOS)
ISODIR=$(dirname "$(find /usr/lib /usr/share -name isolinux.bin 2>/dev/null | head -1)")
for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32 menu.c32; do
  [ -f "$ISODIR/$f" ] && cp "$ISODIR/$f" "$OUT/isolinux/"
done
cp "$CFG/bootloaders/isolinux/"* "$OUT/isolinux/"
sed -e 's/@FLAVOUR@/carmelos/g' \
    -e 's|@KERNEL@|/live/vmlinuz|g' \
    -e 's|@INITRD@|/live/initrd.img|g' \
    -e 's|@LB_BOOTAPPEND_LIVE@|boot=live components username=carmel hostname=carmelos locales=en_US.UTF-8 keyboard-layouts=us|g' \
    -e 's|@LB_BOOTAPPEND_FAILSAFE@|nomodeset vga=normal|g' \
    "$CFG/bootloaders/isolinux/live.cfg.in" > "$OUT/isolinux/live.cfg"

# grub (UEFI)
cat > "$OUT/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5
insmod all_video
set gfxpayload=keep
menuentry "CarmelOS 1.0 (Live)" {
    linux /live/vmlinuz boot=live components username=carmel hostname=carmelos locales=en_US.UTF-8 keyboard-layouts=us
    initrd /live/initrd.img
}
menuentry "CarmelOS 1.0 (failsafe mode)" {
    linux /live/vmlinuz boot=live components username=carmel hostname=carmelos nomodeset vga=normal
    initrd /live/initrd.img
}
GRUB

# UEFI boot image
EFI_BUILT=no
GRUBEFI=/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi
if [ -f "$GRUBEFI" ] && command -v mformat >/dev/null 2>&1; then
  cp "$GRUBEFI" "$OUT/EFI/BOOT/BOOTX64.EFI"
  mkdir -p "$OUT/EFI/BOOT/grub"
  cp "$OUT/boot/grub/grub.cfg" "$OUT/EFI/BOOT/grub/grub.cfg"
  dd if=/dev/zero of="$OUT/boot/efi.img" bs=1M count=4 status=none
  mformat -i "$OUT/boot/efi.img" -F ::
  mmd    -i "$OUT/boot/efi.img" ::/EFI ::/EFI/BOOT ::/boot ::/boot/grub
  mcopy  -i "$OUT/boot/efi.img" "$OUT/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
  mcopy  -i "$OUT/boot/efi.img" "$OUT/boot/grub/grub.cfg"  ::/boot/grub/
  EFI_BUILT=yes
  echo "UEFI efi.img built"
fi

XORRISO_ARGS=(
  -as mkisofs -r -V CarmelOS -J -joliet-long
  -b isolinux/isolinux.bin -c isolinux/boot.cat
  -no-emul-boot -boot-load-size 4 -boot-info-table
  -input-charset utf-8
)
if [ "$EFI_BUILT" = "yes" ]; then
  XORRISO_ARGS+=(
    -eltorito-alt-boot -e boot/efi.img -no-emul-boot
    -isohybrid-gpt-basdat
  )
fi
XORRISO_ARGS+=( -o "$ISO" "$OUT" )
xorriso "${XORRISO_ARGS[@]}"
command -v isohybrid >/dev/null 2>&1 && isohybrid "$ISO" 2>/dev/null || true

echo
echo "════════ CarmelOS ISO built ════════"
ls -lh "$ISO"
echo "live/ contents:"; ls -lh "$OUT/live"
echo "isolinux/ contents:"; ls "$OUT/isolinux"
