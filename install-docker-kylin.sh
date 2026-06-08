#!/bin/bash
###############################################################################
#  install-docker-kylin.sh
#  在银河麒麟 V10 (x86_64) 上自动安装 Docker CE
#
#  使用方法:
#    1. 把脚本上传到服务器,或在服务器上用 vi 创建:
#         vi install-docker-kylin.sh
#         (粘贴内容,:wq 保存)
#
#    2. 加执行权限并运行:
#         chmod +x install-docker-kylin.sh
#         sudo ./install-docker-kylin.sh
#
#  !!! 不要把脚本内容整段复制粘贴到终端执行 !!!
#  !!! 必须先保存成文件再运行 !!!
###############################################################################

set -e
set -u

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}>> $*${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

# ===== 必须 root =====
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 sudo 运行: sudo $0"
    exit 1
fi

# ===== 记录原始用户(给 docker 组用) =====
ORIG_USER="${SUDO_USER:-$USER}"

# ===== 配置项 =====
DOCKER_VERSION="26.1.2-1.el8"
DOCKER_REPO_URL="https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
DOCKER_REPO_FILE="/etc/yum.repos.d/docker-ce.repo"
CONTAINER_SELINUX_URL="https://mirrors.aliyun.com/almalinux/8/AppStream/x86_64/os/Packages/container-selinux-2.229.0-2.module_el8.10.0+4082+f7f0c95e.noarch.rpm"
ALMALINUX_REPO="https://mirrors.aliyun.com/almalinux/8/AppStream/x86_64/os/Packages/"

# 国内镜像源
MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://dockerproxy.com"
    "https://docker.mirrors.ustc.edu.cn"
    "https://hub-mirror.c.163.com"
)

###############################################################################
# 步骤 1: 检查环境
###############################################################################
log_step "步骤 1/8: 检查系统环境"

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    log_error "仅支持 x86_64,当前: $ARCH"
    exit 1
fi
log_ok "架构: $ARCH"

if [[ -f /etc/kylin-release ]]; then
    log_ok "系统: $(cat /etc/kylin-release)"
else
    log_warn "未检测到 /etc/kylin-release,可能不是麒麟系统"
fi

if curl -sI --max-time 5 https://mirrors.aliyun.com > /dev/null; then
    log_ok "网络: mirrors.aliyun.com 可访问"
else
    log_error "无法访问 mirrors.aliyun.com,请检查网络"
    exit 1
fi

###############################################################################
# 步骤 2: 清理旧组件
###############################################################################
log_step "步骤 2/8: 清理 podman / 旧 containerd"

yum remove -y podman buildah skopeo containers-common podman-compose 2>/dev/null || true
yum remove -y containerd.io 2>/dev/null || true
rm -rf /etc/containers /var/lib/containers /var/run/containers 2>/dev/null || true
log_ok "清理完成"

###############################################################################
# 步骤 3: 配置 docker-ce 源
###############################################################################
log_step "步骤 3/8: 配置 docker-ce 源"

# 源文件不存在则下载
if [[ ! -f "$DOCKER_REPO_FILE" ]]; then
    log_info "下载 docker-ce 源..."
    if ! curl -fsSL -o "$DOCKER_REPO_FILE" "$DOCKER_REPO_URL"; then
        log_error "源文件下载失败: $DOCKER_REPO_URL"
        exit 1
    fi
    log_ok "源文件已下载"
else
    log_info "源文件已存在: $DOCKER_REPO_FILE"
fi

# 强制改成指向 CentOS 8(避免麒麟当成 el10)
sed -i 's|/centos/\$releasever|/centos/8|g' "$DOCKER_REPO_FILE"
log_ok "源已配置指向 CentOS 8"

# 刷新缓存
yum clean all > /dev/null 2>&1
yum makecache > /dev/null 2>&1

# 验证源生效
if yum repolist 2>/dev/null | grep -q docker-ce-stable; then
    log_ok "docker-ce 源生效"
else
    log_error "docker-ce 源未生效,检查 $DOCKER_REPO_FILE"
    cat "$DOCKER_REPO_FILE"
    exit 1
fi

###############################################################################
# 步骤 4: 安装 container-selinux
###############################################################################
log_step "步骤 4/8: 安装 container-selinux"

if rpm -q container-selinux > /dev/null 2>&1; then
    log_ok "container-selinux 已安装,跳过"
else
    TMPFILE="/tmp/container-selinux.rpm"

    log_info "下载 container-selinux..."
    if ! curl -L --fail -o "$TMPFILE" "$CONTAINER_SELINUX_URL" 2>/dev/null; then
        log_warn "预设 URL 失效,自动获取最新版本..."

        LATEST=$(curl -s "$ALMALINUX_REPO" \
            | grep -oE 'container-selinux-[0-9][^"]*\.noarch\.rpm' \
            | sort -u | tail -1)

        if [[ -z "$LATEST" ]]; then
            log_error "无法获取 container-selinux 包列表"
            exit 1
        fi

        log_info "找到最新版本: $LATEST"
        if ! curl -L --fail -o "$TMPFILE" "${ALMALINUX_REPO}${LATEST}"; then
            log_error "下载失败: ${ALMALINUX_REPO}${LATEST}"
            exit 1
        fi
    fi

    if [[ ! -s "$TMPFILE" ]]; then
        log_error "下载文件为空: $TMPFILE"
        exit 1
    fi

    log_ok "下载完成: $(ls -lh $TMPFILE | awk '{print $5}')"

    log_info "使用 --nodeps 强制安装(绕过麒麟 selinux-policy 命名差异)..."
    rpm -ivh --nodeps --replacepkgs "$TMPFILE"

    rm -f "$TMPFILE"
    log_ok "container-selinux 安装成功"
fi

###############################################################################
# 步骤 5: 安装 Docker
###############################################################################
log_step "步骤 5/8: 安装 Docker CE $DOCKER_VERSION"

yum install -y \
    "docker-ce-$DOCKER_VERSION" \
    "docker-ce-cli-$DOCKER_VERSION" \
    containerd.io \
    docker-compose-plugin \
    docker-buildx-plugin

log_ok "Docker 安装完成"

###############################################################################
# 步骤 6: 启动 Docker
###############################################################################
log_step "步骤 6/8: 启动 Docker 服务"

systemctl enable --now docker
sleep 2

if systemctl is-active --quiet docker; then
    log_ok "Docker 服务运行中"
else
    log_error "Docker 启动失败,日志:"
    journalctl -xeu docker --no-pager | tail -20
    exit 1
fi

###############################################################################
# 步骤 7: 配置镜像加速
###############################################################################
log_step "步骤 7/8: 配置国内镜像加速"

mkdir -p /etc/docker

if [[ -f /etc/docker/daemon.json ]]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    log_info "已备份原 daemon.json"
fi

# 生成 daemon.json
{
    echo "{"
    echo '  "registry-mirrors": ['
    for i in "${!MIRRORS[@]}"; do
        if [[ $i -eq $((${#MIRRORS[@]} - 1)) ]]; then
            echo "    \"${MIRRORS[$i]}\""
        else
            echo "    \"${MIRRORS[$i]}\","
        fi
    done
    echo "  ],"
    echo '  "log-driver": "json-file",'
    echo '  "log-opts": {'
    echo '    "max-size": "100m",'
    echo '    "max-file": "3"'
    echo "  },"
    echo '  "storage-driver": "overlay2"'
    echo "}"
} > /etc/docker/daemon.json

log_ok "daemon.json 已写入:"
cat /etc/docker/daemon.json

systemctl restart docker
sleep 2

if systemctl is-active --quiet docker; then
    log_ok "Docker 重启成功"
else
    log_error "Docker 重启失败,检查 daemon.json 格式"
    exit 1
fi

###############################################################################
# 步骤 8: 把用户加入 docker 组
###############################################################################
log_step "步骤 8/8: 用户权限"

if [[ "$ORIG_USER" != "root" ]]; then
    usermod -aG docker "$ORIG_USER"
    log_ok "用户 $ORIG_USER 已加入 docker 组"
else
    log_info "当前是 root,无需加组"
fi

###############################################################################
# 验证
###############################################################################
log_step "验证安装"

echo ""
log_info "Docker 版本:"
docker version --format 'Client: {{.Client.Version}} | Server: {{.Server.Version}}'

echo ""
log_info "Compose 版本:"
docker compose version

echo ""
log_info "镜像加速器:"
docker info 2>/dev/null | grep -A 4 "Registry Mirrors" || true

echo ""
log_info "测试拉取 hello-world..."
if docker run --rm docker.m.daocloud.io/library/hello-world > /tmp/docker-test.log 2>&1; then
    log_ok "Docker 测试成功!"
    grep "Hello from Docker" /tmp/docker-test.log || true
    rm -f /tmp/docker-test.log
else
    log_warn "测试失败,但 Docker 本身已装好。错误信息:"
    cat /tmp/docker-test.log
    rm -f /tmp/docker-test.log
fi

###############################################################################
# 完成
###############################################################################
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                  Docker 安装完成!                         ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "常用命令:"
echo "  docker ps                          # 看运行中的容器"
echo "  docker images                      # 看本地镜像"
echo "  docker compose up -d               # compose 启动"
echo ""
echo "拉镜像示例(用国内加速):"
echo "  docker pull docker.m.daocloud.io/library/nginx"
echo "  docker pull docker.m.daocloud.io/grafana/grafana"
echo ""

if [[ "$ORIG_USER" != "root" ]]; then
    echo "提示: 重新登录(或执行 newgrp docker)才能免 sudo 使用 docker"
fi
echo ""