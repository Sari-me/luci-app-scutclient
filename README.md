# luci-app-scutclient

## GitHub Actions 编译

仓库已经提供 `.github/workflows/build.yml`。

进入 GitHub 仓库的 **Actions → Build OpenWrt IPK → Run workflow** 即可手动构建。

默认使用 OpenWrt `22.03.7` SDK，并同时生成：

- `scutclient_*.ipk`
- `luci-app-scutclient_*.ipk`

构建完成后，在对应 Workflow Run 页面的 **Artifacts** 下载与路由器架构匹配的压缩包。

常用架构可以通过路由器执行以下命令确认：

```sh
opkg print-architecture
uname -m

安装示例：

opkg install /tmp/scutclient_*.ipk
opkg install /tmp/luci-app-scutclient_*.ipk

---
