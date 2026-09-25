
# init-server

> Linux 服务器一键初始化脚本：SSH 端口修改、系统源修复、Docker 安装、Compose 批量部署。

[![Platform](https://img.shields.io/badge/platform-CentOS%207%2B%20%7C%20RHEL%207%2B%20%7C%20Rocky%20%7C%20Alma%20%7C%20Ubuntu%2020.04%2B%20%7C%20Debian%2011%2B-blue)]()
[![Shell](https://img.shields.io/badge/shell-bash%204.0%2B-4EAA25)]()
[![License](https://img.shields.io/badge/License-GPLv3-green)]()
[![Version](https://img.shields.io/badge/version-1.0.0-orange)]()

---

## 目录

- [简介](#简介)
- [核心特性](#核心特性)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [安装部署](#安装部署)
- [运行模式详解](#运行模式详解)
- [配置文件完整参考](#配置文件完整参考)
- [功能模块详解](#功能模块详解)
  - [SSH 端口修改](#一ssh-端口修改)
  - [系统包源修复](#二系统包源修复)
  - [Docker 安装](#三docker-安装)
  - [daemon.json 配置](#四daemonjson-配置)
  - [Compose 批量部署](#五compose-批量部署)
  - [防火墙自动适配](#六防火墙自动适配)
- [日志系统](#日志系统)
- [使用场景示例](#使用场景示例)
- [常见问题 FAQ](#常见问题-faq)
- [最佳实践](#最佳实践)
- [故障排查](#故障排查)
- [项目结构](#项目结构)
- [贡献指南](#贡献指南)
- [许可证](#许可证)

---

## 简介

`init-server` 是一个用于 Linux 服务器初始化的 Bash 脚本，将部署一台新机器时最常用的几个操作整合到一个脚本中，并提供**幂等、可回滚、可审计**的保障。

### 解决的问题

在给一台新的 Linux 服务器做初始配置时，通常会面临以下重复劳动：

1. **修改 SSH 端口**（安全加固）——手工改容易出错，改完可能因为防火墙没放行而失联
2. **修复系统包源**——国内网络环境下默认源经常不可用，需要手工替换为镜像源
3. **安装 Docker**——官方脚本、镜像加速、日志限制、`daemon.json` 配置，每一步都需要查文档
4. **部署 Docker Compose 项目**——多个项目分散在不同 YAML 文件里，需要一个一个手 `cd` 进去执行

`init-server` 把这些操作全部封装起来，并提供统一的日志、错误处理和配置能力。

### 设计理念

- **幂等**：重复运行不产生副作用，已配置好的不会重复操作
- **安全**：SSH 端口修改失败自动回退，避免服务器失联
- **透明**：每一步操作都写入日志，出错时可以精确溯源
- **灵活**：支持交互、半自动、全自动三种模式，覆盖从手工单机到 CI/CD 的所有场景
- **无侵入**：通过复制而非移动文件，源目录保持整洁

---

## 核心特性

| 特性 | 说明 |
|------|------|
| 三种运行模式 | 完全交互 / 半自动 / 全自动，按需选择 |
| 幂等执行 | 重复运行不会重复操作，Docker 服务不会无谓重启 |
| 失败自动回退 | SSH 端口修改任一环节失败自动回滚，避免失联 |
| 防火墙自动适配 | 支持 firewalld / ufw / nftables / iptables |
| 云平台提示 | 检测到阿里云/AWS/腾讯云时提示同步放行安全组 |
| 详细日志系统 | 命令级记录、文件快照、步骤计时、错误汇总 |
| 配置文件驱动 | 支持 `--config` 使用配置文件，适合批量运维 |
| 多发行版兼容 | CentOS / RHEL / Rocky / Alma / Ubuntu / Debian |
| Compose 批量部署 | 自动识别命名规则，配对 env 文件，一键部署多个项目 |
| 镜像加速配置 | 内置多个可用加速地址，支持自定义 |

---

## 系统要求

### 支持的发行版

| 发行版 | 版本 | 状态 |
|--------|------|------|
| CentOS | 7 / 8 Stream | ✅ 完全支持 |
| RHEL | 7 / 8 / 9 | ✅ 完全支持 |
| Rocky Linux | 8 / 9 | ✅ 完全支持 |
| AlmaLinux | 8 / 9 | ✅ 完全支持 |
| Fedora | 35+ | ✅ 完全支持 |
| Ubuntu | 20.04 / 22.04 / 24.04 | ✅ 完全支持 |
| Debian | 11 / 12 | ✅ 完全支持 |
| Alpine | 3.15+ | ⚠️ 需手动预装 bash |
| 其他 | - | ⚠️ 未测试，可能可用 |

### 环境要求

- **Bash 版本**：4.0 或以上（使用了关联数组）
- **权限**：必须使用 `root` 运行（或用 `sudo`）
- **网络**：能访问外网（除非使用离线模式）
- **磁盘**：至少 5GB 可用空间（Docker 安装和镜像存储）

### 依赖命令

脚本会用到以下命令，其中大部分在标准系统上已经存在：

| 命令 | 用途 | 缺失时 |
|------|------|--------|
| `curl` / `wget` | 下载文件 | 需手动安装 |
| `ss` | 检查端口监听 | 需手动安装 |
| `jq` 或 `python3` | JSON 校验 | 可选，缺失时跳过校验 |
| `firewall-cmd` / `ufw` / `nft` / `iptables` | 防火墙操作 | 自动降级 |

---

## 快速开始

### 一键运行（无配置）

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/init-server/main/init_server.sh -o init_server.sh
chmod +x init_server.sh
sudo bash init_server.sh


这是**完全交互模式**，脚本会引导你完成所有步骤。

### 使用配置文件

```bash
# 生成配置模板
bash init_server.sh --dump-config > /etc/my-init.conf

# 收紧权限（脚本会拒绝加载过宽的权限）
chmod 600 /etc/my-init.conf

# 编辑配置
vi /etc/my-init.conf

# 半自动执行（异常时询问）
sudo bash init_server.sh --config /etc/my-init.conf

# 全自动执行（不询问）
sudo bash init_server.sh --config /etc/my-init.conf --yes
```

---

## 安装部署

### 方式一：直接下载

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/init-server/main/init_server.sh -o /usr/local/bin/init-server
chmod +x /usr/local/bin/init-server
```

之后可以全局调用：

```bash
sudo init-server
sudo init-server --config /etc/my-init.conf
```

### 方式二：克隆仓库

```bash
git clone https://github.com/<your-username>/init-server.git
cd init-server
chmod +x init_server.sh
sudo bash init_server.sh
```

### 方式三：内网批量分发

```bash
# 从一台机器分发到多台
for host in node1 node2 node3; do
    scp init_server.sh my-init.conf "root@$host:/tmp/"
    ssh "root@$host" "sudo bash /tmp/init_server.sh --config /tmp/my-init.conf --yes"
done
```

---

## 运行模式详解

脚本提供三种运行模式，区别在于**何时询问用户**。

### 完全交互模式

```bash
sudo bash init_server.sh
```

**行为**：每一步都询问。包括是否修改 SSH 端口、如何处理包源、如何配置 daemon.json、是否部署 Compose 等。

**适用场景**：

- 首次接触脚本，想了解每一步在做什么
- 手工调试，需要逐步确认

### 半自动模式

```bash
sudo bash init_server.sh --config /etc/my-init.conf
```

**行为**：正常流程按配置直接执行，仅在遇到异常时才询问。例如：

- SSH 端口修改后未监听 → 询问是否回退
- 防火墙放行失败 → 询问是否回退 SSH 配置
- 系统包源不可用 → 询问是否切换到默认源
- Docker 安装失败 → 询问是否重试或切官方源
- YAML 语法校验失败 → 询问是否继续处理其他项目

**适用场景**：

- 批量运维时希望有人工监督
- 首次部署新机器，需要观察每一步是否正常
- 半自动比全自动更安全，遇到问题会停下来

### 全自动模式

```bash
sudo bash init_server.sh --config /etc/my-init.conf --yes
```

**行为**：异常也不询问，自动按以下策略处理：

| 异常 | 处理 |
|------|------|
| SSH 端口不监听 | 自动回退 SSH 配置 |
| 防火墙放行失败 | 自动回退 SSH 配置 |
| 包源不可用 | 自动切内置默认源 |
| Docker 安装失败 | 记录并跳过 Compose 部署 |
| YAML 语法错误 | 自动跳过该项目，继续下一个 |
| 容器启动失败 | 记录并继续下一个 |

所有错误和警告在脚本结尾统一汇总。

**适用场景**：

- CI/CD 自动化部署
- 无人值守批量刷机
- 标准化部署流程

### 异常处理对照表

| 异常场景 | 完全交互 | 半自动 | 全自动 |
|---------|---------|--------|--------|
| SSH 端口写入后未监听 | 询问回退 | 询问回退 | 自动回退 |
| 防火墙放行失败 | 询问回退 | 询问回退 | 自动回退 |
| SELinux 策略失败 | 记录警告继续 | 记录警告继续 | 记录警告继续 |
| 系统包源不可用 | 逐项询问 | 询问切默认源 | 自动切默认源 |
| 系统包源仍不可用 | 询问继续 | 询问继续 | 记录并继续 |
| Docker 安装失败 | 询问重试 | 询问重试 | 自动尝试官方源 |
| Docker 源不可达 | 询问切换 | 询问切换 | 记录并尝试官方源 |
| daemon.json 冲突 | 询问处理 | 按 MODE 处理 | 按 MODE 处理 |
| YAML 语法错误 | 询问继续 | 询问继续 | 自动跳过继续 |
| 容器启动失败 | 记录继续 | 记录继续 | 记录继续 |
| 项目目录不存在 | 询问新目录 | 报错退出 | 报错退出 |
| 结束时 | 无汇总 | 输出汇总 | 输出汇总 |

### 退出码约定

| 退出码 | 含义 |
|--------|------|
| 0 | 所有步骤成功，无错误、无警告 |
| 1 | 存在错误（可从日志"错误汇总"查看具体原因） |

可以据此判断执行结果：

```bash
if sudo bash init_server.sh --config /etc/my-init.conf --yes; then
    echo "部署成功"
else
    echo "部署有错误，请查看日志"
    exit 1
fi
```

---

## 配置文件完整参考

配置文件是 Bash 语法，通过 `source` 加载。所有变量均为可选，未定义时使用脚本内置默认值。

### 生成模板

```bash
bash init_server.sh --dump-config > /etc/my-init.conf
chmod 600 /etc/my-init.conf
```

### SSH 端口

```bash
# SSH_CHANGE: 是否执行 SSH 端口修改
#   true  = 执行
#   false = 跳过（默认）
SSH_CHANGE=false

# SSH_PORT: 新端口号，范围 1024-65535
#   仅当 SSH_CHANGE=true 时生效
#   示例: 2222 / 22022 / 54321
SSH_PORT=

# SSH_CLOSE_OLD_PORT: 修改成功后是否关闭旧端口 22
#   true  = 自动关闭（默认）
#   false = 保留
#
# 建议:
#   首次操作时设为 false，另开终端测试新端口连接后再手动关闭 22
#   确定环境稳定后设为 true，实现全自动切换
SSH_CLOSE_OLD_PORT=true
```

### 系统包源

```bash
# PACKAGE_SOURCE_MODE: 包源处理策略
#   auto    = 先测试现有源，可用则用；不可用时按模式处理
#             半自动: 询问是否切默认源
#             全自动: 自动切内置阿里云默认源
#             （推荐）
#   default = 直接应用内置默认源（阿里云镜像）
#   custom  = 使用自定义源，需填 URL 或 FILE
#   skip    = 完全跳过包源检查（离线环境用）
PACKAGE_SOURCE_MODE=auto

# PACKAGE_SOURCE_URL: 镜像站 URL 前缀，用于 custom 模式
#   示例:
#     https://mirrors.tuna.tsinghua.edu.cn
#     https://mirrors.ustc.edu.cn
#     https://mirrors.aliyun.com
#     https://mirrors.huaweicloud.com
#   注意: 不要带尾部斜杠
PACKAGE_SOURCE_URL=

# PACKAGE_SOURCE_FILE: 本地源文件绝对路径，用于 custom 模式
#   与 PACKAGE_SOURCE_URL 二选一（同时填写时优先用 FILE）
#   支持的文件类型:
#     apt 系统:  .list  或  .sources
#     yum 系统:  .repo
#   示例:
#     /root/sources.list
#     /root/tuna.repo
PACKAGE_SOURCE_FILE=
```

### Docker 安装

```bash
# DOCKER_INSTALL: 是否安装 Docker
#   true  = 安装（默认）
#   false = 完全跳过
DOCKER_INSTALL=true

# DOCKER_MIRRORS: Docker Hub 镜像加速地址列表
#   仅对 docker.io（Docker Hub）生效
#   非 Docker Hub 的仓库（ghcr.io / quay.io / gcr.io）需单独处理
#
#   常用地址:
#     https://docker.m.daocloud.io
#     https://docker.xuanyuan.me
#     https://docker.1ms.run
#     腾讯云 CVM 内网: https://mirror.ccs.tencentyun.com
#     阿里云 ECS 内网: https://<你的ID>.mirror.aliyuncs.com
#
#   空数组表示不使用加速器:
#     DOCKER_MIRRORS=()
DOCKER_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://docker.xuanyuan.me"
    "https://docker.1ms.run"
)

# DOCKER_LOG_MAX_SIZE: 单个容器日志文件最大尺寸
#   支持单位: k / m / g
#   示例: 10m / 50m / 1g / 100k
DOCKER_LOG_MAX_SIZE="10m"

# DOCKER_LOG_MAX_FILE: 容器日志文件保留份数（滚动覆盖）
#   示例: 3 / 5 / 10
DOCKER_LOG_MAX_FILE="3"

# DOCKER_LIVE_RESTORE: 重启 Docker 守护进程时容器是否停止
#   true  = 容器不停止（推荐生产环境）
#   false = 停止所有容器
DOCKER_LIVE_RESTORE=true

# DOCKER_DAEMON_MODE: 处理 /etc/docker/daemon.json 的策略
#
#   auto    = 已存在则保留；不存在则用推荐配置创建（推荐）
#             全自动模式下也不会覆盖已有配置
#   keep    = 已存在则保留；不存在则跳过（完全不动）
#   default = 已存在时——
#               半自动: 询问是否覆盖
#               全自动: 直接覆盖（会先备份）
#             不存在时创建推荐配置
#   skip    = 完全不处理 daemon.json
DOCKER_DAEMON_MODE=auto
```

### Compose 部署

```bash
# COMPOSE_DEPLOY: 是否执行批量部署
#   true  = 执行
#   false = 跳过（默认）
COMPOSE_DEPLOY=false

# COMPOSE_YAML_DIR: YAML 文件所在目录（绝对路径）
#   留空时使用脚本执行时的当前目录
#   示例:
#     /root
#     /opt/compose
#     /data/stacks
COMPOSE_YAML_DIR=

# COMPOSE_MODE: 部署方案
#   A = 保留原文件名，使用 docker compose -p <name> -f <file> up -d（推荐）
#   B = 复制时将 YAML 重命名为 docker-compose.yml
COMPOSE_MODE=A
```

### 日志配置（可选）

以下变量通过配置文件设置时，会覆盖同名环境变量。通常不建议在配置文件里修改，用环境变量更灵活：

```bash
# LOG_DIR="/var/log/init_server"
# LOG_LEVEL="INFO"
# LOG_CMD_OUTPUT=1
# LOG_MAX_BYTES=4000
```

### 完整配置示例

```bash
# ============================================================
# 生产环境配置示例
# ============================================================

# SSH 加固
SSH_CHANGE=true
SSH_PORT=2222
SSH_CLOSE_OLD_PORT=true

# 系统源
PACKAGE_SOURCE_MODE=auto

# Docker
DOCKER_INSTALL=true
DOCKER_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://docker.xuanyuan.me"
    "https://docker.1ms.run"
)
DOCKER_LOG_MAX_SIZE="50m"
DOCKER_LOG_MAX_FILE="5"
DOCKER_LIVE_RESTORE=true
DOCKER_DAEMON_MODE=auto

# Compose 部署
COMPOSE_DEPLOY=true
COMPOSE_YAML_DIR=/opt/compose
COMPOSE_MODE=A
```

---

## 功能模块详解

### 一、SSH 端口修改

#### 执行流程

```
1. 备份 sshd_config
2. 写入新的 Port 配置
3. 通过检测到的防火墙放行新端口
4. 处理 SELinux 策略（若启用）
5. 重启 sshd 服务
6. 验证新端口是否监听
7. 成功后关闭旧端口（可选）
```

#### 安全保护

**任一环节失败都会自动回退**到备份配置：

| 失败点 | 处理 |
|--------|------|
| 防火墙放行失败 | 回退 sshd_config，重启 sshd |
| SELinux 策略失败 | 记录警告，继续（不阻塞） |
| 重启后端口未监听 | 回退 sshd_config，重启 sshd |

#### 幂等性

如果当前端口已经是目标端口，脚本会直接跳过，不会重复操作。

#### 首次使用建议

```bash
SSH_CHANGE=true
SSH_PORT=2222
SSH_CLOSE_OLD_PORT=false    # 首次保留 22
```

用半自动模式运行，另开终端测试新端口：

```bash
ssh -p 2222 root@your-server-ip
```

确认能连上后，改为：

```bash
SSH_CLOSE_OLD_PORT=true
```

#### 万一失联怎么办

如果 SSH 端口修改后完全无法连接：

1. 通过云平台控制台的 VNC/串口登录
2. 找到备份文件：

```bash
ls -la /etc/ssh/sshd_config.bak.*
```

3. 恢复：

```bash
cp /etc/ssh/sshd_config.bak.YYYYMMDD_HHMMSS /etc/ssh/sshd_config
systemctl restart sshd
```

---

### 二、系统包源修复

#### 处理策略

| 模式 | 行为 |
|------|------|
| `auto` | 先测试现有源；可用则用，不可用则按模式处理 |
| `default` | 直接应用内置默认源（阿里云） |
| `custom` | 使用自定义源（URL 或本地文件） |
| `skip` | 完全跳过 |

#### 内置默认源

脚本针对不同发行版内置了阿里云源配置：

| 发行版 | 源配置 |
|--------|--------|
| Ubuntu 24.04+ | 使用 deb822 格式（`/etc/apt/sources.list.d/ubuntu.sources`） |
| Ubuntu 22.04 及以下 | 使用传统 apt 格式（`/etc/apt/sources.list`） |
| Debian 11+ | apt 格式 |
| CentOS 7 | yum repo |
| Rocky / Alma | yum repo（替换 baseurl） |
| CentOS 8+ | ⚠️ 提示手动处理（已 EOL） |

#### 自定义源

**方式一：URL**

```bash
PACKAGE_SOURCE_MODE=custom
PACKAGE_SOURCE_URL=https://mirrors.tuna.tsinghua.edu.cn
```

脚本会根据系统版本自动拼装完整路径。

**方式二：本地文件**

```bash
PACKAGE_SOURCE_MODE=custom
PACKAGE_SOURCE_FILE=/root/custom-sources.list
```

脚本会复制到系统的源目录。

#### 备份机制

修改前的源文件会自动备份到 `.bak.YYYYMMDD_HHMMSS`，只保留最近 5 份。

---

### 三、Docker 安装

#### 安装方式

| 系统 | 安装方式 |
|------|---------|
| Ubuntu / Debian | Docker 官方脚本 + 阿里云镜像 |
| CentOS / RHEL / Rocky / Alma | 阿里云 Docker CE 源 |
| Fedora | 阿里云 Docker CE 源 |

#### 镜像源降级

如果阿里云 Docker 源不可达，脚本会：

1. **半自动**：询问是否切换到 Docker 官方源
2. **全自动**：直接切换到官方源

#### 幂等性

如果 Docker 已安装，脚本**不会重复安装**，只做以下检查：

- 服务是否运行（`systemctl is-active docker`）
- 是否开机自启（`systemctl is-enabled docker`）
- 状态正常则完全跳过

#### 校验安装结果

安装完成后会验证：

```bash
docker info | grep -A5 "Registry Mirrors"
```

确认镜像加速配置生效。

---

### 四、daemon.json 配置

#### 处理策略

| 模式 | 文件已存在 | 文件不存在 |
|------|-----------|-----------|
| `auto` | 保留，不动 | 创建推荐配置 |
| `keep` | 保留，不动 | 跳过，不创建 |
| `default` | 半自动询问 / 全自动覆盖 | 创建推荐配置 |
| `skip` | 完全不动 | 完全不动 |

#### 推荐配置内容

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.xuanyuan.me",
    "https://docker.1ms.run"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
```

#### 字段说明

| 字段 | 作用 |
|------|------|
| `registry-mirrors` | Docker Hub 镜像加速地址 |
| `log-driver` | 日志驱动，`json-file` 是默认值 |
| `log-opts.max-size` | 单日志文件上限，防止日志撑爆磁盘 |
| `log-opts.max-file` | 日志保留份数，滚动覆盖 |
| `live-restore` | 重启 Docker 守护进程时容器不停止 |

#### 重启保护

**只有配置真正发生变化时才会重启 Docker**。已存在且内容相同的配置不会触发重启，避免无谓的中断容器。

---

### 五、Compose 批量部署

#### 文件命名规则

脚本自动识别以下命名规则：

```
<yaml-dir>/
├── docker-compose_<name>.yml     ← 识别
├── docker-compose_<name>.yaml    ← 识别
├── <name>.env                    ← 配对复制
└── 其他文件                       ← 忽略
```

`<name>` 会成为目标目录名。

#### 完整处理流程

以 `docker-compose_web.yml` + `web.env` 为例：

**原始目录：**

```
/opt/compose/
├── docker-compose_web.yml
├── web.env
├── docker-compose_api.yml
├── api.env
└── README.md
```

**方案 A 处理后（推荐）：**

```
/opt/compose/
├── docker-compose_web.yml       ← 保留（源文件不动）
├── web.env                       ← 保留
├── docker-compose_api.yml        ← 保留
├── api.env                       ← 保留
├── README.md
├── web/                          ← 新建
│   ├── docker-compose_web.yml    ← 复制
│   └── .env                      ← web.env 复制并重命名
└── api/                          ← 新建
    ├── docker-compose_api.yml    ← 复制
    └── .env                      ← api.env 复制并重命名
```

启动命令：`docker compose -p web -f docker-compose_web.yml up -d`

**方案 B 处理后：**

```
/opt/compose/
├── web/
│   ├── docker-compose.yml        ← 复制并重命名
│   └── .env
└── api/
    ├── docker-compose.yml
    └── .env
```

启动命令：`docker compose up -d`

#### 部署流程

每个项目按以下步骤处理：

1. **复制 YAML 到目标目录**
2. **复制 `<name>.env` 为 `.env`**（如果存在）
3. **YAML 语法预校验**（`docker compose config`）
4. **拉取镜像**（带进度显示）
5. **启动容器**（`docker compose up -d`）
6. **显示容器状态**

#### 错误处理

| 阶段 | 半自动 | 全自动 |
|------|--------|--------|
| YAML 语法错误 | 询问是否继续 | 自动跳过继续 |
| 镜像拉取失败 | 记录警告继续 | 记录警告继续 |
| 容器启动失败 | 记录继续 | 记录继续 |

**注意**：容器启动失败**不会**中断整个部署流程，脚本会继续处理下一个项目，最后统一汇总。

#### 进度显示

脚本根据终端环境自动选择进度模式：

- **交互式终端**：显示动态进度条（镜像层下载进度）
- **重定向日志**：使用 plain 模式，逐行追加

---

### 六、防火墙自动适配

#### 检测顺序

脚本按以下优先级检测：

```
firewalld（活跃） → ufw（启用） → nftables（有规则） → iptables（有规则） → 无
```

#### 支持的防火墙

| 系统 | 检测到的防火墙 | 操作 |
|------|--------------|------|
| CentOS/RHEL/Rocky/Alma/Fedora | firewalld | `firewall-cmd --permanent --add-port` |
| Ubuntu / Debian（启用 ufw） | ufw | `ufw allow` |
| Debian 10+ / Arch | nftables | `nft add rule` |
| 老式系统 / Alpine | iptables | `iptables -I INPUT` |
| 容器 / WSL2 | 无 | 提示"无需放行" |

#### 关键设计

**已安装但未启用的防火墙不会被误判为活跃**。例如：

- Ubuntu 装了 ufw 但没 `ufw enable` → 脚本会继续检测其他工具
- firewalld 已安装但服务未启动 → 同上

这样可以避免"看似放行实际无效"的问题。

#### 云平台提示

脚本通过元数据服务识别云环境：

| 云平台 | 元数据地址 |
|--------|-----------|
| 阿里云 | `http://100.100.100.200` |
| AWS / 腾讯云 | `http://169.254.169.254` |

检测到后会在放行端口时额外提醒：

```
⚠️  检测到 阿里云 环境，请在控制台安全组中放行 2222/tcp
    云平台安全组独立于系统防火墙，脚本无法自动配置
```

**注意**：云平台安全组需要**独立于系统防火墙配置**，脚本无法自动操作。

#### 持久化

| 防火墙 | 持久化方式 |
|--------|-----------|
| firewalld | `--permanent` 参数自动持久化 |
| ufw | 自动持久化 |
| nftables | 写入 `/etc/nftables.conf`（若存在） |
| iptables | 尝试多个常见路径 |

iptables 持久化路径尝试顺序：

1. `/etc/sysconfig/iptables`（RHEL/CentOS）
2. `/etc/iptables/rules.v4`（Debian/Ubuntu）
3. `/etc/iptables.rules`（通用兜底）

---

## 日志系统

### 日志文件

每次运行生成一个带时间戳的日志：

```
logs/init_server_20260925_143012_12345.log
```

文件名格式：`init_server_<日期>_<时间>_<PID>.log`

### 日志内容

| 内容 | 说明 |
|------|------|
| 环境快照 | 主机名、内核、内存、磁盘、公网 IP |
| 命令级记录 | 执行的命令、耗时、退出码、输出 |
| 文件快照 | 修改的关键文件的大小、行数、sha256 |
| 步骤计时 | 每个步骤的开始/结束时间 |
| 错误/警告汇总 | 执行结束时统一输出 |

### 日志格式

```
[2026-09-25 14:30:12.345] [INFO] [PID:12345] ▶▶▶ [步骤开始] Docker 安装
[2026-09-25 14:30:12.412] [INFO] [PID:12345] [CMD] ✅ 成功: 启用 docker 服务 （rc=0, 耗时 0.114s）
[2026-09-25 14:30:15.223] [WARN] [PID:12345] 镜像拉取有错误（rc=1），继续尝试启动
[2026-09-25 14:30:20.001] [ERROR] [PID:12345] 项目 web：容器启动失败
```

### 环境变量

| 变量 | 默认 | 作用 |
|------|------|------|
| `LOG_DIR` | 脚本目录下 `logs/` | 日志目录 |
| `LOG_LEVEL` | `INFO` | 日志级别 `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_CMD_OUTPUT` | `1` | 是否记录命令输出 |
| `LOG_MAX_BYTES` | `4000` | 单条命令输出记录上限 |
| `DEBUG` | `0` | `1` 时开启 `set -x` |

### 调试示例

```bash
# 详细日志
sudo LOG_LEVEL=DEBUG bash init_server.sh --config /etc/my-init.conf

# 追踪每个 shell 命令
sudo DEBUG=1 LOG_LEVEL=DEBUG bash init_server.sh --config /etc/my-init.conf

# 自定义日志目录
sudo LOG_DIR=/var/log/myinit bash init_server.sh --config /etc/my-init.conf
```

### 日志分析

```bash
# 只看错误
grep '\[ERROR\]' logs/init_server_*.log

# 只看警告
grep '\[WARN\]' logs/init_server_*.log

# 查看所有命令执行记录
grep '\[CMD\]' logs/init_server_*.log

# 查看某一步骤的完整记录
sed -n '/步骤开始] Docker 安装/,/步骤结束] Docker 安装/p' logs/init_server_*.log

# 查看错误汇总
grep -A20 '错误汇总' logs/init_server_*.log

# 查看文件快照
grep '快照' logs/init_server_*.log
```

### 日志清理

日志会随时间累积。建议加入清理任务：

```bash
# 只保留最近 30 天
find /var/log/init_server -name 'init_server_*.log' -mtime +30 -delete
```

或加到 crontab：

```cron
0 3 * * * find /var/log/init_server -name 'init_server_*.log' -mtime +30 -delete
```

---

## 使用场景示例

### 场景 1：全新机器首次部署

```bash
# 1. 下载脚本
curl -fsSL https://raw.githubusercontent.com/<your-username>/init-server/main/init_server.sh -o init_server.sh

# 2. 生成配置
bash init_server.sh --dump-config > /etc/my-init.conf
chmod 600 /etc/my-init.conf

# 3. 编辑配置
cat > /etc/my-init.conf <<'EOF'
SSH_CHANGE=true
SSH_PORT=2222
SSH_CLOSE_OLD_PORT=false    # 首次保留 22

PACKAGE_SOURCE_MODE=auto
DOCKER_INSTALL=true
DOCKER_DAEMON_MODE=auto

COMPOSE_DEPLOY=true
COMPOSE_YAML_DIR=/root
COMPOSE_MODE=A
EOF

# 4. 半自动执行（观察每一步）
sudo bash init_server.sh --config /etc/my-init.conf

# 5. 确认新端口连接正常后，改为全自动
sed -i 's/SSH_CLOSE_OLD_PORT=false/SSH_CLOSE_OLD_PORT=true/' /etc/my-init.conf
sudo bash init_server.sh --config /etc/my-init.conf --yes
```

### 场景 2：CI/CD 批量刷机器

```bash
#!/bin/bash
# batch-deploy.sh

HOSTS="node1 node2 node3"
CONFIG="/etc/my-init.conf"

for host in $HOSTS; do
    echo "=== 部署 $host ==="

    # 分发脚本和配置
    scp init_server.sh "$CONFIG" "root@$host:/tmp/"

    # 远程执行
    ssh "root@$host" "sudo bash /tmp/init_server.sh --config /tmp/my-init.conf --yes"

    # 检查退出码
    if [[ $? -ne 0 ]]; then
        echo "❌ $host 部署失败"
    else
        echo "✅ $host 部署成功"
    fi
done
```

### 场景 3：只安装 Docker

```bash
cat > /tmp/docker-only.conf <<'EOF'
SSH_CHANGE=false
PACKAGE_SOURCE_MODE=auto
DOCKER_INSTALL=true
DOCKER_DAEMON_MODE=keep     # 有就留，没有就不创建
COMPOSE_DEPLOY=false
EOF

sudo bash init_server.sh --config /tmp/docker-only.conf --yes
```

### 场景 4：离线/内网环境

```bash
cat > /tmp/offline.conf <<'EOF'
SSH_CHANGE=false

PACKAGE_SOURCE_MODE=custom
PACKAGE_SOURCE_FILE=/root/offline-sources.list

DOCKER_INSTALL=false        # Docker 需手动预装
DOCKER_DAEMON_MODE=keep
DOCKER_MIRRORS=()           # 内网不需要加速

COMPOSE_DEPLOY=true
COMPOSE_YAML_DIR=/opt/stacks
EOF

sudo bash init_server.sh --config /tmp/offline.conf --yes
```

### 场景 5：只更新 Compose 项目

已经配好 Docker 的机器，只需要重新部署项目：

```bash
cat > /tmp/update.conf <<'EOF'
SSH_CHANGE=false
PACKAGE_SOURCE_MODE=skip
DOCKER_INSTALL=true
DOCKER_DAEMON_MODE=auto     # auto 在已存在时自动保留
COMPOSE_DEPLOY=true
COMPOSE_YAML_DIR=/opt/compose
COMPOSE_MODE=A
EOF

sudo bash init_server.sh --config /tmp/update.conf --yes
```

### 场景 6：多环境变体

按机器角色使用不同配置：

```bash
# /etc/my-init.conf.d/ 目录下
web-server.conf    # Web 服务器配置
db-server.conf     # 数据库服务器配置
cache-server.conf  # 缓存服务器配置

# 部署时按角色选择
sudo bash init_server.sh --config /etc/my-init.conf.d/web-server.conf --yes
sudo bash init_server.sh --config /etc/my-init.conf.d/db-server.conf --yes
```

---

## 常见问题 FAQ

### Q1: `.env` 文件为什么看不到？

**A**: `.env` 是以点开头的隐藏文件，`ls` 默认不显示。用以下命令查看：

```bash
ls -la /path/to/project/
cat /path/to/project/.env
```

### Q2: 镜像拉取很慢/失败？

**A**: 检查镜像加速配置是否生效：

```bash
docker info | grep -A5 "Registry Mirrors"
```

如果未生效，检查 `/etc/docker/daemon.json`：

```bash
cat /etc/docker/daemon.json
```

修改后重启 Docker：

```bash
systemctl daemon-reload
systemctl restart docker
```

**注意**：`registry-mirrors` **只对 Docker Hub 生效**。非 Docker Hub 的仓库（`ghcr.io` / `quay.io` / `gcr.io` / `registry.k8s.io`）需要单独配置或直接使用完整地址。

### Q3: 如何让脚本不改我的 `daemon.json`？

**A**: 在配置文件中设置：

```bash
DOCKER_DAEMON_MODE=skip
```

或者设置为 `keep`（有就留，没有就不创建）。

### Q4: 脚本执行完但结束时报错？

**A**: 查看日志末尾的"错误汇总"部分。通常是因为某个 Compose 项目有问题，但脚本依然完成了其他项目。

```bash
# 定位错误
grep -A20 '错误汇总' logs/init_server_*.log
```

### Q5: 支持 ARM 架构吗？

**A**: 脚本本身与架构无关。但 Docker 镜像需要支持你的架构。如果镜像是 x86_64-only 的，在 ARM 机器上会报 `no matching manifest`。

解决方案：
1. 选择支持多架构的镜像（如 `nginx`、`mysql` 官方镜像）
2. 在 Compose 文件中显式指定：

```yaml
services:
  web:
    image: nginx
    platform: linux/amd64
```

### Q6: SSH 端口修改后连不上怎么办？

**A**: 通过云平台控制台的 VNC/串口登录，然后：

```bash
# 查看备份
ls -la /etc/ssh/sshd_config.bak.*

# 恢复
cp /etc/ssh/sshd_config.bak.YYYYMMDD_HHMMSS /etc/ssh/sshd_config
systemctl restart sshd
```

### Q7: 脚本可以在容器里运行吗？

**A**: 技术上是可行的，但意义不大。容器环境通常没有 systemd，防火墙操作也不适用。如果需要，建议只在容器里使用 Compose 部署部分。

### Q8: 如何修改日志级别？

**A**: 三种方式：

```bash
# 1. 环境变量
sudo LOG_LEVEL=DEBUG bash init_server.sh

# 2. 配置文件（会覆盖环境变量）
echo 'LOG_LEVEL=DEBUG' >> /etc/my-init.conf

# 3. 只在调试时启用（临时）
sudo LOG_LEVEL=DEBUG bash init_server.sh --config /etc/my-init.conf
```

### Q9: 脚本会修改我的系统源吗？

**A**: 取决于 `PACKAGE_SOURCE_MODE`：

- `auto`：现有源可用时**不动**；不可用时按模式处理
- `default`：直接覆盖为阿里云源（会先备份）
- `custom`：使用你提供的源（会先备份）
- `skip`：**完全不动**

无论哪种模式，修改前都会备份到 `.bak.YYYYMMDD_HHMMSS`。

### Q10: 配置文件权限要求？

**A**: 脚本会**拒绝加载"其他用户可写"的配置文件**，防止提权攻击。

```bash
chmod 600 /etc/my-init.conf
```

### Q11: 部署失败后如何重试？

**A**: 直接重新运行脚本即可。脚本是幂等的：

- 已改好的 SSH 端口会跳过
- 已装的 Docker 会跳过
- 已存在的 daemon.json 按 `DOCKER_DAEMON_MODE` 处理
- 已部署的容器会被 `docker compose up -d` 重新应用

### Q12: 脚本会删除我的现有数据吗？

**A**: **不会**。脚本设计原则：

- 修改文件前先备份
- 通过复制而非移动文件
- 已存在的 daemon.json 默认保留
- 已运行的 Docker 服务不重启（除非配置变化）

**唯一会关闭的**是 SSH 的 22 端口（当 `SSH_CLOSE_OLD_PORT=true` 且新端口验证成功后）。

### Q13: 如何完全卸载？

**A**: 脚本本身不产生需要卸载的内容。如果清理：

```bash
# 停止所有 Compose 项目
cd /opt/compose
for d in */; do
    cd "$d"
    docker compose down
    cd ..
done

# 卸载 Docker（如需要）
apt-get remove docker-ce docker-ce-cli containerd.io
# 或
yum remove docker-ce docker-ce-cli containerd.io

# 清理数据（慎用！会删除所有镜像和容器）
rm -rf /var/lib/docker
```

---

## 最佳实践

### 1. 首次部署用半自动

第一次在新机器上运行，用 `--config` 半自动模式，观察每一步的输出。等确认无误后，才改为 `--yes` 全自动。

### 2. SSH 端口分两步改

```bash
# 第一次：保留 22
SSH_CHANGE=true
SSH_PORT=2222
SSH_CLOSE_OLD_PORT=false
```

另开终端测试新端口连接成功后再改：

```bash
SSH_CLOSE_OLD_PORT=true
```

### 3. 生产环境用 `live-restore`

```bash
DOCKER_LIVE_RESTORE=true
```

这样即使以后需要改 `daemon.json` 重启 Docker，运行中的容器也不会停止。

### 4. 限制日志大小

```bash
DOCKER_LOG_MAX_SIZE="50m"
DOCKER_LOG_MAX_FILE="5"
```

不限制的话，持续输出的容器几个月后日志会撑爆磁盘。

### 5. 用配置文件而非命令行

配置文件可以版本控制、review、diff，比临时拼命令行更可靠：

```bash
# 好
sudo bash init_server.sh --config /etc/my-init.conf

# 不好
sudo bash init_server.sh  # 然后手工输入各种参数
```

### 6. 保持配置文件权限收紧

```bash
chmod 600 /etc/my-init.conf
```

### 7. 定期清理日志和备份

```bash
# crontab
0 3 * * * find /var/log/init_server -name '*.log' -mtime +30 -delete
0 3 * * * find /etc -name '*.bak.*' -mtime +30 -delete 2>/dev/null
```

~~### 8. 在云平台上双重放行~~

~~脚本只配置系统防火墙，云平台安全组需要手动操作：~~

~~- 阿里云：ECS 控制台 → 安全组 → 配置规则~~
~~- AWS：EC2 → Security Groups~~
~~- 腾讯云：CVM 控制台 → 安全组~~

---

## 故障排查

### 检查点 1：脚本是否正常启动

```bash
bash -n init_server.sh    # 语法检查
```

### 检查点 2：查看详细日志

```bash
sudo LOG_LEVEL=DEBUG bash init_server.sh --config /etc/my-init.conf
```

### 检查点 3：定位失败步骤

```bash
# 查看错误汇总
grep -B2 -A20 '错误汇总' logs/init_server_*.log

# 或看错误行
grep '\[ERROR\]' logs/init_server_*.log
```

### 检查点 4：常见错误对照

| 错误信息 | 原因 | 解决 |
|---------|------|------|
| `no matching manifest for linux/arm64` | 镜像不支持 ARM | 换镜像或加 `platform` |
| `dial tcp ... i/o timeout` | 网络不通 | 检查镜像加速、防火墙 |
| `unauthorized` | 私有仓库需认证 | `docker login` |
| `manifest unknown` | 镜像 tag 不存在 | 检查 YAML 中的 tag |
| `port is already allocated` | 端口冲突 | 修改映射端口或停止占用进程 |
| `permission denied` | 权限问题 | 用 `sudo` 运行 |
| `no configuration file provided` | 目录中无 compose 文件 | 检查文件名和路径 |

### 检查点 5：手动复现

在目标目录下手工执行，看具体错误：

```bash
cd /opt/compose/web
docker compose -p web -f docker-compose_web.yml config   # 只校验
docker compose -p web -f docker-compose_web.yml pull      # 只拉镜像
docker compose -p web -f docker-compose_web.yml up -d     # 只启动
```

每一步分开执行，报错信息更精确。

---

## 项目结构

```
init-server/
├── init_server.sh                # 主脚本
├── README.md                     # 本文档
├── LICENSE                       # MIT 许可证
├── CHANGELOG.md                  # 更新日志
```

---

## 贡献指南

### 报告问题

提交 Issue 时请提供：

1. **系统信息**：`cat /etc/os-release`
2. **脚本版本**：脚本头部注释里的版本号
3. **完整日志**：`logs/init_server_*.log`
4. **复现步骤**：具体操作

### 提交 PR

1. Fork 仓库
2. 创建分支：`git checkout -b feature/your-feature`
3. 修改代码
4. 本地测试：
   ```bash
   bash -n init_server.sh
   shellcheck init_server.sh
   ```
5. 提交：`git commit -am 'Add feature'`
6. 推送：`git push origin feature/your-feature`
7. 创建 Pull Request

### 代码规范

- 使用 `bash -n` 检查语法
- 使用 `shellcheck` 检查代码质量
- 新增函数加注释说明
- 错误处理遵循现有模式

### 测试环境

建议在以下环境测试改动：

- CentOS 7 或 Rocky 9
- Ubuntu 22.04 或 Debian 12

---

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)

## 许可证

MIT License — 详见 [LICENSE](LICENSE) 文件。

Copyright (c) 2026

## 致谢

如果这个脚本帮你节省了时间，请点个 ⭐ 支持一下。

---



