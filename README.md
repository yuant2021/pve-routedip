# pve-routedip

Proxmox VE 9 的 Routed IP 插件：把任意长度的 IPv4 / IPv6 地址或网段路由到虚拟机网卡，
路由跟随虚拟机所在节点（含在线迁移），配置修改即时生效，路由由 BIRD 等路由守护进程收集。

## 功能

- **任意长度 CIDR**：IPv4 `/0`–`/32`、IPv6 `/0`–`/128`；单个地址视为主机路由（`/32`、`/128`）。
  主机位会被清零（`203.0.113.7/29` 存为 `203.0.113.0/29`）。全集群内不同网卡的网段不得重叠。
- **tap-only 开关**（按网卡）：开启后不再把 `tapXiY` 插入 vmbr（包括虚拟机启动、网卡热插拔、
  在线修改网卡、SDN vnet），tap 成为宿主与虚拟机之间的点对点三层链路，路由与网关地址直接配在 tap 上。
  关闭时 tap 照常进入网桥，路由指向网桥（带 VLAN tag 时指向 `vmbrXvT` 或 `vmbrX.T`）。
- **宿主“假网关”可修改**：集群默认 IPv4 `169.254.0.1`、IPv6 `fe80::1`，可在数据中心页面修改，
  也可按网卡覆盖。IPv6 网关为 link-local 时配置为 `/64`，否则 `/128`；IPv4 一律 `/32`。
  只有存在对应地址族路由时才会配置该族网关。
- **tap MAC**：tap-only 的 tap 在所有节点上使用同一个 MAC（默认 `fe:ff:ff:ff:ff:ff`，可修改），
  虚拟机迁移后网关的邻居缓存仍然有效，不会断流。
- **即时更新**：Web 界面/API/CLI 修改后立即应用到运行中的虚拟机（包括 tap-only 的开启与关闭，
  关闭时 tap 会被重新插回其配置的网桥）；其它节点上的改动由 `pve-routedipd` 在 1 秒内同步。
- **迁移**：在线迁移时源节点在目标恢复运行前撤掉路由，目标节点在虚拟机恢复运行前装上路由。
  迁移过程中目标节点的 tap 已按 tap-only 配好但不带路由。
- **独立的 Web 配置页**：
  - 数据中心 → Routed IP：网关/MAC 选项，集群内全部路由网卡的列表，可新增/编辑/删除。
  - 虚拟机 → Routed IP：该虚拟机各网卡的路由配置及实时状态（是否生效、路由设备、错误信息）。
- **可安装、可卸载**：标准 deb 包。卸载时把 tap-only 的 tap 插回网桥、删除插件添加的全部路由和地址，
  并恢复被替换的 PVE 文件。

不处理 proxy ARP / proxy NDP，也不生成 BIRD 配置。

## 安装

所有节点都需要安装（集群内的配置是共享的，路由在虚拟机所在节点生效）：

```sh
make deb                      # 需要 debhelper、libpve-common-perl
apt install ./pve-routedip_1.0.0_all.deb
```

安装后 pvedaemon、pveproxy 等由 PVE 自身的 `pve-api-updates` 触发器自动重载，刷新浏览器即可看到新页面。

宿主需自行开启转发：

```sh
sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
```

卸载：`apt remove pve-routedip`。`/etc/pve/routedip/` 中的配置是集群共享的，卸载与 purge 都不会删除它。

## 使用

1. 虚拟机网卡照常在 PVE 中配置一个已存在的网桥（tap-only 模式下网桥只用于确定 MTU，tap 不会接入）。
   tap-only 网卡若设置了 `mtu=`，tap 的 MTU 取该值。
2. 在 数据中心 → Routed IP 或 虚拟机 → Routed IP 中为网卡填写路由的地址/网段，按需开启 tap-only。
3. 在虚拟机内配置地址和指向假网关的默认路由，例如（Linux）：

   ```sh
   ip addr add 203.0.113.10/32 dev eth0
   ip route add 169.254.0.1 dev eth0
   ip route add default via 169.254.0.1 dev eth0
   ip -6 addr add 2001:db8:10::1/64 dev eth0
   ip -6 route add default via fe80::1 dev eth0
   ```

   宿主不发送 RA，虚拟机内需静态配置。

命令行：

```sh
pve-routedip set 100 net0 --cidr '203.0.113.10;2001:db8:10::/64' --tap-only 1
pve-routedip show 100            # 本节点上的状态
pve-routedip list                # 集群内全部路由网卡
pve-routedip options set --gateway4 100.64.0.1
pve-routedip status              # 本节点上已安装的路由/地址/tap-only 设备
pve-routedip delete 100 net0
```

API：`/cluster/routedip/options`、`/cluster/routedip/vms`、
`/nodes/{node}/qemu/{vmid}/routedip[/{netX}]`。写操作需要虚拟机上的 `VM.Config.Network`
以及 `/` 上的 `Sys.Modify`（路由属于宿主资源）。

## BIRD

插件添加的路由和地址都带协议号 `150`（`/etc/iproute2/rt_protos.d/pve-routedip.conf` 中命名为
`routedip`），位于 main 表。BIRD 的 kernel 协议开启 `learn` 后可用 `krt_source = 150` 过滤。

## 配置文件

```
/etc/pve/routedip/cluster.cfg     gateway4 / gateway6 / gateway-mac
/etc/pve/routedip/<vmid>.cfg      net0: cidr=203.0.113.10/32;2001:db8:10::/64,tap-only=1
```

虚拟机删除 60 秒后其配置由 `pve-routedipd` 自动清理。

## 实现说明

- 安装时用 `dpkg-divert` 替换 `PVE/Network.pm`（libpve-common-perl）与 `PVE/API2.pm`（pve-manager），
  替换后的模块先原样加载原文件，再分别挂上网卡钩子和注册 API；PVE 升级时新原文件会落到被转移的位置，
  不受影响。Web 界面通过在 `index.html.tpl` 中插入一个 script 标签加载，pve-manager 升级后由 dpkg
  触发器重新插入。
- 钩子：`tap_plug`（tap-only 时不入网桥）、`tap_unplug`（删路由）、`add_bridge_fdb`（虚拟机启动或
  恢复运行前装路由，迁移目标即在此时接管）、`del_bridge_fdb`（迁移源在目标恢复前删路由）。
- 内核本身就是状态库：凡带协议号 150 的路由/地址都归插件管理，不再需要的即删除。
  某个 tap 存在、且虚拟机配置在本节点时才装路由；tap 存在但配置在别的节点（迁移中）时不做任何改动。
- `pve-routedipd` 每秒比对一次配置与内核状态，处理其它节点上的配置修改、迁移收尾、手工改动导致的偏差，
  并清理已删除虚拟机的配置。

## 限制

- 仅支持 QEMU 虚拟机（LXC 容器使用 veth，不在范围内）。
- tap-only 网卡绕过网桥，PVE 防火墙的虚拟机规则（基于网桥）对其不生效。
- 非 tap-only 模式下，网关地址配置在共享网桥上；迁移后虚拟机侧的网关邻居缓存取决于各节点网桥 MAC 是否一致。
- 运行中切换 tap-only 会改变网关所在的二层设备（MAC 也随之变化），虚拟机的邻居缓存过期前
  （实测 IPv4 约 15 秒）该网卡会短暂不通；增删路由网段与在线迁移不会中断。
  修改网关地址后，虚拟机内的网关配置需要同步修改。
- 跨集群的远程迁移（`qm remote-migrate`）不会带走路由配置。
- 所有节点都要安装：未安装的节点上虚拟机启动时 tap 会照常进入网桥，也不会有路由。

## 开发

```sh
make check    # 单元测试，需要 libpve-common-perl
make deb
```
