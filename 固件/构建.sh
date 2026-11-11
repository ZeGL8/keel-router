#!/bin/zsh
# 构建.sh —— 在本机出一个可刷的固件（sysupgrade 包）。
# 步骤：打包前端 → 组装 files/ → 在 ImageBuilder 容器里 make image → 产物放到 固件/输出/<版本>/ 并生成校验和与版本清单。
# 前提：colima 已启动（colima start --vm-type vz --vz-rosetta）。首次运行会构建环境镜像（约 5 分钟）并下载软件包。
# 用法：./构建.sh        （版本号取自 版本.txt）
set -e
H="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$H/.." && pwd)"
VER=$(cat "$H/版本.txt"); OUT="$H/输出/$VER"
docker info >/dev/null 2>&1 || { echo "!! docker 不可用：先运行 colima start --vm-type vz --vz-rosetta"; exit 1; }

echo "==> 1/4 打包前端"; uv run --no-project python "$P/部署工具/打包前端.py" | tail -1
echo "==> 2/4 组装 files/"; uv run --no-project python "$H/组装.py"
echo "==> 3/4 构建环境"; docker image inspect kel-ib:25.12.5 >/dev/null 2>&1 || docker build --platform linux/amd64 -t kel-ib:25.12.5 "$H"
PKGS=$(grep -v '^#' "$H/软件包.txt" | tr '\n' ' ')
echo "==> 4/4 make image（版本 $VER）"
mkdir -p "$OUT"; find "$OUT" -name "*.bin" -delete
# SOURCE_DATE_EPOCH（直接改容器里 include/version.mk 的那一行；在命令行上传 SOURCE_DATE_EPOCH=… 不生效，2026-11-08 试构建验证过）：
# ImageBuilder 把它写死成官方发布日（2026-06-29），并据此把固件里所有文件的修改时间都改成那天——
# 网页文件的 Last-Modified 因此永远是 6 月 29 日，uhttpd 又不发 Cache-Control，浏览器按「距修改时间的 10%」算缓存新鲜期，
# 一次拿到就 13 天不再问路由器要新的（升级后看到旧页面混着新文件）。传入构建时间，缓存新鲜期就随固件的「年龄」缩短。
# dl 目录放在命名卷里：软件包只下载一次；files 以只读方式挂进去
docker run --rm --platform linux/amd64 -v kel-ib-dl:/ib/dl -v "$H/files:/files:ro" -v "$OUT:/out" kel-ib:25.12.5 \
	sh -c "sed -i 's/^SOURCE_DATE_EPOCH:=.*/SOURCE_DATE_EPOCH:=$(date +%s)/' include/version.mk && make image PROFILE=jdcloud_re-cp-02 PACKAGES='$PKGS' FILES=/files EXTRA_IMAGE_NAME=kel-$VER BIN_DIR=/out 2>&1 | tail -40"
BIN=$(find "$OUT" -name "*squashfs-sysupgrade.bin" | head -1)
[ -n "$BIN" ] || { echo "!! 没有产出 sysupgrade 固件，看上面的输出"; exit 1; }
SZ=$(stat -f %z "$BIN"); MAX=16187392
SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
echo "$SHA  $(basename "$BIN")" > "$OUT/sha256sums"
# 版本清单：在线升级时路由器先取它，对比版本号、核对大小和校验和
cat > "$OUT/latest.json" <<J
{ "version": "$VER", "build": "$(date +%Y%m%d-%H%M)", "board": "jdcloud,re-cp-02", "base": "OpenWrt 25.12.5",
  "file": "$(basename "$BIN")", "size": $SZ, "sha256": "$SHA", "notes": "" }
J
echo "✅ $BIN"
echo "   大小 $SZ 字节（固件分区 $MAX；剩给可写区约 $(( (MAX - SZ) / 1024 )) KB）  sha256 $SHA"
