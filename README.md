# TCP / UDP 通用端口转发管理器

一个基于 Linux `iptables` 的 TCP / UDP 通用端口转发管理脚本。

支持将服务器 A 的指定 TCP / UDP 端口转发到服务器 B，并支持使用域名作为目标地址。当目标域名解析到的 IPv4 地址发生变化时，可以通过 Cron 自动检测并重新建立转发规则。

适用于简单的端口转发、IPv4 NAT 转发、游戏端口转发、服务端口转发等场景。

---

## ✨ 功能特性

- ✅ 支持 TCP
- ✅ 支持 UDP
- ✅ 支持 TCP + UDP
- ✅ 支持 IPv4 地址作为目标
- ✅ 支持域名作为目标
- ✅ 域名自动解析 IPv4
- ✅ 支持多条转发规则
- ✅ 每条规则拥有独立 ID
- ✅ 交互式管理菜单
- ✅ 添加转发规则
- ✅ 修改转发规则
- ✅ 删除转发规则
- ✅ 立即更新全部规则
- ✅ 自动检测域名 IP
- ✅ Cron 自动定时检查
- ✅ 自动安装系统依赖
- ✅ 自动开启 IPv4 Forward
- ✅ IPv4 Forward 配置持久化
- ✅ 自动创建 iptables DNAT 规则
- ✅ 自动创建 MASQUERADE 规则
- ✅ 自动创建 FORWARD 放行规则
- ✅ 只清理本程序创建的 iptables 规则
- ✅ 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Fedora
- ✅ 支持 apt / dnf / yum
- ✅ 提供运行日志
- ✅ 支持一键卸载

---

## 📦 系统要求

支持常见 Linux 发行版：

- Debian
- Ubuntu
- Linux Mint
- CentOS
- RHEL
- Rocky Linux
- AlmaLinux
- Fedora

需要：

- root 权限
- IPv4 网络环境

脚本会自动检测并安装：

| 依赖 | 用途 |
|---|---|
| `iptables` | 创建 NAT / FORWARD 转发规则 |
| `dig` | 解析目标域名 IPv4 |
| `cron` / `cronie` | 自动定时检测 |
| `sysctl` | 开启 IPv4 Forward |

无需手动提前安装。

---

## 🚀 安装

下载脚本：

```bash
wget -O tcp-udp-forward.sh https://raw.githubusercontent.com/SumMoonYou/tcp-udp-forward/main/tcp-udp-forward.sh
