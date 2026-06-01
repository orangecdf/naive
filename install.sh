#!/usr/bin/env bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

naive_systemd_version="${1:-latest}"

init_var() {
  ECHO_TYPE="echo -e"
  package_manager=""
  release=""
  version=""
  get_arch=""

  NAIVE_DATA="/usr/local/naive/"
  NAIVE_CONFIGS="/usr/local/naive/configs/"
  NAIVE_HTML="/usr/local/naive/html/"

  naive_ssl_method=1
  naive_domain=""
  naive_email=""
  naive_ssl="acme"
  naive_crt=""
  naive_key=""

  naive_port=444
  naive_username="sysadmin"
  naive_password="sysadmin"
  naive_auth=""
}

echo_content() {
  case $1 in
  "red")    ${ECHO_TYPE} "\033[31m$2\033[0m" ;;
  "green")  ${ECHO_TYPE} "\033[32m$2\033[0m" ;;
  "yellow") ${ECHO_TYPE} "\033[33m$2\033[0m" ;;
  "blue")   ${ECHO_TYPE} "\033[34m$2\033[0m" ;;
  "skyBlue")${ECHO_TYPE} "\033[36m$2\033[0m" ;;
  "white")  ${ECHO_TYPE} "\033[37m$2\033[0m" ;;
  esac
}

can_connect() {
  if ping -c2 -i0.3 -W1 "$1" &>/dev/null; then return 0; else return 1; fi
}

version_ge() {
  local v1=${1#v}
  local v2=${2#v}
  if [[ -z "$v1" || "$v1" == "latest" ]]; then return 0; fi
  IFS='.' read -r -a v1_parts <<<"$v1"
  IFS='.' read -r -a v2_parts <<<"$v2"
  for i in "${!v1_parts[@]}"; do
    local part1=${v1_parts[i]:-0}
    local part2=${v2_parts[i]:-0}
    if [[ "$part1" < "$part2" ]]; then return 1
    elif [[ "$part1" > "$part2" ]]; then return 0
    fi
  done
  return 0
}

# 获取下一个可用节点 ID
next_node_id() {
  local id=1
  while [[ -f "${NAIVE_CONFIGS}naive-${id}.json" ]]; do
    ((id++))
  done
  echo "$id"
}

# 列出所有已安装节点
list_nodes() {
  local found=0
  for config in "${NAIVE_CONFIGS}"naive-*.json; do
    [[ -f "$config" ]] || continue
    found=1
    local id
    id=$(basename "$config" | grep -oP '\d+')
    local port user
    port=$(grep -oP '"listen":\s*\["\s*:\K\d+' "$config" | head -1)
    user=$(grep -oP '"auth_credentials":\s*\["\K[^"]+' "$config" | head -1)
    if [[ -z "$user" ]]; then
      user=$(grep -oP '"auth_user_deprecated":\s*"\K[^"]+' "$config" | head -1)
    fi
    local status
    if systemctl is-active "naive@${id}" &>/dev/null; then
      status="\033[32m运行中\033[0m"
    else
      status="\033[31m已停止\033[0m"
    fi
    echo_content white "  节点 #${id} | 端口: ${port} | 认证: ${user} | 状态: $(echo -e "$status")"
  done
  if [[ $found -eq 0 ]]; then
    echo_content yellow "  暂无已安装节点"
  fi
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "必须使用 root 运行此脚本"
    exit 1
  fi

  can_connect www.google.com
  if [[ "$?" == "1" ]]; then
    echo_content red "---> 网络连接失败（无法访问 google.com）"
    exit 1
  fi

  if [[ $(command -v yum) ]]; then
    package_manager='yum'
  elif [[ $(command -v dnf) ]]; then
    package_manager='dnf'
  elif [[ $(command -v apt-get) ]]; then
    package_manager='apt-get'
  elif [[ $(command -v apt) ]]; then
    package_manager='apt'
  fi

  if [[ -z "${package_manager}" ]]; then
    echo_content red "不支持当前系统"
    exit 1
  fi

  if [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    if rpm -q centos-stream-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-stream-release)
    elif rpm -q centos-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-release)
    fi
  elif grep </etc/issue -q -i "debian" && [[ -f "/etc/issue" ]]; then
    release="debian"
    version=$(cat /etc/debian_version)
  elif grep </etc/issue -q -i "ubuntu" && [[ -f "/etc/issue" ]]; then
    release="ubuntu"
    version=$(lsb_release -sr)
  fi

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "仅支持 x86_64/amd64 和 arm64/aarch64"
    exit 1
  fi
}

install_depend() {
  if [[ "${package_manager}" == 'apt-get' || "${package_manager}" == 'apt' ]]; then
    ${package_manager} update -y
  fi
  ${package_manager} install -y curl systemd nftables
}

# 安装 naive 二进制（仅首次）
install_binary() {
  if [[ -f "${NAIVE_DATA}naive" ]]; then
    echo_content skyBlue "---> naive 二进制已存在，跳过下载"
    return
  fi

  echo_content green "---> 下载 naive 二进制"
  mkdir -p "${NAIVE_DATA}"

  local bin_url="https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}"
  if [[ "latest" != "${naive_systemd_version}" ]]; then
    bin_url="https://github.com/jonssonyan/naive/releases/download/${naive_systemd_version}/naive-linux-${get_arch}"
  fi

  curl -fsSL "${bin_url}" -o "${NAIVE_DATA}naive" && chmod +x "${NAIVE_DATA}naive"
  echo_content skyBlue "---> naive 二进制下载完成"
}

# 安装 systemd template service（仅首次）
install_service_template() {
  if [[ -f "/etc/systemd/system/naive@.service" ]]; then
    return
  fi

  cat >/etc/systemd/system/naive@.service <<EOF
[Unit]
Description=NaiveProxy instance %i
After=network.target

[Service]
Type=simple
ExecStart=${NAIVE_DATA}naive run --config ${NAIVE_CONFIGS}naive-%i.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# 初始化 HTML 伪装页
init_html() {
  mkdir -p "${NAIVE_HTML}"
  if [[ ! -f "${NAIVE_HTML}index.html" ]]; then
    cat >"${NAIVE_HTML}index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title>
<style>html{color-scheme:light dark}body{width:35em;margin:0 auto;font-family:Tahoma,Verdana,Arial,sans-serif}</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and working.</p>
<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF
  fi
}

# 生成节点配置文件
generate_config() {
  local node_id="$1"
  local config_path="${NAIVE_CONFIGS}naive-${node_id}.json"
  mkdir -p "${NAIVE_CONFIGS}"

  if version_ge "${naive_systemd_version}" "v2.7.6"; then
    local auth_block="\"auth_credentials\": [\"${naive_auth}\"],"
  else
    local auth_block="\"auth_user_deprecated\": \"${naive_username}\",
                          \"auth_pass_deprecated\": \"${naive_password}\","
  fi

  if [[ "${naive_ssl_method}" == "1" ]]; then
    # 自动证书
    cat >"${config_path}" <<EOF
{
  "admin": {"disabled": true},
  "logging": {
    "sink": {"writer": {"output": "stderr"}},
    "logs": {"default": {"writer": {"output": "stderr"}}}
  },
  "storage": {"module": "file_system", "root": "${NAIVE_DATA}file_system/"},
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":${naive_port}"],
          "routes": [{
            "handle": [{
              "handler": "subroute",
              "routes": [
                {
                  "handle": [{
                    ${auth_block}
                    "handler": "forward_proxy",
                    "hide_ip": true,
                    "hide_via": true,
                    "probe_resistance": {}
                  }]
                },
                {
                  "match": [{"host": ["${naive_domain}"]}],
                  "handle": [{
                    "handler": "file_server",
                    "root": "${NAIVE_HTML}",
                    "index_names": ["index.html", "index.htm"]
                  }],
                  "terminal": true
                }
              ]
            }]
          }],
          "tls_connection_policies": [{"match": {"sni": ["${naive_domain}"]}}],
          "automatic_https": {"disable": true}
        }
      }
    },
    "tls": {
      "certificates": {"automate": ["${naive_domain}"]},
      "automation": {
        "policies": [{
          "issuers": [{"module": "${naive_ssl}", "email": "${naive_email}"}]
        }]
      }
    }
  }
}
EOF
  else
    # 自定义证书
    cat >"${config_path}" <<EOF
{
  "admin": {"disabled": true},
  "logging": {
    "sink": {"writer": {"output": "stderr"}},
    "logs": {"default": {"writer": {"output": "stderr"}}}
  },
  "storage": {"module": "file_system", "root": "${NAIVE_DATA}file_system/"},
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":${naive_port}"],
          "routes": [{
            "handle": [{
              "handler": "subroute",
              "routes": [
                {
                  "handle": [{
                    ${auth_block}
                    "handler": "forward_proxy",
                    "hide_ip": true,
                    "hide_via": true,
                    "probe_resistance": {}
                  }]
                },
                {
                  "match": [{"host": ["${naive_domain}"]}],
                  "handle": [{
                    "handler": "file_server",
                    "root": "${NAIVE_HTML}",
                    "index_names": ["index.html", "index.htm"]
                  }],
                  "terminal": true
                }
              ]
            }]
          }],
          "tls_connection_policies": [{"match": {"sni": ["${naive_domain}"]}}],
          "automatic_https": {"disable": true}
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [{"certificate": "${naive_crt}", "key": "${naive_key}"}]
      }
    }
  }
}
EOF
  fi
}

# 收集节点参数
prompt_node_params() {
  while read -r -p "请输入端口 (默认 444): " naive_port; do
    [[ -z "${naive_port}" ]] && naive_port="444"
    # 检查端口是否被占用
    if ss -tlnp | grep -q ":${naive_port} "; then
      echo_content red "端口 ${naive_port} 已被占用，请换一个"
    else
      break
    fi
  done

  read -r -p "请输入用户名 (默认 sysadmin): " naive_username
  [[ -z "${naive_username}" ]] && naive_username="sysadmin"

  read -r -p "请输入密码 (默认 sysadmin): " naive_password
  [[ -z "${naive_password}" ]] && naive_password="sysadmin"

  naive_auth=$(echo -n "${naive_username}:${naive_password}" | base64 | tr --delete '\n' | base64)

  while read -r -p "证书方式 (1/自动申请  2/自定义路径，默认 1): " naive_ssl_method; do
    if [[ -z "${naive_ssl_method}" || "${naive_ssl_method}" == "1" ]]; then
      naive_ssl_method=1
      echo_content yellow "提示：请确认域名已解析到本机"
      while read -r -p "请输入域名 (必填): " naive_domain; do
        [[ -n "${naive_domain}" ]] && break
        echo_content red "域名不能为空"
      done
      read -r -p "请输入邮箱 (可选): " naive_email
      while read -r -p "证书来源 (1/acme  2/zerossl，默认 1): " naive_ssl_type; do
        if [[ -z "${naive_ssl_type}" || "${naive_ssl_type}" == "1" ]]; then
          naive_ssl="acme"; break
        elif [[ "${naive_ssl_type}" == "2" ]]; then
          naive_ssl="zerossl"; break
        else
          echo_content red "只能输入 1 或 2"
        fi
      done
      break
    elif [[ "${naive_ssl_method}" == "2" ]]; then
      naive_ssl_method=2
      while read -r -p "请输入域名 (必填): " naive_domain; do
        [[ -n "${naive_domain}" ]] && break
        echo_content red "域名不能为空"
      done
      while read -r -p "请输入 crt 证书路径 (必填): " naive_crt; do
        [[ -n "${naive_crt}" ]] && break
        echo_content red "路径不能为空"
      done
      while read -r -p "请输入 key 私钥路径 (必填): " naive_key; do
        [[ -n "${naive_key}" ]] && break
        echo_content red "路径不能为空"
      done
      break
    else
      echo_content red "只能输入 1 或 2"
    fi
  done
}

# 添加一个新节点
add_node() {
  install_binary
  install_service_template
  init_html

  local node_id
  node_id=$(next_node_id)

  echo_content green "---> 添加节点 #${node_id}"
  prompt_node_params
  generate_config "${node_id}"

  systemctl enable "naive@${node_id}" && systemctl restart "naive@${node_id}"
  echo_content skyBlue "---> 节点 #${node_id} 添加成功！端口: ${naive_port} | 用户名: ${naive_username}"
}

# 删除指定节点
remove_node() {
  echo_content white "当前节点列表："
  list_nodes
  echo ""
  read -r -p "请输入要删除的节点编号: " node_id
  if [[ -z "${node_id}" ]]; then
    echo_content red "编号不能为空"
    return
  fi
  if [[ ! -f "${NAIVE_CONFIGS}naive-${node_id}.json" ]]; then
    echo_content red "节点 #${node_id} 不存在"
    return
  fi

  systemctl stop "naive@${node_id}" 2>/dev/null
  systemctl disable "naive@${node_id}" 2>/dev/null
  rm -f "${NAIVE_CONFIGS}naive-${node_id}.json"
  echo_content skyBlue "---> 节点 #${node_id} 已删除"
}

# 升级 naive 二进制
upgrade_naive() {
  if [[ ! -f "${NAIVE_DATA}naive" ]]; then
    echo_content red "---> naive 未安装"
    return
  fi

  local latest_version
  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/naive/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  local current_version
  current_version=$("${NAIVE_DATA}naive" version | awk '{print $1}')

  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> 已是最新版本 ${current_version}"
    return
  fi

  echo_content green "---> 升级 naive: ${current_version} -> ${latest_version}"

  # 停止所有节点
  for config in "${NAIVE_CONFIGS}"naive-*.json; do
    [[ -f "$config" ]] || continue
    local id
    id=$(basename "$config" | grep -oP '\d+')
    systemctl stop "naive@${id}" 2>/dev/null
  done

  curl -fsSL "https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-${get_arch}" \
    -o "${NAIVE_DATA}naive" && chmod +x "${NAIVE_DATA}naive"

  # 重启所有节点
  for config in "${NAIVE_CONFIGS}"naive-*.json; do
    [[ -f "$config" ]] || continue
    local id
    id=$(basename "$config" | grep -oP '\d+')
    systemctl restart "naive@${id}"
  done

  echo_content skyBlue "---> 升级完成"
}

# 卸载全部
uninstall_all() {
  read -r -p "确认卸载所有节点？(y/N): " confirm
  [[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && return

  for config in "${NAIVE_CONFIGS}"naive-*.json; do
    [[ -f "$config" ]] || continue
    local id
    id=$(basename "$config" | grep -oP '\d+')
    systemctl stop "naive@${id}" 2>/dev/null
    systemctl disable "naive@${id}" 2>/dev/null
  done

  rm -f /etc/systemd/system/naive@.service
  systemctl daemon-reload
  systemctl reset-failed
  rm -rf "${NAIVE_DATA}"
  echo_content skyBlue "---> 已卸载全部 naive"
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  clear

  while true; do
    echo_content red "\n=============================================================="
    echo_content skyBlue "  NaiveProxy 多节点管理脚本"
    echo_content skyBlue "  当前节点："
    list_nodes
    echo_content red "=============================================================="
    echo_content yellow "1. 添加节点"
    echo_content yellow "2. 删除节点"
    echo_content yellow "3. 查看节点状态"
    echo_content yellow "4. 升级 naive 二进制"
    echo_content yellow "5. 卸载全部"
    echo_content yellow "0. 退出"
    echo_content red "=============================================================="
    read -r -p "请选择: " input_option
    case ${input_option} in
    1) add_node ;;
    2) remove_node ;;
    3)
      echo_content white "详细状态："
      for config in "${NAIVE_CONFIGS}"naive-*.json; do
        [[ -f "$config" ]] || continue
        id=$(basename "$config" | grep -oP '\d+')
        echo_content skyBlue "--- 节点 #${id} ---"
        systemctl status "naive@${id}" --no-pager -l | tail -10
      done
      ;;
    4) upgrade_naive ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) echo_content red "无效选项" ;;
    esac
  done
}

main
