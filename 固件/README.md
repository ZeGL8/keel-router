# 固件：自己打包 + 在线升级

目标设备：MT7621 / 16MB NOR 闪存 / 512MB 内存的这款路由器（OpenWrt 官方设备型号 `jdcloud,re-cp-02`），基础系统 OpenWrt 25.12.5。

## 目录

| 路径 | 是什么 |
|---|---|
| `构建.sh` | 一条命令出固件：打包前端 → 组装 `files/` → ImageBuilder `make image` → `输出/<版本>/` |
| `组装.py` | 把本地源码（`前端静态包/`、`后端插件/`）摆成固件里的目录结构 `files/` |
| `软件包.txt` | 固件预装的软件包清单 |
| `首次启动.sh` | 进固件后是 `/etc/uci-defaults/99-kel`：刷入后第一次开机执行一次，补齐基础设置 |
| `保留清单.txt` | 进固件后是 `/lib/upgrade/keep.d/kel`：升级时随配置保留的**数据**文件 |
| `版本.txt` | 固件版本号（进固件后在 `/etc/kel_version`） |
| `Dockerfile` | ImageBuilder 的运行环境（官方只有 Linux x86_64 版） |
| `下载/` | 官方原料，均已按官方 sha256sums 校验：ImageBuilder、官方原版 sysupgrade 固件、initramfs 救援镜像 |
| `输出/<版本>/` | 产物：`*-squashfs-sysupgrade.bin`、`sha256sums`、`latest.json`（在线升级用的版本清单）。产物不进 git（`.gitignore`）；本地留当前版本和上一版（回退用）即可 |
| `救援备份-<日期>/` | **第一次刷机前一定要做一份整片闪存备份**：U-Boot、Config、**Factory（无线校准和 MAC，丢了无法恢复）**、系统分区、配置备份（**含密钥，勿外传**，不进 git） |
| 之后每次升级前 | 再做一份系统分区镜像 + 配置备份 + 软件包清单（`远程升级.sh` 会自动做） |

## 环境（一次性）

这台 Mac 是 Apple 芯片，ImageBuilder 只有 Linux x86_64 版，所以经 colima（轻量 Linux 虚拟机）+ Rosetta 运行：

```bash
brew install colima docker
colima start --vm-type vz --vz-rosetta --cpu 4 --memory 4 --disk 20
```

之后每次构建：`./构建.sh`（改版本号就改 `版本.txt`）。关机重启后要先 `colima start`。

## 固件里有什么、没有什么

- **有**：全部后端（kelapi、守护脚本、看门狗、设备策略）、全部网页、定时任务、默认配置。它们在只读区（squashfs，高压缩），不再占可写区。
- **没有**：mihomo / AdGuardHome 的二进制。它们太大（60MB / 38MB），仍然是开机后下载到内存运行。
- **去掉的包**：`owut` / `luci-app-attendedsysupgrade`（官方在线升级会把系统刷成不含本界面的官方固件）、`kmod-mmc-mtk`（TF 卡驱动，本机用不上还刷屏报错，原来靠 `kel-nosd` 开机卸载，现在直接不装）。

## 升级时「保留什么」——最容易出事的地方

OpenWrt 的 `sysupgrade` 默认保留配置：刷入前把一批文件打成备份，刷完第一次开机时解回去。

- 现在路由器上的 `/etc/sysupgrade.conf` 把**代码**（`/www`、脚本、插件）也列进去了，因为以前代码不在固件里，不列就会丢。
- 换成自打包固件后，代码在固件里。如果仍然把旧代码备份带过去，**旧网页/旧脚本会盖住新固件里的文件**，而且新固件的可写区只有 2–3MB，光是恢复就可能写不下。
- 所以：
  1. 新固件里，数据文件由 `/lib/upgrade/keep.d/kel` 声明（`/etc/kelclash`、`/etc/keladg`、`/etc/kel_*` 等）；`/etc/config/*`、SSH 公钥、定时任务由系统默认保留。
  2. 新固件第一次开机，`99-kel` 会把 `/etc/sysupgrade.conf` 里的代码路径清掉。
  3. **第一次从现在的系统迁移过去时，必须在刷之前先把路由器上的 `/etc/sysupgrade.conf` 换成不含代码的版本**，否则第 2 条来不及生效。迁移步骤里已包含这一步。

## 救砖手段（已核实的部分和未核实的部分）

- 分区：`U-Boot`(256K) / `Config`(64K) / `Factory`(256K，无线校准和 MAC，**丢了无法恢复，已备份**) / `firmware`(15.4MB)。
- `sysupgrade` 只写 `firmware` 分区，不碰 U-Boot 和 Factory。所以刷坏的是系统，引导程序还在。
- 引导程序：U-Boot 2018.09（2024-12-07 构建）。解包后确认里面带**网页恢复模式**和 **TFTP 恢复模式**，文字是“Enter web failsafe mode by pressing reset button”，内置上传固件的页面，编译进去的默认地址是 `192.168.1.1`（电脑设 `192.168.1.2`）。
- **未核实**：我没法按物理按键，所以没有实际进过这个恢复模式。按住 reset 多久、指示灯怎么闪、恢复页面地址是不是 `192.168.1.1`，都需要在刷机前由人实际试一次（进恢复模式本身不会改动任何东西，不上传就没事）。
- 最后的手段：`救援备份-*/mtd3-firmware.bin` 是当前系统的完整镜像，配合编程器或串口可以原样写回。

## 升级怎么做：一条命令，无人值守

```bash
./远程升级.sh 192.168.68.1 --演练    # 路由器自己下载并校验固件，不刷写
./远程升级.sh 192.168.68.1           # 真的升级
```

第一次从「官方固件 + 事后安装」迁移，和以后每次升级，用的是同一个脚本、同一条路。

- **路由器端** `/usr/sbin/kel-upgrade`（源码 `后端插件/kel-upgrade`）自己做完全部事情：取版本清单 → 比版本、核对机型 → 下载到内存 → 核对大小和 sha256 → `sysupgrade -T` → 把升级保留清单里的代码路径去掉 → 停代理和广告过滤、释放内存 → `sysupgrade` 保留配置刷入 → 重启。任何一步不对就停在刷写之前，系统原样继续运行。
- **电脑端** `远程升级.sh` 负责：刷之前备份（配置 + 系统分区）、把升级程序放上去、在本机开临时下载地址、发指令；刷的时候只是等（路由器断网 3–5 分钟，电脑不需要外网）；刷完后自己把路由器找回来（原地址 → 当前网关 → 192.168.1.1，最多等 15 分钟），逐项验收（版本、确实重启过、首次启动脚本已执行、程序在只读区、外网、DNS、界面、后端、无线、个人设置还在），结论写在 `升级记录/<时间>.log` 的最后一行 `RESULT=...`。
- 升级历史在路由器的 `/etc/kel_upgrade.log`：刷之前记一行 `start`，新系统第一次启动成功记一行 `booted`。

找不回来时脚本会说明下一步：能 ping 通网关但登不上，多半是配置没恢复；完全找不到，才需要去路由器旁边用恢复模式。

## 在线升级：已实现的和还差的

已实现：路由器端升级程序、后端接口（`web_upgrade_check / start / status`）、电脑端无人值守脚本。`sysupgrade -T` 校验实测可用：官方固件通过，截断的、随机内容的文件都被拒绝。流程：

1. **发布**：把 `输出/<版本>/` 下的固件和 `latest.json` 放到一个固定的下载地址。
2. **检查**：路由器取 `latest.json`，和 `/etc/kel_version` 比版本号，核对 `board` 是本机型号。
3. **下载**：下到 `/tmp`（内存），核对大小和 sha256，再跑 `sysupgrade -T`。
4. **升级**：停代理和广告过滤 → `sysupgrade`（保留配置）→ 重启。界面显示原厂样式的等待框，轮询到路由器回来、版本号变了才提示成功。
5. **保护**：版本不比当前新不升；型号不对不升；校验不过不升；内存不够不升；全程不动 U-Boot 和 Factory。

还差的：界面上的「检查更新」入口（接口已有）；固件放在哪（现在是电脑临时开的局域网地址；放到公网后把地址写进 uci `kel.settings.upgrade_url` 即可）；是否对 `latest.json` 做签名（防止下载地址被人替换成恶意固件，OpenWrt 自带 `usign` 可以做）。

## 从外网的电脑升级（2026-10-13 升到 1.0.2 时实际走通的步骤）

电脑和路由器不在同一个局域网时，`远程升级.sh` 用不了（它要在局域网里开下载地址、按局域网地址找回路由器）。这时按下面做，全程走 SSH 密钥和公网 IPv6；本机开着代理 TUN 时 ssh 都要加 `-6 -B en1`。

1. **构建**：`colima start --vm-type vz --vz-rosetta --cpu 4 --memory 4 --disk 20`，然后 `./构建.sh`。首次要建环境镜像，约 6 分钟。用完 `colima stop`。
2. **核对**：软件包清单与上一版一致（`diff` 两个 `.manifest`）；`files/` 里每个文件与路由器上的逐一比对，只应有 `etc/config/kel*`、`etc/kel_version`、`etc/uci-defaults/99-kel` 不同。
3. **备份到电脑**：`sysupgrade -b -` 和 `cat /dev/mtd3ro`，存进 `救援备份-<时间>/`。
4. **布置回连**：重启后外网 IPv6 多半会变，电脑会找不到路由器。刷之前在路由器的 `/etc/crontabs/root` 里加一行带标记 `# kel-callback-tmp` 的任务，每分钟把 `pppoe-wan` 的外网 IPv6、`/etc/kel_version` 的版本、开机秒数用 curl 发到电脑的公网 IPv6 某个端口；电脑上用 `nc -6 -l <端口>` 循环接收。定时任务文件随升级保留，新系统起来一分钟内就会报到。**先手工跑一次这条任务确认电脑能收到，再刷。**
5. **上传并演练**：固件 `cat` 到路由器 `/tmp/firmware.bin`，核对 sha256；`kel-upgrade inspect /tmp/firmware.bin`；`kel-upgrade start --file /tmp/firmware.bin --ver <版本> --dry`，状态到 `dry-ok` 才继续。
6. **刷入**：`kel-upgrade start --file /tmp/firmware.bin --ver <版本>`。ssh 会断，属正常。
7. **等回连、验收**：电脑收到 `ver=<新版本>` 且开机秒数很小的上报后，用上报里的新地址登录，按 `远程升级.sh` 第 4 段的清单逐项查。这次从发起到收到上报是 3 分半。
8. **收尾**：删掉那行临时任务（`sed -i "/kel-callback-tmp/d"`）并重启 cron，删 `/tmp/firmware.bin`，停掉电脑上的接收端。

注意：busybox 的 `nc` 没有 `-w`，路由器上也没有 `timeout`；要探测端口或发数据用 `curl -m`。
