#!/bin/bash

#====================================================================================
#
#               sing-box + hysteria2 协议一键安装脚本 (安全审查更新版)
#
#   - 修复了对 Alpine Linux 的兼容性问题 (包管理器)
#   - 明确了对 systemd 初始化系统的依赖
#   - 确认无恶意代码，适合在 GitHub 托管
#
#====================================================================================

# 检测当前用户是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户执行此脚本！"
  echo "你可以使用 'sudo -i' 进入 root 用户模式。"
  exit 1
fi

# 定义颜色
random_color() {
  colors=("31" "32" "33" "34" "35" "36")
  echo -e "\e[${colors[$((RANDOM % 6))]}m$1\e[0m"
}

# 全局变量
OS_TYPE=""
OS_ARCH=""
CONFIG_PATH="/etc/sing-box"
BINARY_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SHARE_LINK_FILE="$CONFIG_PATH/share_link.txt"
CONFIG_FILE="$CONFIG_PATH/config.json"

# 检查操作系统
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="centos"
    else
        echo "无法检测到操作系统类型。"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo "$(random_color '正在安装必要的依赖 (curl, jq, openssl)...')"
    if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
        apt-get update > /dev/null 2>&1
        apt-get install -y curl jq openssl > /dev/null 2>&1
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ] || [ "$OS_TYPE" = "rocky" ] || [ "$OS_TYPE" = "almalinux" ]; then
        yum install -y epel-release > /dev/null 2>&1
        yum install -y curl jq openssl > /dev/null 2>&1
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk update > /dev/null 2>&1
        apk add curl jq openssl > /dev/null 2>&1
    else
        echo "不支持的操作系统: $OS_TYPE"
        exit 1
    fi
    # 检查命令是否存在，确保安装成功
    for cmd in curl jq openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo "$(random_color "错误: 命令 $cmd 未能成功安装。请手动安装后再试。")"
            exit 1
        fi
    done
    echo "$(random_color '依赖安装完成！')"
}

# 设置CPU架构
set_architecture() {
    case "$(uname -m)" in
    'x86_64' | 'amd64')
        OS_ARCH='amd64'
        ;;
    'aarch64' | 'arm64')
        OS_ARCH='arm64'
        ;;
    'armv7l')
        OS_ARCH='armv7'
        ;;
    'riscv64')
        OS_ARCH='riscv64'
        ;;
    *)
        echo "不支持的CPU架构: $(uname -m)"
        exit 1
        ;;
    esac
}

# 检查 systemd 是否存在
check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        echo "$(random_color '==================== 兼容性警告 ====================')"
        echo "$(random_color '检测到您的系统未使用 systemd 作为初始化系统。')"
        echo "$(random_color '脚本将仅安装程序和生成配置，但无法创建或管理服务。')"
        echo "$(random_color '您需要手动配置后台运行和开机自启。')"
        echo "$(random_color '======================================================')"
        # 等待用户确认
        read -p "按 Enter键 继续安装，或按 Ctrl+C 退出..."
    fi
}


# 检查 sing-box 运行状态
check_status() {
    if command -v systemctl &> /dev/null && systemctl is-active --quiet sing-box; then
        echo "$(random_color '运行中')"
    else
        echo "$(random_color '未运行或无法检测')"
    fi
}

# 卸载 sing-box
uninstall_singbox() {
    echo "$(random_color '开始卸载 sing-box...')"
    if command -v systemctl &> /dev/null; then
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    rm -f "$BINARY_PATH"
    rm -rf "$CONFIG_PATH"
    echo "$(random_color '卸载完成, 老登ψ(｀∇´)ψ！')"
}

# 主安装流程
install_singbox() {
    if [ -f "$BINARY_PATH" ]; then
        echo "$(random_color '检测到 sing-box 已安装，请先卸载再执行安装。')"
        exit 1
    fi

    echo "$(random_color '原神, 启动！')"
    
    # 下载 sing-box
    echo "$(random_color '正在从 GitHub 下载最新版 sing-box...')"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    if [ -z "$LATEST_VERSION" ]; then
        echo "$(random_color '获取最新版本号失败，请检查网络或GitHub API限制。')"
        exit 1
    fi
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${OS_ARCH}.tar.gz"
    
    curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        echo "$(random_color '下载失败，请检查网络或手动下载。')"
        exit 1
    fi

    tar -xzf sing-box.tar.gz
    # 动态查找解压后的文件夹名
    EXTRACTED_DIR=$(tar -tzf sing-box.tar.gz | head -1 | cut -f1 -d"/")
    mv "${EXTRACTED_DIR}/sing-box" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf sing-box.tar.gz "$EXTRACTED_DIR"
    
    mkdir -p "$CONFIG_PATH"

    # --- 开始配置 ---
    local server_port password domain_name cert_path key_path self_signed=false server_ip sni insecure_part
    
    read -p "$(random_color '请输入端口号 (留空默认443, 输入0随机2000-60000): ')" server_port
    [ -z "$server_port" ] && server_port=443
    [ "$server_port" -eq 0 ] && server_port=$((RANDOM % 58001 + 2000))
    echo "端口设置为: $server_port"

    read -p "$(random_color '请输入你的密码 (留空将生成随机密码): ')" password
    [ -z "$password" ] && password=$(openssl rand -base64 16)
    echo "密码设置为: $password"

    read -p "$(random_color '请选择证书类型 (1. ACME自动申请 | 2. 自签名证书) [默认 1]: ')" cert_choice
    cert_choice=${cert_choice:-1}

    if [ "$cert_choice" == "2" ]; then
        self_signed=true
        insecure_part="&insecure=1"
        read -p "$(random_color '请输入用于自签名证书的域名 (默认 bing.com): ')" domain_name
        domain_name=${domain_name:-"bing.com"}
        sni=$domain_name

        cert_path="$CONFIG_PATH/$domain_name.crt"
        key_path="$CONFIG_PATH/$domain_name.key"

        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$key_path" -out "$cert_path" -subj "/CN=$domain_name" -days 3650
        echo "$(random_color '自签名证书已生成。')"
    else
        read -p "$(random_color '请输入你的域名 (必须正确解析到本机IP): ')" domain_name
        while [ -z "$domain_name" ]; do
            read -p "$(random_color '域名不能为空, 请重新输入: ')" domain_name
        done
        sni=$domain_name
    fi

    read -p "$(random_color '请选择IP模式 (1. IPv4 | 2. IPv6) [默认 1]: ')" ip_choice
    ip_choice=${ip_choice:-1}

    if [ "$ip_choice" == "2" ]; then
        server_ip="[$(curl -s6 ip.sb)]"
        if [ "$server_ip" == "[]" ]; then
            echo "$(random_color '获取 IPv6 地址失败，请检查网络环境！')"
            exit 1
        fi
        echo "获取到 IPv6 地址: $server_ip"
    else
        server_ip=$(curl -s4 ip.sb)
        if [ -z "$server_ip" ]; then
            echo "$(random_color '获取 IPv4 地址失败，请检查网络环境！')"
            exit 1
        fi
        echo "获取到 IPv4 地址: $server_ip"
    fi

    # --- 生成配置文件 ---
    if [ "$self_signed" = true ]; then
        tls_config=$(cat <<EOF
        "tls": {
            "enabled": true,
            "certificate_path": "$cert_path",
            "key_path": "$key_path"
        }
EOF
)
    else
        tls_config=$(cat <<EOF
        "tls": {
            "enabled": true,
            "server_name": "$domain_name",
            "acme": {
                "domain_names": ["$domain_name"],
                "email": "abuse@$(echo $domain_name | cut -d'.' -f2-)",
                "provider": "letsencrypt"
            }
        }
EOF
)
    fi

    cat > "$CONFIG_FILE" <<EOF
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "hysteria2",
            "listen": "::",
            "listen_port": $server_port,
            "users": [
                {
                    "password": "$password"
                }
            ],
            $tls_config
        }
    ],
    "outbounds": [
        {
            "type": "direct"
        }
    ]
}
EOF
    echo "$(random_color 'sing-box 配置文件已生成。')"

    # --- 仅在 systemd 系统上创建和启动服务 ---
    if command -v systemctl &> /dev/null; then
        echo "$(random_color '正在配置 systemd 服务...')"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_PATH
ExecStart=$BINARY_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        echo "$(random_color 'systemd 服务文件已创建。')"

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl start sing-box
    else
        echo "$(random_color '非 systemd 系统，跳过服务创建。请手动运行以下命令来启动：')"
        echo "$(random_color "$BINARY_PATH run -c $CONFIG_FILE")"
    fi
    
    # --- 生成并显示分享链接 ---
    share_link="hysteria2://${password}@${server_ip}:${server_port}/?sni=${sni}${insecure_part}#Hy2-$(hostname)"
    echo "$share_link" > "$SHARE_LINK_FILE"
    
    echo "$(random_color '==================================================')"
    echo "$(random_color '          (ง ื▿ ื)ว 安装完成！          ')"
    echo "$(random_color '==================================================')"
    echo ""
    echo "$(random_color '这是你的 Hysteria2 节点链接，请注意保存：')"
    echo "$(random_color "$share_link")"
    echo ""
    echo "$(random_color '配置文件路径: ')" "$CONFIG_FILE"
    echo ""
    if command -v systemctl &> /dev/null; then
        echo "$(random_color '用 "bash '$0' menu" 指令可以再次唤出管理菜单哦！')"
    fi
}

# 管理菜单
show_menu() {
    if ! command -v systemctl &> /dev/null; then
        echo "非 systemd 系统不支持管理菜单。"
        exit 1
    fi
    echo "$(random_color '==================================================')"
    echo "$(random_color '      sing-box + Hysteria2 管理脚本      ')"
    echo "$(random_color '--------------------------------------------------')"
    echo "sing-box 状态: $(check_status)"
    echo ""
    echo " 1. 安装 sing-box (Hysteria2 模式)"
    echo " 2. 卸载 sing-box"
    echo " 3. 查看配置 / 分享链接"
    echo ""
    echo " 4. 启动 sing-box"
    echo " 5. 停止 sing-box"
    echo " 6. 重启 sing-box"
    echo " 7. 查看日志"
    echo ""
    echo " 0. 退出脚本"
    echo "$(random_color '==================================================')"
    
    read -p "选择一个操作, 小崽子(ง ื▿ ื)ว: " choice
    case $choice in
    1) install_singbox ;;
    2) uninstall_singbox ;;
    3) view_config ;;
    4) systemctl start sing-box && echo "$(random_color 'sing-box 已启动')" ;;
    5) systemctl stop sing-box && echo "$(random_color 'sing-box 已停止')" ;;
    6) systemctl restart sing-box && echo "$(random_color 'sing-box 已重启')" ;;
    7) journalctl -u sing-box -f --no-pager ;;
    0) exit 0 ;;
    *) echo "$(random_color '无效的选择，退出脚本。')" && exit 1 ;;
    esac
}


# --- 脚本主入口 ---
main() {
    clear
    echo -e "$(random_color '
    ░██████╗░░█████╗░███╗░░██╗░██████╗░░█████╗░░██╗░░░░░░██╗██████╗░
    ██╔════╝░██╔══██╗████╗░██║██╔════╝░██╔══██╗░██║░░██╗░██║██╔══██╗
    ╚█████╗░░██║░░██║██╔██╗██║██║░░██╗░███████║░╚██╗████╗██╔╝██████╔╝
    ░╚═══██╗░██║░░██║██║╚████║██║░░╚██╗██╔══██║░░████╔═████║░██╔══██╗
    ██████╔╝░╚█████╔╝██║░╚███║╚██████╔╝██║░░██║░░╚██╔╝░╚██╔╝░██║░░██║
    ╚═════╝░░░╚════╝░╚═╝░░╚══╝░╚═════╝░╚═╝░░╚═╝░░░╚═╝░░░╚═╝░░╚═╝░░╚═╝
    ')"
    echo ""

    check_os
    install_dependencies
    set_architecture
    check_systemd

    if [[ "$1" == "menu" ]]; then
        show_menu
    else
        install_singbox
    fi
}

main "$@"
