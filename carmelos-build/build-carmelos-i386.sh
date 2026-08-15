#!/bin/bash
# CarmelOS i386 (32-bit) ISO builder
# 内核不支持IA32仿真(CONFIG_IA32_EMULATION=n)，全程使用 proot -q qemu-i386-static 执行chroot
set -e
export LC_ALL=C
export PATH="/usr/local/bin:$PATH"

BUILD=/workspace/carmelos-build
CHROOT=$BUILD/chroot-i386
CFG=$BUILD/config
OUT=$BUILD/binary-i386
ISO=$BUILD/CarmelOS-i386.iso
PROXY="${HTTP_PROXY:-}"

stage() { echo; echo "════════ $(date '+%H:%M:%S')  $* ════════"; }

# ── qemu/proot 执行器（i386二进制专用）────────────────────────
run_proot_i386() {
  proot -r "$CHROOT" \
    -q /usr/bin/qemu-i386-static \
    -b /dev:/dev -b /proc:/proc -b /sys:/sys \
    -b /etc/resolv.conf:/etc/resolv.conf \
    -b /tmp:/tmp -w / \
    -0 \
    env http_proxy="$PROXY" https_proxy="$PROXY" \
        HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" \
        DEBIAN_FRONTEND=noninteractive \
        DEBCONF_FRONTEND=noninteractive \
        DEBCONF_NONINTERACTIVE_SEEN=true \
        DEBCONF_NOWARNINGS=1 \
        DEBCONF_PRIORITY=critical \
        PERL_BADLANG=0 \
        UCF_FORCE_CONFFOLD=1 \
        APT_LISTBUGS_FRONTEND=none \
        APT_LISTCHANGES_FRONTEND=none \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root "$@"
}

# ══════════════════════════════════════════════════════════════
# Stage 0: debootstrap --foreign (host工具完成，无需执行i386二进制)
# ══════════════════════════════════════════════════════════════
stage "0/9  debootstrap bookworm i386 (--foreign 只下载解压)"
rm -rf "$CHROOT"
mkdir -p "$CHROOT"
CACHE="$BUILD/cache/bootstrap"
mkdir -p "$CACHE"
SUITE=bookworm
ARCH=i386
MIRRORS=(
  "http://mirrors.ustc.edu.cn/debian"
  "http://mirrors.aliyun.com/debian"
  "http://ftp.cn.debian.org/debian"
  "http://deb.debian.org/debian"
)
# --foreign 与 --make-tarball 互斥，foreign模式下不缓存tarball
TRY=0; SUCCESS=0
while [ $TRY -lt 4 ]; do
  TRY=$((TRY+1))
  rm -rf "$CHROOT" 2>/dev/null || true
  mkdir -p "$CHROOT"
  for MIRROR in "${MIRRORS[@]}"; do
    echo "  try $TRY  mirror=$MIRROR"
    if debootstrap \
        --foreign \
        --arch="$ARCH" \
        --variant=minbase \
        --components="main,contrib,non-free,non-free-firmware" \
        --include="debian-archive-keyring,apt-transport-https,ca-certificates,locales,openssl,passwd,login,systemd" \
        --no-check-gpg \
        "$SUITE" "$CHROOT" "$MIRROR"; then
      SUCCESS=1; break 2
    fi
    echo "    mirror failed"
    sleep 2
  done
  sleep 3
done
if [ "$SUCCESS" != "1" ] || [ ! -f "$CHROOT/debootstrap/debootstrap" ]; then
  echo "debootstrap --foreign FAILED" >&2; exit 2
fi
echo "debootstrap foreign stage OK"

# 复制 qemu-i386-static 到 chroot (proot 可能需要，虽然 -q 参数用的是host路径)
mkdir -p "$CHROOT/usr/bin"
cp -f /usr/bin/qemu-i386-static "$CHROOT/usr/bin/" || true

# 基础目录 + DNS
mkdir -p "$CHROOT/etc" "$CHROOT/tmp" "$CHROOT/dev" "$CHROOT/proc" "$CHROOT/sys"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || \
  echo 'nameserver 1.1.1.1' > "$CHROOT/etc/resolv.conf"

# ══════════════════════════════════════════════════════════════
# Stage 1: debootstrap 第二阶段 (proot+qemu-i386-static 中运行)
# ══════════════════════════════════════════════════════════════
stage "1/9  debootstrap --second-stage (proot qemu-i386)"
# 预配置 insecure apt + 国内镜像
mkdir -p "$CHROOT/etc/apt/apt.conf.d" "$CHROOT/etc/apt/sources.list.d"
cat > "$CHROOT/etc/apt/sources.list" <<SRCLIST
deb [trusted=yes] http://mirrors.ustc.edu.cn/debian bookworm main contrib non-free non-free-firmware
deb [trusted=yes] http://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
deb [trusted=yes] http://mirrors.ustc.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware
SRCLIST
cat > "$CHROOT/etc/apt/apt.conf.d/99-carmelos-retries" <<APTCONF
Acquire::Retries "5";
Acquire::http::Timeout "120";
Acquire::https::Timeout "120";
Acquire::Queue-Mode "host";
APT::Get::AllowUnauthenticated "true";
APT::Get::Assume-Yes "true";
DPkg::Options:: "--force-confold";
APTCONF
cat > "$CHROOT/etc/apt/apt.conf.d/99insecure" <<'EOF'
APT::Get::AllowUnauthenticated "true";
Acquire::AllowInsecureRepositories "true";
Acquire::Check-Valid-Until "false";
EOF

# 运行second-stage
TRY=0
while [ $TRY -lt 3 ]; do
  TRY=$((TRY+1))
  if run_proot_i386 /debootstrap/debootstrap --second-stage; then
    echo "second-stage OK"
    break
  else
    echo "second-stage try $TRY failed, repair dpkg state..."
    run_proot_i386 dpkg --configure -a 2>/dev/null || true
    sleep 3
  fi
done
if [ ! -x "$CHROOT/usr/bin/bash" ]; then
  echo "second-stage produced no /usr/bin/bash. abort." >&2
  exit 3
fi
echo "second-stage 完成"

# ══════════════════════════════════════════════════════════════
# Stage 2: apt install 桌面 + live 包
# ══════════════════════════════════════════════════════════════
stage "2/9  apt-get install 桌面+live包 (qemu-i386下运行 较慢...)"
# Fake update-initramfs + update-grub: 内核postinst在没有/proc完整挂载时会失败。稍后stage 6真的生成一次。
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

# 从 package-list 文件读取完整桌面包，剔除 amd64 专用内核（i386用linux-image-686，已在 LIVE_PKGS 中）
CFG_PKGS=$(grep -vE '^\s*#|^\s*$|linux-image-amd64' "$CFG/package-lists/carmelos-desktop.list.chroot" | tr '\n' ' ')
echo "来自carmelos-desktop.list.chroot的包 (剔除linux-image-amd64):"
echo "  $CFG_PKGS"

run_proot_i386 apt-get update -o Acquire::Check-Valid-Until=false || true

# 分批安装 避免qemu下内存/超时爆
BASE_PKGS="sudo locales-all console-setup keyboard-configuration kmod xz-utils wget curl ca-certificates file bzip2 gzip"
LIVE_PKGS="linux-image-686 live-boot live-boot-initramfs-tools live-config live-config-systemd initramfs-tools busybox-static"
# DESKTOP_PKGS = package-list 全文 + task-xfce-desktop (元包补全 recommends) + lightdm + pulseaudio栈
DESKTOP_PKGS="task-xfce-desktop $CFG_PKGS"

install_batch() {
  local label="$1"; shift
  stage "  -> apt install $label"
  local tries=0
  while [ $tries -lt 3 ]; do
    tries=$((tries+1))
    if run_proot_i386 apt-get install -y --no-install-recommends "$@"; then
      echo "  $label install OK"; return 0
    fi
    echo "  $label try $tries failed, dpkg --configure -a retry"
    run_proot_i386 dpkg --configure -a --force-depends 2>/dev/null || true
    run_proot_i386 apt-get install -f -y 2>/dev/null || true
    sleep 5
  done
  echo "  $label gave up after 3 tries (non-fatal if core packages present)"
  return 1
}

install_batch "基础系统包" $BASE_PKGS || true
install_batch "内核+live-boot"  $LIVE_PKGS || true
install_batch "Xfce桌面 (慢)"   $DESKTOP_PKGS || true

# 修复依赖 + 清理
run_proot_i386 apt-get -f install -y 2>/dev/null || true
run_proot_i386 dpkg --configure -a --force-depends 2>/dev/null || true

# 还原真update-initramfs
[ -e "$UI_REAL.real" ] && mv "$UI_REAL.real" "$UI_REAL" || true
[ -e "$CHROOT/usr/sbin/update-grub.real" ] && mv "$CHROOT/usr/sbin/update-grub.real" "$CHROOT/usr/sbin/update-grub" || true

# 验证核心包是否真的安装
echo "=== 安装后验证 ==="
for pkg in linux-image-686 xfce4-session lightdm live-boot live-config; do
  if run_proot_i386 dpkg -l "$pkg" 2>/dev/null | grep -qE "^ii"; then
    echo "  OK  $pkg"
  else
    echo "  WARN: $pkg not fully installed, attempting one more time..."
    run_proot_i386 apt-get install -y --no-install-recommends --fix-missing "$pkg" 2>/dev/null || true
  fi
done

# ══════════════════════════════════════════════════════════════
# Stage 3: 复制CarmelOS branding / includes
# ══════════════════════════════════════════════════════════════
stage "3/9  复制branding + includes.chroot"
cp -aT "$CFG/includes.chroot/." "$CHROOT/" || true

# ══════════════════════════════════════════════════════════════
# Stage 4: 运行 branding hook (密码+locale+autologin+主题缓存)
# ══════════════════════════════════════════════════════════════
stage "4/9  运行 branding hook"
cp -f "$CFG/hooks/normal/carmelos-branding.hook.chroot" "$CHROOT/carmelos-branding.hook"
run_proot_i386 bash /carmelos-branding.hook 2>&1 | tail -10 || echo "(hook非致命警告忽略)"
run_proot_i386 rm -f /carmelos-branding.hook

# ══════════════════════════════════════════════════════════════
# Stage 5: live-boot 配置 + i686 标记
# ══════════════════════════════════════════════════════════════
stage "5/9  live.conf + 模块 + i686架构标记"
cat > "$CHROOT/etc/live.conf" <<LIVECONF
LIVE_USERNAME="carmel"
LIVE_USER_FULLNAME="Carmel"
LIVE_HOSTNAME="carmelos"
LIVE_LOCALES="en_US.UTF-8"
LIVE_KEYBOARD_LAYOUTS="us"
LIVE_NOCONFIGURATIONS="false"
LIVE_PASSWORD="carmel"
LIVECONF

mkdir -p "$CHROOT/etc/initramfs-tools/conf.d"
echo "BOOT=live" > "$CHROOT/etc/initramfs-tools/conf.d/live-boot"
for mod in overlay squashfs loop; do
  grep -q "^${mod}$" "$CHROOT/etc/initramfs-tools/modules" 2>/dev/null || echo "$mod" >> "$CHROOT/etc/initramfs-tools/modules"
done

# /etc/issue 标记 i686 (32位)
cat > "$CHROOT/etc/issue" <<'ISSUE'
CarmelOS 1.0 \n \l (i686 / 32-bit)
ISSUE
cp -f "$CHROOT/etc/issue" "$CHROOT/etc/issue.net" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# Stage 6: 生成 initramfs (必须通过proot, 因/lib/modules是i386内核版本)
# ══════════════════════════════════════════════════════════════
stage "6/9  生成 i386 initramfs (live-boot aware)"
KVER=$(ls "$CHROOT/lib/modules" 2>/dev/null | sort -V | tail -1)
echo "  kernel version: $KVER"
if [ -z "$KVER" ]; then
  echo "ERROR: 没找到 /lib/modules 下的内核版本号! 检查 linux-image-686 是否成功安装"
  echo "chroot /lib/modules 内容:"
  ls -la "$CHROOT/lib/modules" 2>/dev/null
  exit 5
fi
TRY=0
while [ $TRY -lt 3 ]; do
  TRY=$((TRY+1))
  if run_proot_i386 update-initramfs -u -k "$KVER"; then
    echo "  update-initramfs OK"
    break
  fi
  echo "  update-initramfs try $TRY failed, 改用 -c create 模式"
  run_proot_i386 update-initramfs -c -k "$KVER" 2>/dev/null && break
  sleep 3
done

VMLINUZ=$(ls "$CHROOT/boot/vmlinuz-${KVER}" 2>/dev/null | head -1)
INITRD=$(ls  "$CHROOT/boot/initrd.img-${KVER}" 2>/dev/null | head -1)
if [ -z "$VMLINUZ" ] || [ ! -s "$INITRD" ]; then
  echo "  vmlinuz / initrd 缺失，尝试手动find:"
  find "$CHROOT/boot" -maxdepth 2 -type f \( -name "vmlinuz*" -o -name "initrd*" \) 2>/dev/null
  VMLINUZ=$(find "$CHROOT/boot" -maxdepth 2 -name "vmlinuz*" -type f | sort -V | tail -1)
  INITRD=$(find  "$CHROOT/boot" -maxdepth 2 -name "initrd.img*" -type f | sort -V | tail -1)
  echo "  fallback: vmlinuz=$VMLINUZ initrd=$INITRD"
fi
[ -z "$VMLINUZ" ] || [ -z "$INITRD" ] && { echo "FATAL: kernel or initrd missing!"; exit 6; }
echo "  kernel: $(basename "$VMLINUZ")  size=$(stat -c%s "$VMLINUZ" 2>/dev/null)"
echo "  initrd: $(basename "$INITRD")  size=$(stat -c%s "$INITRD" 2>/dev/null)"
file "$VMLINUZ" | head -1

# ══════════════════════════════════════════════════════════════
# Stage 7: cleanup chroot 瘦身
# ══════════════════════════════════════════════════════════════
stage "7/9  清理 chroot"
run_proot_i386 apt-get clean 2>/dev/null || true
run_proot_i386 apt-get autoremove -y 2>/dev/null || true
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb 2>/dev/null || true
rm -rf "$CHROOT/tmp/"* "$CHROOT/var/tmp/"* 2>/dev/null || true
rm -rf "$CHROOT/usr/share/doc" "$CHROOT/usr/share/man" "$CHROOT/usr/share/info" 2>/dev/null || true
rm -f "$CHROOT/var/log/"*.log "$CHROOT/var/log/apt/"* "$CHROOT/var/log/journal/"* 2>/dev/null || true
# carmel home
[ -d "$CHROOT/home/carmel" ] && chown -R 1000:1000 "$CHROOT/home/carmel" 2>/dev/null || true
# 删除 qemu-i386-static (最终ISO不需要)
rm -f "$CHROOT/usr/bin/qemu-i386-static" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# Stage 8: squashfs + 组装 hybrid ISO
# ══════════════════════════════════════════════════════════════
stage "8/9  构建 squashfs + hybrid ISO (CarmelOS-i386.iso)"
rm -rf "$OUT" "$ISO"
mkdir -p "$OUT/live" "$OUT/isolinux" "$OUT/boot/grub" "$OUT/EFI/BOOT"

echo "  mksquashfs (xz)... (rootfs大小会较大，请耐心等待)"
mksquashfs "$CHROOT" "$OUT/live/filesystem.squashfs" -comp xz -noappend -processors 2 2>&1 | tail -3

cp "$VMLINUZ" "$OUT/live/vmlinuz"
cp "$INITRD"  "$OUT/live/initrd.img"
echo "  live/ 目录:"; ls -lh "$OUT/live"

# ── ISOLINUX BIOS 引导 ──
SYSDIR=/usr/lib/syslinux/modules/bios
ISODIR=/usr/lib/ISOLINUX
for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32 menu.c32; do
  for d in $ISODIR $SYSDIR /usr/lib/syslinux/modules/efi32; do
    [ -f "$d/$f" ] && { cp "$d/$f" "$OUT/isolinux/"; break; }
  done
done
cp "$CFG/bootloaders/isolinux/"* "$OUT/isolinux/" 2>/dev/null || true
# 替换 live.cfg.in -> live.cfg
sed -e 's/@FLAVOUR@/carmelos-i386/g' \
    -e 's|@KERNEL@|/live/vmlinuz|g' \
    -e 's|@INITRD@|/live/initrd.img|g' \
    -e 's|@LB_BOOTAPPEND_LIVE@|boot=live components username=carmel live-password=carmel hostname=carmelos locales=en_US.UTF-8 keyboard-layouts=us|g' \
    -e 's|@LB_BOOTAPPEND_FAILSAFE@|nomodeset vga=normal|g' \
    "$CFG/bootloaders/isolinux/live.cfg.in" > "$OUT/isolinux/live.cfg" 2>/dev/null || \
cat > "$OUT/isolinux/live.cfg" <<ISOCFG
label live
  menu label ^CarmelOS 1.0 (i686 Live)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live components username=carmel live-password=carmel hostname=carmelos locales=en_US.UTF-8 keyboard-layouts=us quiet splash
label failsafe
  menu label CarmelOS 1.0 (^Failsafe mode)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live components username=carmel live-password=carmel nomodeset vga=normal
ISOCFG
[ -f "$OUT/isolinux/isolinux.cfg" ] || cp "$OUT/isolinux/live.cfg" "$OUT/isolinux/isolinux.cfg"

# ── GRUB UEFI 双架构引导 (64+32位EFI) ──
cat > "$OUT/boot/grub/grub.cfg" <<GRUB
set default=0
set timeout=5
insmod all_video
set gfxpayload=keep
menuentry "CarmelOS 1.0 (Live - i686 32-bit)" {
    linux /live/vmlinuz boot=live components username=carmel live-password=carmel hostname=carmelos locales=en_US.UTF-8 keyboard-layouts=us
    initrd /live/initrd.img
}
menuentry "CarmelOS 1.0 (Failsafe - i686)" {
    linux /live/vmlinuz boot=live components username=carmel live-password=carmel hostname=carmelos nomodeset vga=normal
    initrd /live/initrd.img
}
GRUB

EFI_BUILT=no
if command -v mformat >/dev/null 2>&1; then
  GRUB_64=/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi
  GRUB_32=/usr/lib/grub/i386-efi/monolithic/grubia32.efi
  [ -f "$GRUB_64" ] && { mkdir -p "$OUT/EFI/BOOT"; cp "$GRUB_64" "$OUT/EFI/BOOT/BOOTX64.EFI"; }
  [ -f "$GRUB_32" ] && { mkdir -p "$OUT/EFI/BOOT"; cp "$GRUB_32" "$OUT/EFI/BOOT/BOOTIA32.EFI"; }
  if [ -f "$OUT/EFI/BOOT/BOOTX64.EFI" ] || [ -f "$OUT/EFI/BOOT/BOOTIA32.EFI" ]; then
    mkdir -p "$OUT/EFI/BOOT/grub"
    cp "$OUT/boot/grub/grub.cfg" "$OUT/EFI/BOOT/grub/grub.cfg"
    dd if=/dev/zero of="$OUT/boot/efi.img" bs=1M count=8 status=none
    mformat -i "$OUT/boot/efi.img" -F :: 2>/dev/null || mkfs.fat -F12 "$OUT/boot/efi.img" 2>/dev/null || true
    if command -v mmd >/dev/null 2>&1; then
      mmd    -i "$OUT/boot/efi.img" ::/EFI ::/EFI/BOOT ::/boot ::/boot/grub 2>/dev/null || true
      [ -f "$OUT/EFI/BOOT/BOOTX64.EFI" ]  && mcopy -i "$OUT/boot/efi.img" "$OUT/EFI/BOOT/BOOTX64.EFI"  ::/EFI/BOOT/ 2>/dev/null || true
      [ -f "$OUT/EFI/BOOT/BOOTIA32.EFI" ] && mcopy -i "$OUT/boot/efi.img" "$OUT/EFI/BOOT/BOOTIA32.EFI" ::/EFI/BOOT/ 2>/dev/null || true
      mcopy  -i "$OUT/boot/efi.img" "$OUT/boot/grub/grub.cfg"  ::/boot/grub/ 2>/dev/null || true
      EFI_BUILT=yes
    fi
  fi
fi
echo "  UEFI efi.img built: $EFI_BUILT"

# ── xorriso hybrid ISO ──
XORRISO_ARGS=(
  -as mkisofs -r -V 'CarmelOS-i386' -J -joliet-long
  -b isolinux/isolinux.bin -c isolinux/boot.cat
  -no-emul-boot -boot-load-size 4 -boot-info-table
  -input-charset utf-8
)
if [ "$EFI_BUILT" = "yes" ] && [ -s "$OUT/boot/efi.img" ]; then
  XORRISO_ARGS+=(
    -eltorito-alt-boot -e boot/efi.img -no-emul-boot
    -isohybrid-gpt-basdat
  )
fi
XORRISO_ARGS+=( -o "$ISO" "$OUT" )
xorriso "${XORRISO_ARGS[@]}" 2>&1 | tail -5
command -v isohybrid >/dev/null 2>&1 && isohybrid "$ISO" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# Stage 9: 完成, 打印关键信息
# ══════════════════════════════════════════════════════════════
stage "9/9  完成"
echo
ls -lh "$ISO"
echo "--- file ---"
file "$ISO" | head -1
echo "--- live 目录内容 ---"
ls -lh "$OUT/live"
echo "--- vmlinuz ELF 架构 ---"
file "$OUT/live/vmlinuz" | head -1
echo "--- 最终大小 ---"
du -h "$ISO"

echo
echo "════════ CarmelOS i386 ISO 构建完成 ════════"
echo "ISO 路径: $ISO"
echo "MD5:" ; md5sum "$ISO"
echo "SHA256:"; sha256sum "$ISO"
