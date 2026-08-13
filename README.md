# luci-app-cfipopt — CF IP 优选测速 (edgetunnel 节点列表)

在 iStoreOS / OpenWRT 上运行的 Cloudflare IP 优选 + 测速插件。
参照 [cmliu/edgetunnel](https://github.com/cmliu/edgetunnel) 的优选逻辑：

- **生成随机 IP**（`生成随机IP`）：从 Cloudflare CIDR 段随机生成候选 IP，端口从
  `443 2053 2083 2087 2096 8443` 随机选取（可固定端口）
- **优选 API**（`请求优选API`）：拉取在线优选 API 返回的 `IP:端口#备注` 列表
- **测速**：参照 XIU2/CloudflareSpeedTest，对每个候选以
  `https://speed.cloudflare.com/__down?bytes=N` 直连测速，取 HTTP 200 且
  延迟/速度达标的节点，按速度排序输出前 N 个

输出格式为每行 `IP:端口#备注`，可直接复制粘贴到 edgetunnel 实例的
自定义优选 IP / ADD.txt 节点列表中使用。

## 代理自动检测与直连绕过

插件自动检测 OpenClash / DAE 状态：

| 状态 | 行为 |
|---|---|
| OpenClash 运行中 (TUN/redir) | 测速进程以 `nobody`（gid 65534）身份运行，命中 OpenClash mangle 链自带的 `skgid 65534 return` 豁免规则，数据包不被打标记、不进入 utun，直接走 WAN 出口测速 |
| DAE 运行中 | 提示无法自动绕过（eBPF 拦截），建议临时关闭 DAE 或为其配置添加 `speed.cloudflare.com` 的 direct 规则 |
| 无代理 | 直接测速 |

手动指定 `bypass_mode` 可强制/禁止绕过。

## 安装

### 方法一：LuCI 界面安装（系统 → 软件包 → 上传）

1. 上传 `luci-app-cfipopt_1.0.0-1_all.ipk`
2. 安装后 LuCI 菜单出现「服务 → CF IP 优选测速」

### 方法二：命令行

```sh
scp luci-app-cfipopt_1.0.0-1_all.ipk root@<router>:/tmp/
ssh root@<router> 'opkg install /tmp/luci-app-cfipopt_1.0.0-1_all.ipk; /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart'
```

## 使用

1. 打开 LuCI → **服务 → CF IP 优选测速**
2. 配置：候选数量、输出数量、端口、候选来源（优选 API + 随机 / 仅随机 / 仅 API）、
   CIDR 来源（官方 / 自定义）、延迟/速度过滤阈值、测速流量、并发数、绕过方式
3. 点击 **开始测速**，实时进度条 + 日志滚动显示每个节点的延迟/速度
4. 完成后结果区给出 `IP:端口#备注` 列表，可一键 **复制** 或 **下载**

## 后台文件

- `/usr/libexec/cfipopt/run.sh` — 主脚本（`start|stop|run|proxy|status`）
- `/tmp/cfipopt/` — 运行状态（state/log/result.txt/candidates.txt/proxy.json）
- `/etc/config/cfipopt` — UCI 配置

## 构建 ipk (无需 OpenWRT SDK)

```sh
python3 build_ipk.py   # 输出 luci-app-cfipopt_1.0.0-1_all.ipk
```

构建脚本用 python3 tarfile+gzip 直接生成 24.10 格式的 ipk
（`gzip(tar(debian-binary, control.tar.gz, data.tar.gz))`），
可在任意 Linux 主机上运行，无需交叉编译。

## 更新记录

- **2026-08-13** — 修复 LuCI 界面点击「开始测速」无反应的问题（`render()` 中 `this.map` 未赋值导致 JS 报错），并补充启动失败的错误提示
- **2026-08-13** — 首个可用版本: 优选/测速/绕过代理/结果导出全链路

## 备注

- cmliu/CF-CIDR 电信/联通/移动分段上游已失效（404），默认使用 Cloudflare 官方
  `https://www.cloudflare.com/ips-v4`；如手上有运营商分段备份，可粘贴到
  「自定义 CIDR 列表」后选择 `list` 来源
- 测速结果好坏取决于运营商到 Cloudflare 各段的直连质量，多测几轮取并集效果更佳
- 路由器自身 curl 不支持 `--fwmark`，busybox 无 `xargs -P`/`od`，插件已用
  gid 绕过 + `&`/`wait` 并发方案规避
