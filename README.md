# luci-app-scutclient

多实例 SCUT Dr.com/802.1X 认证客户端的 LuCI 管理界面。

一个认证实例 = 一个账号 + 一个 WAN(逻辑接口)+ 一个独立进程 + 一个独立日志文件。
一个 WAN 只能被一个实例绑定;每个实例拥有独立的 Dr.COM 参数、MAC 模式、高级参数与日志。

## GitHub Actions 编译

本地无需搭建 OpenWrt buildroot / SDK / 交叉工具链,编译统一走 GitHub Actions。

仓库已提供 `.github/workflows/build.yml`。进入 GitHub 仓库的 **Actions → Build OpenWrt IPK → Run workflow** 即可手动构建;push 到 master 也会自动触发。

默认使用 OpenWrt `22.03.7` SDK,并同时生成:

- `scutclient_*.ipk`
- `luci-app-scutclient_*.ipk`

支持架构:`x86_64`、`aarch64_generic`、`aarch64_cortex-a53`、`arm_cortex-a7_neon-vfpv4`、`mipsel_24kc`。
构建完成后,在对应 Workflow Run 页面的 **Artifacts** 下载与路由器架构匹配的压缩包。

常用架构可以通过路由器执行以下命令确认:

```sh
opkg print-architecture
uname -m
```

注意:本 workflow 编译后端包时克隆的是 `Sari-me/scutclient` 的 master 分支,后端改动需要先合入该仓库。

## 安装示例

```sh
opkg install /tmp/scutclient_*.ipk
opkg install /tmp/luci-app-scutclient_*.ipk
```

## 使用说明

- **Status**:每个实例一张状态卡(运行状态、账号、WAN、设备、IP、MAC、服务器、PID),支持单实例启动/重启/下线/停止,以及全局互联网连通性探测。
- **Settings**:实例增删改。配置节名称即实例 ID;接口下拉框会标注已被其他实例占用的 WAN 并拒绝重复绑定。每个实例分四个标签页:Basic(账号/接口/MAC)、Dr.COM、Advanced(心跳/EAP 参数与钩子)、Logging。
- **Logs**:按实例查看 `/tmp/scutclient/<实例>.log`,支持等级过滤、行数选择、自动刷新、清空与下载。
- MAC 模式(keep/random/custom)由后端 `/usr/lib/scutclient/scutclient-mac` 持久化并应用到有线设备或无线 STA 接口,认证进程通过 `--expected-mac` 校验是否生效。
- 旧版单账号配置(全局 `drcom` 节)会在服务启动时自动迁移为实例 `default`,并写入 `option.main.config_version='2'` 防止重复迁移。

## 状态页回归测试用例

每轮改动后至少覆盖以下场景(需 `scutclient` ≥ 3.2.0-3,核心会把认证状态写入 `/var/run/scutclient/<实例>.state`):

1. **WWAN runtime MAC**:`ubus call network.interface.wwan status` 取 `l3_device`,与 `cat /sys/class/net/<device>/address` 比对——状态卡"运行时 MAC"必须显示同一个值(不再显示 `-`)。
2. **MAC 一致性**:配置了 MAC 的实例,实际网卡 MAC 与配置一致时显示 `一致`,不一致(如手动改了 MAC)时必须同时显示运行时 MAC、配置 MAC 和 `不一致`。
3. **实例独立认证状态**:一个实例用正确账号、另一个故意用错误密码,两张卡应分别显示 `在线` 与 `认证失败`,而不是共享一个全局网络状态。
4. **心跳超时**:人为阻断 WWAN 心跳后,该实例显示 `重连中` 且进程仍为 `运行中`(状态不再等同于 PID)。
5. **无线掉线隔离**:`ifdown wwan` 后 WWAN 显示 `等待接口`/`已停止`,WAN 实例状态不变;`ifup wwan` 后 WWAN 自动恢复。
