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
- **Web Portal 认证(实验性)**:实例的认证方式可选 `802.1X + Dr.COM`(默认)或 `Web Portal / Wireless authentication`。Portal 模式在 Basic 页选择 WAN 后,点击 **发送测试请求 / 探测 Location**,后端会把 `generate_204` 探测绑定到该 WAN 的真实网卡(不跟随重定向),拿到 30x 的 Location 自动填入当前实例(不自动保存,仍需 Save & Apply);204 表示该 WAN 已可直连,200 无 Location 或失败时给出对应提示。新建实例未保存也可探测;接口变更后旧 Location 会标记为待重测。注意:Portal 登录的 C 后端尚未实现,当前版本启动 portal 实例会明确报错退出。
- 旧版单账号配置(全局 `drcom` 节)会在服务启动时自动迁移为实例 `default`,并写入 `option.main.config_version='3'` 防止重复迁移。

## Portal Location 探测回归测试用例

1. **按钮状态**:portal 实例未选 WAN 时按钮禁用;选择 WAN 立即可点;清空 WAN 再次禁用。
2. **未保存可探测**:新建实例只在表单选择 WAN、不点保存,探测必须成功(不依赖 UCI 已保存值)。
3. **多实例隔离**:三个实例各自点探测,只修改各自实例的 Location 输入框。
4. **真实设备**:返回 JSON 中 `device` 必须是 netifd 解析出的真实网卡(如 `wwan -> MT7981_1.network2` 或 `apcli0`),curl 实际绑定该设备。
5. **204 / 302 / 接口 down / 注入**:`204` 提示无重定向且不清空已填 Location;未认证 `302` 自动填入;接口不存在提示"接口未就绪";`interface=wwan;reboot` 必须返回 400,不进入 shell。

## 状态页回归测试用例

每轮改动后至少覆盖以下场景(需 `scutclient` ≥ 3.2.0-3,核心会把认证状态写入 `/var/run/scutclient/<实例>.state`):

1. **WWAN runtime MAC**:`ubus call network.interface.wwan status` 取 `l3_device`,与 `cat /sys/class/net/<device>/address` 比对——状态卡"运行时 MAC"必须显示同一个值(不再显示 `-`)。
2. **MAC 一致性**:配置了 MAC 的实例,实际网卡 MAC 与配置一致时显示 `一致`,不一致(如手动改了 MAC)时必须同时显示运行时 MAC、配置 MAC 和 `不一致`。
3. **实例独立认证状态**:一个实例用正确账号、另一个故意用错误密码,两张卡应分别显示 `在线` 与 `认证失败`,而不是共享一个全局网络状态。
4. **心跳超时**:人为阻断 WWAN 心跳后,该实例显示 `重连中` 且进程仍为 `运行中`(状态不再等同于 PID)。
5. **无线掉线隔离**:`ifdown wwan` 后 WWAN 显示 `等待接口`/`已停止`,WAN 实例状态不变;`ifup wwan` 后 WWAN 自动恢复。

## Portal 表单与探测回归用例

1. **Portal 保存**:portal 实例只填 username/password/interface/Location,UCI 中不存在 `server_auth_ip/dns/version/hash/hostname` 五个 dot1x 字段时,Save & Apply 必须成功且无"必选项值为空"报错(这些字段由 init 的运行时默认值兜底)。
2. **探测按钮状态**:portal 实例 interface 为空时按钮禁用,选择 wwan 后立即变为可点,无需保存。
3. **多实例隔离**:点 WWAN 的探测/随机 MAC 按钮,只读写 WWAN 自己的字段。
4. **dot1x 实例**:切回 802.1X 后 Location 与探测按钮隐藏,保存不受影响。

**Program index 说明**:`/drcom/login` 的 `program_index` 属于门户页面运行时数据,当前版本仅支持在 Web Portal 页手动覆盖(留空则不携带该参数);是否必须携带取决于门户服务端,自动发现将在后续阶段实现。

## MWAN-safe 双 WAN 回归用例(后端 ≥ 3.3.0-3)

1. **mwan3 off**:WAN dot1x 与 WWAN portal 分别单独认证正常。
2. **mwan3 on**:WWAN portal 经 `mwan3 use wwan` 启动,HTTPS 443 稳定;抓包确认 chkstatus/login/logout 全部从 WWAN 真实网卡发出。
3. **route_isolation A/B**:`native` 与 `mwan3` 对比测试,WAN UDP 心跳不再因 mwan3 分流丢失。
4. **DHCP 地址变化**:`IFUPDATE_ADDRESSES=1` 触发 ifupdate,仅重启绑定该 WAN 的实例,新源 IPv4 生效。
5. **多实例隔离**:WAN=dot1x、WWAN=portal 并存,WAN 不受 WWAN portal 流量影响。

## Portal Location 解析回归用例(后端 ≥ 3.3.0)

1. **HTTPS 不降级**:Location 为 `https://...` 时,状态页/日志显示 chkstatus 走 `https://<host>:443`,绝不再出现 `http://<host>:80`。
2. **显式端口保留**:Location 带 `:8443` 时,kernel 接口与 origin 继续使用 8443,不回退 443。
3. **path/query 保留**:Location 的路径与查询串(wlanacname 等)在启动日志的解析概要之外完整保存在实例配置中,不被丢弃。
4. **ePortal 端口可覆盖**:http Location 默认 801、https 默认 802,`portal_http_port`/`portal_https_port` 覆盖后登录请求命中新端口。
5. **网卡绑定**:双 WAN 下 portal 实例绑定 WWAN,抓包确认 chkstatus/login/logout 全部从 WWAN 真实网卡发出。
6. **退出生命周期**:portal 模式 SIGTERM / Log off 只发 portal 注销,不发送 EAPOL Logoff,无 "Bad file descriptor"。
