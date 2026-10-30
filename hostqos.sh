#!/usr/bin/env bash
# ============================================================
#  HostQoS — VPS 主机评测脚本
#
#  • 精简/完整/极小(--tiny)三模式,浅色信息图单页 HTML 报告(卡片式)
#  • 原型四行卡片:综合评测(半圆仪表+四分项)/服务器基本信息/三网单线程表/
#    国际多区域单线程测速/IPv4+IPv6 回程质量环形图/大小包矩阵/
#    IP 风险评分 8 项/流媒体·社交·AI 解锁三组/邮件端口连通
#  • 每卡带 ? 悬浮提示(点击可用);商家/机房自动识别;三网线路识别
#  • 可选上传自建服务端(hostqos.com)生成在线报告,便于检索与分享
#  • 零广告;默认不落盘(--report 才本地保存报告),不安装任何软件包,
#    兼容 Alpine 等 BusyBox 系统(自动引导到已有 bash)
#
#  用法:
#    bash hostqos.sh            # 完整模式(默认,全部检测)
#    bash hostqos.sh -s         # 精简模式(关键数据)
#    bash hostqos.sh --tiny     # 极小模式(128MB 内存/1GB 磁盘级小机)
#    bash hostqos.sh -h         # 全部参数
#
#  依赖: bash 4+、curl;其余工具(测速/路由)按需下载,测完即清
# ============================================================

# ---- POSIX 引导:被 sh/ash 执行时自动切换到 bash(Alpine 等场景) ----
if [ -z "${BASH_VERSION:-}" ]; then
    for _hq_b in bash /bin/bash /usr/bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash; do
        if command -v "$_hq_b" >/dev/null 2>&1; then
            exec "$_hq_b" "$0" "$@"
        fi
    done
    # 本脚本不调用包管理器安装任何软件包,缺失时仅提示手动安装
    echo "[hostqos] 错误: 本脚本需要 bash 4.0+。请先安装:"
    echo "    Alpine: apk add bash    Debian/Ubuntu: apt install bash    RHEL: yum install bash"
    exit 1
fi

set -uo pipefail
umask 022
export LC_NUMERIC=C

# 误用防护:curl | bash -a 时 -a 被 bash 吃掉(allexport),所有变量(含巨型网页内容)
# 被导出为环境变量,后续外部命令会连环报 "Argument list too long"。检测到即关闭,
# 且参数为空时按用户意图切换完整模式。
_HQ_ALLEXPORT=0
if [[ $- == *a* ]]; then
    set +a
    _HQ_ALLEXPORT=1
fi
_HQ_ARGS_N=$#

HQ_VERSION="2.8.2"
HQ_START_TS=$(date +%s)
HQ_START_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
HQ_UA="HostQoS/${HQ_VERSION} (VPS benchmark)"

# ---------------- 全局结果存储 ----------------
# 标量统一放 G 关联数组,表格类数据放普通数组(每行用 | 分隔)
declare -A G=()
SPEED_ROWS=()      # 名称|下行Mbps|上行Mbps|备注
PING_ROWS=()       # 名称|IP|平均延迟ms|丢包率%|抖动ms|逐包RTT(csv)
TCP_ROWS=()        # 名称|IP|平均握手ms|失败率%  (TCP 443 探测)
TCP6_ROWS=()       # 名称|IP|平均握手ms|失败率%  (IPv6 TCP 443 探测,回程质量 v6 卡用)
MEDIA_ROWS=()      # 服务|状态(yes/no/orig/fail)|地区
IPQ_ROWS=()        # 项目|结果|评级(good/warn/bad/na)
MTU_ROWS=()        # 方向|最大包|评级
V6TOS_ROWS=()      # isp|下行Mbps|上行Mbps(TOS 区域端点 IPv6 直连测速)
INTL_ROWS=()       # 目标|状态|延迟ms|评级
CDN_ROWS=()        # CDN名|显示|耗时s|等级
PROV_ROWS=()       # 省份|电信ms|联通ms|移动ms (丢包→"x%"红)
FIO_ROWS=()        # 块大小|读MB/s|写MB/s|读IOPS|写IOPS
DNSBL_ROWS=()     # 黑名单|命中与否
PKT_ROWS=()       # 族(v4/v6)|包长标签|平均延迟ms|丢包%|评价 (原型大小包子表)
MAIL_ROWS=()      # 协议|端口|出站(ok/blocked/na)|入站(恒na)|状态(ok/partial/blocked)
INTLSPD_ROWS=()   # 区域|状态(优/良好/一般/待检测)|下行Mbps|上行Mbps|rtt最小|rtt均值|重传%
CNMTX_ROWS=()     # 运营商|回程线路|下行|上行|延迟|丢包|重传|评价 (原型三网卡)
V6LINE_ROWS=()    # 运营商|IPv6 回程线路标签(mod_route -6 traceroute 识别)
ROUTE_TARGETS=()   # 目标名|IP|线路标签|ASN集合
declare -A ROUTE_HOPS=()   # 目标名 -> "跳数. IP|ASN|组织" 多行串

HQ_TMP=""          # 临时工作目录(退出时清理)
HQ_BIN=""          # 下载的二进制目录
HQ_TDISK=""        # 磁盘测速降级目录(/tmp 为 tmpfs 时建在 $PWD,cleanup 兜底删除)
HQ_HOME=""          # 运行内缓存目录(preflight 指到临时目录内,退出即清,不在 HOME 留痕)

# ---------------- 模块开关(默认值,CLI 可改) ----------------
HQ_MODE="full"            # full(默认完整) | simple(精简) | tiny(极小)
OPT_PROVIDER=""
OPT_TAG=""
OPT_PLAN_BW=""       # 标称带宽(--plan-bandwidth)
OPT_PLAN_TRF=""      # 月流量额度(--plan-traffic)
OPT_OUTDIR="hostqos"
OPT_REPORT=0        # 默认不落盘:--report 或 -o 时才本地保存 HTML/JSON 报告
OPT_LANG="cn"
OPT_IPV="4 6"             # 默认双栈,实际按可用性自动降级
OPT_MIRROR=""
OPT_LOW_TRAFFIC=0
OPT_KEEP=0
OPT_JSON=0
OPT_GB=0
OPT_COLOR=1
OPT_LOWRES=0        # 低资源模式:内存余量不足时自动开启(preflight 检测)
OPT_SERVER="https://hostqos.com"
OPT_UPLOAD=1
OPT_TOKEN="${HQ_TOKEN:-}"
declare -A MOD_ON=( [cpu]=1 [disk]=1 [ping]=1 [tcpmtu]=1 [speed]=1 [intl]=1 [ipq]=1 [media]=1 [mail]=1 [route]=1 )
# ============================================================
# 工具函数
# ============================================================
HQ_IS_TTY=0
[ -t 1 ] && HQ_IS_TTY=1

C_OFF='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
if [ "$HQ_IS_TTY" = 1 ] && [ "$OPT_COLOR" = 1 ]; then
    C_OFF=$'\033[0m'    C_BOLD=$'\033[1m'   C_DIM=$'\033[2m'
    C_RED=$'\033[31m'   C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
fi

# L <key>: 取当前语言文案。LANG_TEXT 在各模块中按需补充
declare -A LANG_TEXT=()
L() {
    local key=$1 def=${2:-}
    local v=${LANG_TEXT[${OPT_LANG}:$key]-}
    printf '%s' "${v:-$def}"
}

line() { printf '%s\n' "----------------------------------------"; }
sec()  { printf '\n%s[ %s ]%s\n' "${C_CYAN}${C_BOLD}" "$*" "${C_OFF}"; }
kv()   { printf '  %s%-26s%s %s\n' "$C_DIM" "$1" "$C_OFF" "$2"; }
note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '  %s[!]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
err()  { printf '  %s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }

# HTML / JSON 转义
esc() {
    local s=${1//&/&amp;}
    s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}
    printf '%s' "$s"
}
jesc() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/}
    printf '%s' "$s"
}

is_num() { [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# jfield <json> <a.b.c> : 取标量字段(有 jq 用 jq,否则正则回退)
jfield() {
    local json=$1 path=$2 leaf=${2##*.} v=""
    if command -v jq >/dev/null 2>&1; then
        v=$(printf '%s' "$json" | jq -r "getpath( \"$path\" | split(\".\") ) | if . == null then empty elif (type == \"string\" or type == \"number\" or type == \"boolean\") then tostring else empty end" 2>/dev/null)
        [ -n "$v" ] && { printf '%s' "$v"; return; }
    fi
    v=$(printf '%s' "$json" | grep -oE "\"${leaf}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[-+0-9.eE]+|true|false|null)" | head -n1 \
        | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//')
    printf '%s' "$v"
}

# hq_curl <url> [maxtime] [额外curl参数...]
hq_curl() {
    local url=$1; shift
    local mt=15
    if [ $# -ge 1 ] && [[ $1 =~ ^[0-9]+$ ]]; then mt=$1; shift; fi
    curl -fsSL --connect-timeout 5 --max-time "$mt" -A "$HQ_UA" "$@" "$url" 2>/dev/null
}

# hq_download <url> <输出文件> : 直连优先,--mirror 时镜像优先
hq_download() {
    local url=$1 out=$2 try_u
    local -a urls=()
    case "$OPT_MIRROR" in
        "") urls=("$url" "https://ghfast.top/${url}" "https://gh-proxy.com/${url}") ;;
        *)  urls=("${OPT_MIRROR}${url}" "$url") ;;
    esac
    for try_u in "${urls[@]}"; do
        if curl -fSL --connect-timeout 8 --max-time 600 -A "$HQ_UA" -o "$out" "$try_u" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
        rm -f "$out" 2>/dev/null
    done
    return 1
}

# GitHub latest release 资产直链: gh_asset_url <owner/repo> <资产名正则>
gh_asset_url() {
    local repo=$1 pat=$2
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local json _try
    for _try in 1 2; do
        json=$(hq_curl "$api" 12) || { sleep 2; continue; }
        local url
        url=$(printf '%s' "$json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\(https[^"]*\)"/\1/' | grep -E "$pat" | head -n1)
        [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    done
    return 1
}

fmt_mbps() {  # Mbps 数值 -> 自适应字符串
    local v=$1
    is_num "$v" || { printf '%s' "-"; return; }
    awk -v v="$v" 'BEGIN{
        if (v >= 1000)      printf "%.2f Gbps", v/1000;
        else if (v >= 100)  printf "%.1f Mbps", v;
        else if (v >= 10)   printf "%.2f Mbps", v;
        else                printf "%.3f Mbps", v;
    }'
}
fmt_mb() {    # MB/s 数值 -> 自适应字符串
    local v=$1
    is_num "$v" || { printf '%s' "-"; return; }
    awk -v v="$v" 'BEGIN{
        if (v >= 1024) printf "%.2f GB/s", v/1024;
        else           printf "%.1f MB/s", v;
    }'
}
fmt_ms() {
    local v=$1
    is_num "$v" || { printf '%s' "-"; return; }
    awk -v v="$v" 'BEGIN{ printf "%.1f ms", v }'
}

ip_is_v4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
ip_is_v6() { [[ $1 =~ : ]]; }

# 超时包装:有 timeout 命令用之,否则直接执行
with_timeout() {
    local t=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$t" "$@"
    else
        "$@"
    fi
}

# TCP 端口连通:单进程 curl telnet 握手计时(替代 timeout+bash+/dev/tcp 的三进程方案)。
# 小 PID 限额容器(Alpine/LXC)fork 密集时会触发 "fork: retry" 指数退避(每次失败约 31s),
# 单进程探测把每项 fork 数降到 1,是防卡死的关键;curl 支持 telnet:// 与 -w 计时,零 bash 依赖
tcp_port_open() { # <host> <port> [超时秒,默认5] -> 返回0=可连通
    local t=${3:-5} tc
    tc=$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout "$t" --max-time $((t + 2)) \
        "telnet://$1:$2" </dev/null 2>/dev/null)
    is_num "$tc" && awk -v t="$tc" 'BEGIN{exit !(t>0.001)}'
}

cleanup() {
    local rc=$?
    if [ "$OPT_KEEP" = 1 ] && [ -n "$HQ_TMP" ]; then
        note "保留临时目录: $HQ_TMP (--keep)"
    else
        [ -n "$HQ_TMP" ] && rm -rf "$HQ_TMP" 2>/dev/null
    fi
    # 兜底:中途被打断时补删工作目录里的磁盘测速降级目录与共享内存测试文件(均为本脚本创建)
    [ -n "$HQ_TDISK" ] && rm -rf "$HQ_TDISK" 2>/dev/null
    rm -f "/dev/shm/hq_memtest.$$" 2>/dev/null
    return $rc
}
# ============================================================
# CLI 解析与预检
# ============================================================
usage() {
    cat <<'USAGE'
HostQoS — 主机评测脚本 (极客风报告 / 商家自动识别 / 在线汇总)

用法: bash hostqos.sh [模式] [选项]

模式(默认完整):
  (无参数)             完整模式:系统+商家+性能+磁盘 fio、逐跳路由、DNSBL、25端口、
                       更多测速节点与更长基准,单页报告
  -s, --simple         精简模式:系统+商家+性能快测+测速+IP质量+解锁+三网线路,
                       跳过重模块,更快出报告
  --tiny               极小模式:适配 128MB 内存 / 1GB 磁盘的小机器
                       (CPU 快测 5s、磁盘只写 48MB、纯 curl 测速不下载二进制;
                       大小包 ICMP 检测与国际互联检测仍默认开启,--route 可补线路)

通用选项:
  -p, --provider <s>   手动指定商家/产品(如 "搬瓦工|CN2 GIA"),覆盖自动识别
  -t, --tag <s>        主机备注标签(显示在报告头部与索引)
  --plan-bandwidth <s> 标称带宽(如 "2Gbps";显示在"服务器基本信息",并附实测对照)
  --plan-traffic <s>   月流量额度(如 "2000GB/月";不填则如实显示"报告未提供")
  --report             本地保存 HTML 报告(默认 ./hostqos,-o 可改目录);
                       默认不落盘,仅终端摘要+在线报告链接,不留任何文件
  -o, --html <dir>     报告输出目录(默认 ./hostqos;隐含 --report)
  -4 / -6              仅测试 IPv4 / IPv6
  -E, --lang en        英文输出(默认中文)
  --route              强制启用回程线路检测(任意模式,含 --tiny)
  --skip  <a,b,c>      跳过模块: cpu,disk,ping,tcpmtu,speed,intl,ipq,media,mail,route
  --only <a,b,c>       仅运行指定模块
  --mirror [url]       二进制下载走 GitHub 镜像(默认 ghfast.top,可指定前缀)
  --low-traffic        减半测速时长(省流量)
  --low-mem            强制低资源模式(CPU 快测、跳过 speedtest-go/内存带宽、
                       磁盘文件减半;内存可用 <700MB 时自动启用)
  --json               输出全量 JSON(配合 --report 写入报告目录,单独使用打印到 stdout)
  --server <url>       在线报告站点地址(默认 https://hostqos.com)
  --no-upload          完全离线模式,不上传在线报告(配合 --report 则仅本地保存)
  --token <s>          站点访问令牌(若站点启用鉴权;也可用环境变量 HQ_TOKEN)
  --no-color           关闭终端彩色
  --keep               保留临时文件(调试)
  --gb                (已弃用)Geekbench 已移除;传入仅提示并按完整模式运行
  -h, --help           本帮助

兼容性: Alpine/BusyBox 系统可直接 sh 运行,脚本自动切换到已有 bash(缺失时仅提示安装);
       本脚本不安装任何软件包,退出即清理全部临时文件,不改系统配置;
       128MB 内存小机建议 --tiny;1GB 磁盘请确保 ≥80MB 可用空间;
       内存可用 <700MB 时自动进入低资源模式(CPU 快测、跳过 speedtest-go
       下载与内存带宽测试、磁盘测试文件减半),避免影响同机生产服务

示例:
  bash hostqos.sh -t "香港中转机"
  bash hostqos.sh -s -p "RackNerd|2C2G 年付" --skip media
  bash hostqos.sh --only speed,ipq -4 --no-upload
USAGE
}

parse_cli() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--full)       note "完整模式已是默认,-a/--full 可省略"; HQ_MODE="full"; MOD_ON[route]=1; shift ;;
            -s|--simple)     HQ_MODE="simple"; shift ;;
            --tiny)          HQ_MODE="tiny"; MOD_ON[route]=0; shift ;;
            --route)         MOD_ON[route]=1; shift ;;
            -p|--provider)   OPT_PROVIDER=${2:?"--provider 需要参数"}; shift 2 ;;
            -t|--tag)        OPT_TAG=${2:?"--tag 需要参数"}; shift 2 ;;
            --plan-bandwidth) OPT_PLAN_BW=${2:?"--plan-bandwidth 需要参数"}; shift 2 ;;
            --plan-traffic)   OPT_PLAN_TRF=${2:?"--plan-traffic 需要参数"}; shift 2 ;;
            -o|--html)       OPT_OUTDIR=${2:?"--html 需要参数"}; OPT_REPORT=1; shift 2 ;;
            --report)        OPT_REPORT=1; shift ;;
            -E|--lang)
                if [ $# -ge 2 ] && [[ $2 != -* ]]; then OPT_LANG=$2; shift 2
                else OPT_LANG=en; shift; fi ;;
            -4)              OPT_IPV="4"; shift ;;
            -6)              OPT_IPV="6"; shift ;;
            --skip)
                local m=${2:?"--skip 需要模块列表"}; shift 2
                local _sk _m
                IFS=',' read -ra _sk <<< "$m"
                for _m in "${_sk[@]}"; do
                    case $_m in cpu|disk|ping|tcpmtu|speed|intl|ipq|media|mail|route) MOD_ON[$_m]=0 ;; *) err "未知模块: $_m" ;; esac
                done ;;
            --only)
                local m=${2:?"--only 需要模块列表"}; shift 2
                local _on _m
                for _m in cpu disk ping tcpmtu speed intl ipq media mail route; do MOD_ON[$_m]=0; done
                IFS=',' read -ra _on <<< "$m"
                for _m in "${_on[@]}"; do
                    case $_m in cpu|disk|ping|tcpmtu|speed|intl|ipq|media|mail|route) MOD_ON[$_m]=1 ;; *) err "未知模块: $_m" ;; esac
                done ;;
            --mirror)
                if [ $# -ge 2 ] && [[ $2 != -* ]]; then OPT_MIRROR=$2; shift 2
                else OPT_MIRROR="https://ghfast.top/"; shift; fi ;;
            --low-traffic)   OPT_LOW_TRAFFIC=1; shift ;;
            --low-mem)       OPT_LOWRES=1; shift ;;
            --gb)            OPT_GB=1; HQ_MODE="full"; MOD_ON[route]=1; shift ;;
            --json)          OPT_JSON=1; shift ;;
            --server)        OPT_SERVER=${2:?"--server 需要参数"}; shift 2 ;;
            --no-upload)     OPT_UPLOAD=0; shift ;;
            --token)         OPT_TOKEN=${2:?"--token 需要参数"}; shift 2 ;;
            --no-color)      OPT_COLOR=0; shift ;;
            --keep)          OPT_KEEP=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               err "未知参数: $1(查看 -h)"; exit 1 ;;
        esac
    done
}

init_lang() {
    LANG_TEXT=(
        [cn:sys]="系统信息"        [en:sys]="System"
        [cn:provider]="商家识别"    [en:provider]="Provider"
        [cn:cpu]="CPU 性能"         [en:cpu]="CPU"
        [cn:disk]="磁盘性能"        [en:disk]="Disk"
        [cn:ping]="网络延迟"        [en:ping]="Latency"
        [cn:speed]="带宽测速"       [en:speed]="Speedtest"
        [cn:ipq]="IP 质量"          [en:ipq]="IP Quality"
        [cn:media]="流媒体/社交/AI 解锁" [en:media]="Streaming/Social/AI"
        [cn:route]="回程路由"       [en:route]="Route"
        [cn:mail]="邮件端口连通"    [en:mail]="Mail Ports"
        [cn:tcpmtu]="大小包检测"     [en:tcpmtu]="Packet Size"
        [cn:intl]="国际互联"         [en:intl]="International"
        [cn:intl_tcp_note]="延迟为纯 TCP 握手耗时(已剔除 DNS 解析),两次探测取最小,可与 ping 对照" [en:intl_tcp_note]="Latency = pure TCP handshake (DNS excluded), min of 2 probes"
        [cn:isp]="运营商" [en:isp]="ISP"          [cn:lat]="延迟" [en:lat]="Latency"
        [cn:loss]="丢包" [en:loss]="Loss"          [cn:pkt]="包" [en:pkt]="Packet"
        [cn:tcpbig]="TCP大包" [en:tcpbig]="TCP-1200B"  [cn:avg]="均值" [en:avg]="Avg"
        [cn:intl_site]="目标" [en:intl_site]="Target"
        [cn:mode_s]="精简模式" [en:mode_s]="Simple"  [cn:mode_f]="完整模式" [en:mode_f]="Full"
        [cn:mode_t]="极小模式" [en:mode_t]="Tiny"
        [cn:loc]="位置" [en:loc]="Location"  [cn:fraud]="欺诈分" [en:fraud]="Fraud"
        [cn:timek]="时间" [en:timek]="Time"
        [cn:routeline]="回程线路" [en:routeline]="Route Lines"
        [cn:undet]="未检测" [en:undet]="Not tested"
        [cn:undet_hint]="(可用 --only 指定重跑)" [en:undet_hint]="(rerun with --only)"
        [cn:net_p]="网络" [en:net_p]="Network"
        [cn:latcn_p]="延迟(大陆) · 大小包" [en:latcn_p]="CN Latency / Packet"
        [cn:latintl_p]="延迟(国际)" [en:latintl_p]="Intl Latency"
        [cn:disk_p]="磁盘" [en:disk_p]="Disk"  [cn:ipq_p]="IP 质量" [en:ipq_p]="IP Quality"
        [cn:intl_p]="国际互联" [en:intl_p]="International"  [cn:media_p]="解锁" [en:media_p]="Unlocks"
        [cn:single]="单核" [en:single]="Single"  [cn:multi]="多核" [en:multi]="Multi"
        [cn:ratio]="加速比" [en:ratio]="Ratio"   [cn:model]="型号" [en:model]="Model"
        [cn:down]="下行" [en:down]="Down"  [cn:up]="上行" [en:up]="Up"
        [cn:cdn]="国际CDN" [en:cdn]="Intl CDN"  [cn:node]="节点" [en:node]="Node"
        [cn:near]="就近" [en:near]="Nearest"
        [cn:d4k]="4K写" [en:d4k]="4K W"  [cn:dw]="顺序写" [en:dw]="Seq W"  [cn:dr]="顺序读" [en:dr]="Seq R"
        [cn:cap]="容量" [en:cap]="Size"
        [cn:type]="类型" [en:type]="Type"  [cn:native]="原生" [en:native]="Native"
        [cn:bcast]="广播/国际" [en:bcast]="Broadcast"
        [cn:proxyk]="代理标记" [en:proxyk]="Proxy"  [cn:dcip]="机房IP" [en:dcip]="Datacenter"
        [cn:yes2]="是" [en:yes2]="Yes"  [cn:no2]="否" [en:no2]="No"
        [cn:merch]="商家" [en:merch]="Provider"  [cn:linek]="线路" [en:linek]="Line"
        [cn:cpus]="CPU" [en:cpus]="CPU"  [cn:diskk]="磁盘" [en:diskk]="Disk"
        [cn:bw]="带宽" [en:bw]="Bandwidth"  [cn:cnlat]="大陆延迟" [en:cnlat]="CN Lat"
        [cn:mtuk]="大小包" [en:mtuk]="Packet"  [cn:intlcon]="国际互联" [en:intlcon]="Intl"
        [cn:durk]="耗时" [en:durk]="Duration"
        [cn:untested]="未检测" [en:untested]="Not tested"
        [cn:isp_ct]="电信" [en:isp_ct]="CT"  [cn:isp_cu]="联通" [en:isp_cu]="CU"  [cn:isp_cm]="移动" [en:isp_cm]="CM"
        [cn:foot_gen]="报告本地生成 · 除公共 IP 情报 API 与测速节点外无第三方交互" [en:foot_gen]="Report generated locally · No 3rd-party except public IP APIs & speedtest nodes"
        [cn:mtu_p]="大包(大陆)" [en:mtu_p]="Large Pkt (CN)"
        [cn:virt]="虚拟化" [en:virt]="Virt"  [cn:mem]="内存" [en:mem]="RAM"  [cn:osshort]="系统" [en:osshort]="OS"
        [cn:foot_opt]="可选在线报告" [en:foot_opt]="optional online report"
        [cn:report]="测试报告"      [en:report]="Report"
        [cn:yes]="支持"             [en:yes]="Yes"
        [cn:no]="不支持"            [en:no]="No"
        [cn:orig]="仅自制"          [en:orig]="Originals Only"
        [cn:fail]="检测失败"        [en:fail]="Failed"
        [cn:jitk]="抖动"            [en:jitk]="Jitter"
        [cn:failr]="失败"           [en:failr]="Fail"
        [cn:cn_avg]="大陆方向延迟"   [en:cn_avg]="CN Latency"   [cn:median]="中位数" [en:median]="median"
        [cn:cn_jit]="大陆平均抖动"   [en:cn_jit]="CN Jitter Avg"
        [cn:tcp_avg]="大陆TCP握手均值" [en:tcp_avg]="CN TCP Handshake"
        [cn:nodes]="节点"           [en:nodes]="nodes"
        [cn:dirs]="方向"            [en:dirs]="dirs"
        [cn:dnsc]="DNS 解析"        [en:dnsc]="DNS Resolve"
        [cn:dns_ok]="正常(与 DoH 一致)" [en:dns_ok]="OK (matches DoH)"
        [cn:dns_bad]="疑似劫持"      [en:dns_bad]="Possible hijack"
        [cn:dns_bad2]="疑似污染"     [en:dns_bad2]="Possible pollution"
        [cn:dns_fail2]="系统解析失败(疑似阻断)" [en:dns_fail2]="System resolve failed (blocked?)"
        [cn:dns_unk]="DoH 不可达,无法比对" [en:dns_unk]="DoH unreachable, no comparison"
        [cn:retr]="重传"            [en:retr]="retrans"
        [cn:gradek]="评分"          [en:gradek]="Score"
        [cn:membw]="内存带宽"        [en:membw]="Mem BW"
        [cn:on]="开启"              [en:on]="on"
        [cn:off]="未开启"           [en:off]="off"
        [cn:usage]="用途"           [en:usage]="Usage"
        [cn:pct_note]="历史对比:本次总分超过" [en:pct_note]="History: total score beats"
        [cn:intlspd_note]="国际区域单线程测速(每区域单连接 5s + 重传采样;上传无公共端点,如实标待检测)" [en:intlspd_note]="Regional single-thread speedtest (5s per region + retrans sampling)"
        [cn:mail_ok]="出站 ✓ 通" [en:mail_ok]="outbound OK"
        [cn:mail_bl]="出站 ✗ 阻断" [en:mail_bl]="outbound BLOCKED"
        [cn:mail_sum]="出站连通" [en:mail_sum]="Outbound"
        [cn:mail_note]="通;入站无法自测,如实标待检测" [en:mail_note]="OK; inbound not self-testable"
        [cn:prov6]="IPv6 测点零丢包" [en:prov6]="IPv6 probes zero-loss"
        [cn:mail_in_ok]="入站 ✓ 通" [en:mail_in_ok]="inbound OK"
        [cn:mail_in_rf]="入站 无监听" [en:mail_in_rf]="inbound no listener"
        [cn:mail_in_bl]="入站 ✗ 阻断" [en:mail_in_bl]="inbound BLOCKED"
        [cn:mail_in_na]="入站 待检测" [en:mail_in_na]="inbound N/A"
        [cn:mail_note2]="出站=本机直连目标 MX;入站=check-host.net 外部节点探测本机(无监听=路径可达但无服务)" [en:mail_note2]="out=direct to MX; in=check-host.net external probe"
        [cn:prov6_no]="(无 IPv6,全部异常)" [en:prov6_no]="(no IPv6, all abnormal)"
        [cn:ss_loc]="位置" [en:ss_loc]="Location"
        [cn:ss_prov]="商家" [en:ss_prov]="Provider"
        [cn:ss_virt]="虚拟化" [en:ss_virt]="Virt"
        [cn:ss_score]="评分" [en:ss_score]="Score"
        [cn:ss_single]="单核" [en:ss_single]="Single"
        [cn:ss_multi]="多核" [en:ss_multi]="Multi"
        [cn:ss_mem]="内存" [en:ss_mem]="RAM"
        [cn:ss_membw]="带宽" [en:ss_membw]="BW"
        [cn:ss_disk]="磁盘" [en:ss_disk]="Disk"
        [cn:ss_seq]="顺序" [en:ss_seq]="Seq"
        [cn:ss_cn]="三网" [en:ss_cn]="CN-Net"
        [cn:ss_pkt]="大小包" [en:ss_pkt]="PktSize"
        [cn:ss_fraud]="欺诈" [en:ss_fraud]="Fraud"
        [cn:ss_media]="解锁" [en:ss_media]="Unlock"
        [cn:ss_intl]="国际" [en:ss_intl]="Intl"
        [cn:ss_time]="耗时" [en:ss_time]="Time"
        [cn:ss_route]="回程" [en:ss_route]="Route"
        [cn:cnmtx_p]="三网质量" [en:cnmtx_p]="CN Quality"
        [cn:cnmtx_note]="延迟/抖动/丢包/TCP 握手/定向测速/重传/回程线路" [en:cnmtx_note]="latency/jitter/loss/TCP/speed/retrans/route"
        [cn:cnmtx_avg]="均值" [en:cnmtx_avg]="Avg"
        [cn:cdngrp]="CDN 资源可达" [en:cdngrp]="CDN Assets"
        [cn:asninfo]="ASN 概况" [en:asninfo]="ASN Info"
        [cn:asnnb]="邻居" [en:asnnb]="neighbours"
        [cn:asnpf]="前缀" [en:asnpf]="prefixes"
        [cn:provm]="省份延迟矩阵" [en:provm]="Province Matrix"
        [cn:provm_note]="31 省 × 电信/联通/移动网内目标,每格发 4 个 ICMP 包" [en:provm_note]="31 provinces x CT/CU/CM, 4 pings per cell"
        [cn:provm_avg]="全网省份均值" [en:provm_avg]="All-Province Avg"
        [cn:cells]="个可用网格" [en:cells]="cells"
        [cn:provm_hint]="明细见报告完整模式/JSON;丢包格标注 *丢包%" [en:provm_hint]="details in full report/JSON; * marks loss"
        [cn:tier1k]="Tier1 骨干" [en:tier1k]="Tier1 Backbone"
        [cn:ipreg]="IP 段注册" [en:ipreg]="IP Registration"
        [cn:regd]="注册于" [en:regd]="registered"
        [cn:dtype]="介质" [en:dtype]="Media"
        [cn:geo]="坐标" [en:geo]="Geo"
    )
}

preflight() {
    [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { err "需要 bash 4.0+(当前 $BASH_VERSION)"; exit 1; }
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { err "需要 curl 或 wget"; exit 1; }
    [ "$(id -u)" = 0 ] || warn "非 root 运行:大部分测试可用,个别探测可能受限"

    # 临时目录:优先 /dev/shm? 测速写盘用磁盘,故用磁盘临时目录
    local base=${TMPDIR:-/tmp} _stale
    # 清扫历次异常退出(SIGKILL 时 trap 不触发)留下的陈旧临时目录;24h 门槛避免误伤并行运行
    for _stale in "$base"/hostqos.??????; do
        [ -d "$_stale" ] || continue
        [ -n "$(find "$_stale" -maxdepth 0 -mmin +1440 2>/dev/null)" ] && rm -rf "$_stale"
    done
    HQ_TMP=$(mktemp -d "$base/hostqos.XXXXXX" 2>/dev/null) || { err "无法创建临时目录"; exit 1; }
    HQ_BIN="$HQ_TMP/bin"; mkdir -p "$HQ_BIN"
    HQ_HOME="$HQ_TMP/home"   # 节点表/DNS/端点缓存仅存活本次运行,不在 $HOME 留痕
    trap cleanup EXIT INT TERM

    # 机器架构(用于下载预编译二进制)
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)  HQ_ARCH="x86_64"; HQ_GOARCH="x86_64"; HQ_YABSARCH="x64" ;;
        aarch64|arm64) HQ_ARCH="arm64";  HQ_GOARCH="arm64";  HQ_YABSARCH="aarch64" ;;
        *)             HQ_ARCH="";       HQ_GOARCH="";       HQ_YABSARCH="" ;;
    esac

    # 输出目录仅在 --report/-o 时创建;默认不落盘,不在工作目录留任何文件
    if [ "$OPT_REPORT" = 1 ]; then
        mkdir -p "$OPT_OUTDIR" 2>/dev/null || { err "无法创建输出目录 $OPT_OUTDIR"; exit 1; }
        OPT_OUTDIR=$(cd "$OPT_OUTDIR" && pwd) || exit 1
    fi

    # 低资源检测:内存余量不足时自动降级(CPU 快测/跳过 speedtest-go 下载与内存带宽/
    # 磁盘文件减半),避免测速把生产小机压死(2GB 级、常驻服务多的机器常见)
    local mem_avail_mb
    mem_avail_mb=$(awk '/^MemAvailable:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    is_num "$mem_avail_mb" || mem_avail_mb=0
    if [ "$mem_avail_mb" -lt 700 ]; then
        OPT_LOWRES=1
        note "内存可用仅 ${mem_avail_mb}MB → 自动启用低资源模式(CPU 快测、跳过 speedtest-go、磁盘文件减半;内存带宽仍以小块执行)"
    fi

    # ---- 跨发行版兼容层:一次性探测系统能力,后续模块按能力降级 ----
    # busybox/老核心工具常见坑:dd 不支持 conv=fdatasync、ping 不支持 -W
    local _ddt="$HQ_TMP/ddprobe.$$"
    DD_SYNC="conv=fdatasync"
    if ! dd if=/dev/zero of="$_ddt" bs=1k count=1 conv=fdatasync >/dev/null 2>&1; then
        if dd if=/dev/zero of="$_ddt" bs=1k count=1 conv=fsync >/dev/null 2>&1; then
            DD_SYNC="conv=fsync"
        else
            DD_SYNC=""
        fi
    fi
    rm -f "$_ddt" 2>/dev/null
    PING_WOPT="-W 2"
    ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1 || PING_WOPT=""

    # 架构与缺失工具的降级说明(不阻断,如实告知哪些模块会退化)
    if [ -z "$HQ_ARCH" ]; then
        warn "$(uname -m) 架构无预编译二进制:fio/测速/traceroute 相关项将跳过(基础检测不受影响)"
    fi
    command -v dig >/dev/null 2>&1 || \
        note "dig 缺失:省份/IPv6 测点走系统解析/DoH 回退,IP 黑名单数据库将跳过(安装 dnsutils/bind9-dnsutils 可启用)"
    command -v ss >/dev/null 2>&1 || note "ss 缺失:TCP 重传采样将跳过"
    command -v jq >/dev/null 2>&1 || note "jq 缺失:JSON 解析走 grep 兼容路径(无功能损失)"
    grep -qi microsoft /proc/version 2>/dev/null && \
        note "WSL 环境:/proc 与 DMI 信息可能不完整,虚拟化/超线程识别或受影响"
    [ -r /etc/alpine-release ] && \
        note "Alpine:建议已安装 bash;缺失工具可 apk add curl dig jq"
}

print_banner() {
    printf '%s\n' "${C_CYAN}${C_BOLD}"
    cat <<'BANNER'
   _  _                     _        _
  | || |__ _ _  _  ___ __ _| |_ __ _(_)_ _
  | __ / _` | || |(_-</ _` |  _/ _` | | '_|
  |_||_\__,_|\_,_/__/\__,_|\__\__,_|_|_(_|
BANNER
    printf '%s%s\n' "  HostQoS v$HQ_VERSION · 零广告 · 默认不落盘(--report 本地保存)" "${C_OFF}"
    case "$HQ_MODE" in
        full)  note "模式: 完整模式(全部检测,预计 8-20 分钟; -s 精简 / --tiny 极小)" ;;
        tiny)  note "模式: 极小模式(小规格机器适用,预计 1-3 分钟;下载/写盘 <50MB)" ;;
        *)     note "模式: 精简模式(关键数据,预计 3-6 分钟;无参数为完整模式,--tiny 极小)" ;;
    esac
    if [ "$OPT_LOW_TRAFFIC" = 1 ]; then note "低流量模式:测速时长减半"; fi
    local est="2-6"
    [ "$HQ_MODE" = full ] && est="6-20"
    [ "$HQ_MODE" = tiny ] && est="0.2-1"
    note "预计消耗流量: ${est} GB(测速为主,Ctrl+C 可中断)"
}
# ============================================================
# M0 系统信息(始终运行)
# ============================================================
detect_virt() {
    local v="" dmi_all
    dmi_all="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt 2>/dev/null)
        [ "$v" = "none" ] && v=""
    fi
    if [ -z "$v" ]; then
        case "$dmi_all" in
            *QEMU*|*KVM*)            v="kvm" ;;
            *"Amazon EC2"*)          v="amazon" ;;
            *"Google Compute"*)      v="kvm" ;;
            *"Alibaba Cloud"*)       v="kvm" ;;
            *VMware*|*VMW*)          v="vmware" ;;
            *Xen*|*"HVM domU"*)      v="xen" ;;
            *"innotek"*|*VirtualBox*|*"Oracle Corporation"*) v="oracle" ;;
            *Microsoft*|*Hyper-V*)   v="microsoft" ;;
            *Parallels*)             v="parallels" ;;
            *Bochs*)                 v="bochs" ;;
            *OpenStack*)             v="kvm" ;;
            *BHYVE*|*bhyve*)         v="bhyve" ;;
        esac
    fi
    if [ -z "$v" ]; then
        if [ -d /proc/xen ]; then v="xen"
        elif [ -f /proc/user_beancounters ]; then v="openvz"
        elif grep -qaE '(^|/)docker|kubepods|libpod' /proc/1/cgroup 2>/dev/null; then v="docker"
        elif grep -qa 'lxc' /proc/1/environ 2>/dev/null || grep -qa '^lxc' /proc/1/cgroup 2>/dev/null; then v="lxc"
        elif [ -e /dev/kvm ]; then :; fi
    fi
    local -A vmap=( [kvm]="KVM" [qemu]="QEMU/KVM" [xen]="Xen" [openvz]="OpenVZ" [lxc]="LXC"
                    [docker]="Docker" [vmware]="VMware" [microsoft]="Hyper-V" [amazon]="Amazon Nitro"
                    [oracle]="Oracle VM" [parallels]="Parallels" [bochs]="Bochs" [bhyve]="bhyve"
                    [podman]="Podman" [zvm]="z/VM" [virtage]="Virtage" )
    if [ -n "$v" ]; then
        printf '%s' "${vmap[$v]:-$v}"
    else
        printf '%s' "未知(可能独服)"
    fi
}

mod_sysinfo() {
    sec "$(L sys '系统信息') System"
    local os_pretty os_arch
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null
        os_pretty=${PRETTY_NAME:-${NAME:-unknown}}
    else
        os_pretty=$(uname -s)
    fi
    os_arch=$(uname -m)

    local cpu_model cpu_cores cpu_threads cpu_mhz flags
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')
    [ -z "$cpu_model" ] && cpu_model=$(grep -m1 'Model' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')
    cpu_threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    cpu_cores=$(lscpu 2>/dev/null | awk -F': *' '/^Core\(s\) per socket/{c=$2} /^Socket\(s\)/{s=$2} END{if(c&&s) print c*s; else exit 1}') || cpu_cores=$cpu_threads
    cpu_mhz=$(awk -F': *' '/^cpu MHz/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
    [ -z "$cpu_mhz" ] && cpu_mhz=$(lscpu 2>/dev/null | awk -F': *' '/^CPU max MHz/{print int($2); exit}')
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)
    local aes="否" vmx="" avx2=""
    [[ $flags == *aes* ]] && aes="是"
    [[ $flags == *avx2* ]] && avx2="AVX2"
    # 嵌套虚拟化指令(vmx/svm 未暴露到 guest = 宿主未开嵌套虚拟化)
    if [[ $flags == *vmx* ]]; then vmx="VT-x"
    elif [[ $flags == *svm* ]]; then vmx="AMD-V"
    fi
    [ -z "$vmx" ] && vmx="无"
    G[cpu_virt]=$vmx
    # L3 缓存(/sys 通用,兼容无 lscpu 环境;参考 HardwareQuality CPU 组)
    local c l3=""
    for c in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ "$(cat "$c/level" 2>/dev/null)" = 3 ] && l3=$(awk '{printf "%.0fMB", $1/1024}' "$(cat "$c/size" 2>/dev/null)" 2>/dev/null)
    done
    G[l3_cache]=$l3; G[avx2]=$avx2

    # /proc/meminfo 为主(全发行版一致),老式 free 输出兜底
    local mem_total mem_avail swap_total
    mem_total=$(awk '/^MemTotal:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    swap_total=$(awk '/^SwapTotal:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    if [ -z "$mem_total" ]; then
        local mem_line
        mem_line=$(free -m 2>/dev/null | awk '/^Mem:/{t=$2; a=(NF>=7?$7:$4)} /^Swap:/{s=$2} END{print t, a, s}')
        read -r mem_total mem_avail swap_total <<< "$mem_line"
    fi
    mem_total=${mem_total:-0}; mem_avail=${mem_avail:-0}; swap_total=${swap_total:-0}

    local disk_total disk_avail disk_mount=$PWD
    if command -v df >/dev/null; then
        read -r disk_total disk_avail _ < <(df -Pm "$disk_mount" 2>/dev/null | awk 'NR==2{print $2,$3,$4}')
    fi
    disk_total=${disk_total:-0}; disk_avail=${disk_avail:-0}

    local virt cc
    virt=$(detect_virt)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "-")
    # 本地网络栈策略(参考 NetQuality):qdisc / 缓冲上限 / BBR
    local qdisc rmem wmem
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "-")
    rmem=$(awk '{print $3}' /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)
    wmem=$(awk '{print $3}' /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)
    [[ $cc == *bbr* ]] && G[bbr]=1 || G[bbr]=0
    G[qdisc]="$qdisc"
    [ -n "$rmem" ] && G[rmem_max]=$rmem
    [ -n "$wmem" ] && G[wmem_max]=$wmem

    # 内存超售特征(参考 HardwareQuality/nodequality):气球回收 / KSM 复用 独立判定
    local oversell="" _balloon=0 _ksm=0
    if grep -q '^virtio_balloon' /proc/modules 2>/dev/null || lsmod 2>/dev/null | grep -q '^virtio_balloon'; then
        _balloon=1
        oversell="virtio_balloon 驱动已加载(宿主机可气球回收内存)"
    fi
    if [ "$(cat /sys/kernel/mm/ksm/run 2>/dev/null)" = 1 ] && \
       [ "$(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        _ksm=1
        oversell="${oversell:+${oversell} + }KSM 内存页合并已开启(同宿主机超售特征)"
    fi
    G[oversell_balloon]=$_balloon
    G[oversell_ksm]=$_ksm
    if [ "$_balloon" = 1 ] || [ "$_ksm" = 1 ]; then
        kv "超开指标" "$( [ "$_balloon" = 1 ] && printf '%s✔ 气球回收%s  ' "$C_RED" "$C_OFF" || printf '%s✘ 气球回收%s  ' "$C_GREEN" "$C_OFF" )$( [ "$_ksm" = 1 ] && printf '%s✔ KSM 复用%s' "$C_RED" "$C_OFF" || printf '%s✘ KSM 复用%s' "$C_GREEN" "$C_OFF" )"
    fi
    G[oversell]="$oversell"

    local load uptime
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
    read -r uptime _ < /proc/uptime
    uptime=$(awk -v s="${uptime:-0}" 'BEGIN{d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm", d, h, m}')

    local hn; hn=$(hostname 2>/dev/null || echo unknown)

    G[os]="$os_pretty ($os_arch)"
    G[arch]="$os_arch"
    # 精简系统名:如 "Debian GNU/Linux 12 (bookworm)" → "Debian 12";识别失败回退首词
    G[os_short]=$(printf '%s' "$os_pretty" | sed -nE 's/^.*(Debian|Ubuntu|CentOS|AlmaLinux|Rocky|Fedora|Alpine|Arch Linux|openSUSE|Gentoo|Oracle Linux|Amazon Linux|Raspbian|Kali|Deepin|UOS|Anolis|openEuler)[^0-9]*([0-9]+(\.[0-9]+)?)?.*/\1 \2/p' | sed 's/ *$//')
    [ -z "${G[os_short]}" ] && G[os_short]=$(printf '%s' "$os_pretty" | awk '{print $1" "$2}' | sed 's/ *$//')
    [ -z "${G[os_short]}" ] && G[os_short]=$(printf '%s' "$os_pretty" | cut -d' ' -f1)
    G[kernel]=$(uname -r)
    G[hostname]="$hn"
    G[uptime]="$uptime"; G[load]="$load"
    G[cpu_model]="$cpu_model"; G[cpu_cores]=$cpu_cores; G[cpu_threads]=$cpu_threads
    G[cpu_mhz]=$cpu_mhz; G[aes]=$aes; G[cpu_virt]=$vmx
    G[mem_total_mb]=$mem_total; G[mem_avail_mb]=$mem_avail; G[swap_total_mb]=$swap_total
    G[disk_total_mb]=$disk_total; G[disk_avail_mb]=$disk_avail
    G[virt]="$virt"; G[tcp_cc]="$cc"
    G[dmi_vendor]=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr -d '\n')
    G[dmi_product]=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\n')

    kv "操作系统"   "${G[os]}"
    kv "内核"       "${G[kernel]}"
    kv "运行时间"   "$uptime (负载 $load)"
    kv "CPU"        "$cpu_model"
    kv "核心"       "${cpu_cores}核${cpu_threads}线程 @ ${cpu_mhz%%.*}MHz${l3:+ · L3 ${l3}}"
    kv "指令集"     "AES-NI:$aes${avx2:+ · $avx2}${vmx:+ · $vmx}"
    kv "内存"       "$(awk -v m=$mem_total 'BEGIN{printf "%.1fGB",m/1024}') (可用$(awk -v m=$mem_avail 'BEGIN{printf "%.1fGB",m/1024}')) / Swap $(awk -v m=$swap_total 'BEGIN{printf "%.1fGB",m/1024}')"
    kv "磁盘"       "共$(awk -v m=$disk_total 'BEGIN{printf "%.0fGB",m/1024}') 可用$(awk -v m=$disk_avail 'BEGIN{printf "%.0fGB",m/1024}')"
    kv "虚拟化"     "$virt"
    kv "TCP CC"     "$cc (qdisc ${G[qdisc]:-?}, $( [ "${G[bbr]:-0}" = 1 ] && echo 'BBR 开启' || echo 'BBR 未开启'))"
    [ -n "$oversell" ] && warn "内存超售: $oversell"
}
# ============================================================
# M1 商家识别(DMI + 云Metadata + ASN/PTR 组合,优先级链)
# ============================================================

# DMI 规则: 关键字|品牌|类型(cloud=云商家平台 vm=仅虚拟化平台)
PROV_DMI_RULES=(
    "digitalocean|DigitalOcean|cloud"
    "hetzner|Hetzner|cloud"
    "vultr|Vultr|cloud"
    "linode|Linode (Akamai)|cloud"
    "google compute engine|Google Cloud|cloud"
    "amazon ec2|Amazon AWS|cloud"
    "alibaba cloud|阿里云|cloud"
    "scaleway|Scaleway|cloud"
    "upcloud|UpCloud|cloud"
    "oracle corporation|Oracle Cloud(疑似)|cloud"
    "microsoft corporation|Microsoft (Hyper-V/Azure)|cloud"
    "openstack|OpenStack|cloud"
    "qemu|QEMU/KVM|vm"
    "vmware|VMware|vm"
    "xen|Xen|vm"
    "innotek|VirtualBox|vm"
    "virtualbox|VirtualBox|vm"
    "parallels|Parallels|vm"
    "bochs|Bochs|vm"
    "bhyve|bhyve|vm"
    "kubevirt|KubeVirt|vm"
)

# ASN 号码库: AS号|品牌 (仅收录确定的)
PROV_ASN_RULES=(
    "20473|Vultr"
    "14061|DigitalOcean"
    "24940|Hetzner"
    "213230|Hetzner"
    "16276|OVH"
    "16509|Amazon AWS"
    "14618|Amazon AWS"
    "396982|Google Cloud"
    "15169|Google"
    "8075|Microsoft Azure"
    "45102|阿里云"
    "37963|阿里云"
    "132203|腾讯云"
    "51167|Contabo"
    "63949|Linode (Akamai)"
    "9009|M247"
    "13213|M247"
    "53667|FranTech (BuyVM)"
    "53655|FranTech (BuyVM)"
)

# org/isp 关键词库(不区分大小写子串): 正则@品牌
PROV_ORG_RULES=(
    "vultr|choopa|the constant company@Vultr"
    "digitalocean@DigitalOcean"
    "hetzner@Hetzner"
    "ovh@OVH"
    "amazon|aws@Amazon AWS"
    "google cloud|google llc@Google Cloud"
    "microsoft@Microsoft Azure"
    "alibaba|aliyun|阿里巴巴|阿里云@阿里云"
    "tencent@腾讯云"
    "huawei@华为云"
    "contabo@Contabo"
    "linode|akamai connected@Linode (Akamai)"
    "m247@M247"
    "it7|bandwagonhost@搬瓦工 BandwagonHost"
    "dmit@DMIT"
    "racknerd@RackNerd"
    "cloudcone@CloudCone"
    "vmiss@VMISS"
    "greencloud|green cloud@GreenCloudVPS"
    "hosthatch@HostHatch"
    "gcore|g-core@GCore"
    "oracle@Oracle Cloud"
    "scaleway@Scaleway"
    "upcloud@UpCloud"
    "leaseweb@Leaseweb"
    "hostwinds@HostWinds"
    "kamatera@Kamatera"
    "ionos|1&1@IONOS"
    "hostinger@Hostinger"
    "psychz@Psychz"
    "colocrossing@ColoCrossing"
    "frantech|buyvm@BuyVM"
    "equinix metal|packet hosting@Equinix Metal"
    "zenlayer@ZenLayer"
    "gigsglobal|gigs@GIGS"
    "multacom@Multacom"
    "16clouds@搬瓦工 BandwagonHost"
)

PROV_UPSTREAM="m247|ponynet|choopa|colocrossing|frantech|leaseweb|zenlayer"

prov_match_dmi() {
    local hay
    hay="$(printf '%s %s' "${G[dmi_vendor]:-}" "${G[dmi_product]:-}" | tr '[:upper:]' '[:lower:]')"
    [ -z "$(printf '%s' "$hay" | tr -d ' ')" ] && return 1
    local rule kw brand type
    for rule in "${PROV_DMI_RULES[@]}"; do
        IFS='|' read -r kw brand type <<< "$rule"
        if printf '%s' "$hay" | grep -qE "$kw"; then
            PROV_DMI_MATCH="$brand"; PROV_DMI_TYPE="$type"
            return 0
        fi
    done
    return 1
}

# 云 metadata 并行探测(每项独立短超时,互斥命中)
prov_probe_metadata() {
    local d="$HQ_TMP/meta"; mkdir -p "$d"
    local -a pids=()

    (
        _out=$(hq_curl "http://169.254.169.254/latest/meta-data/instance-id" 2)
        if [ -z "$_out" ]; then
            _tok=$(curl -fsS --connect-timeout 2 --max-time 2 -X PUT \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
                "http://169.254.169.254/latest/api/token" 2>/dev/null)
            [ -n "$_tok" ] && _out=$(hq_curl "http://169.254.169.254/latest/meta-data/instance-id" 2 -H "X-aws-ec2-metadata-token: ${_tok}")
        fi
        printf '%s' "$_out"
    ) >"$d/aws" 2>/dev/null & pids+=($!)
    ( hq_curl -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/name" 2 ) >"$d/gcp" 2>/dev/null & pids+=($!)
    ( hq_curl -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/azEnvironment?api-version=2021-02-01&format=text" 2 ) >"$d/az" 2>/dev/null & pids+=($!)
    ( hq_curl "http://169.254.169.254/opc/v2/instance/" 2 || hq_curl "http://169.254.169.254/opc/v1/instance/" 2 ) >"$d/oci" 2>/dev/null & pids+=($!)
    ( hq_curl "http://169.254.169.254/metadata/v1.json" 3 ) >"$d/do" 2>/dev/null & pids+=($!)
    ( hq_curl "http://169.254.169.254/hetzner/v1/metadata" 2 ) >"$d/hz" 2>/dev/null & pids+=($!)
    ( hq_curl "http://169.254.169.254/v1/" 2 ) >"$d/vultr" 2>/dev/null & pids+=($!)
    ( hq_curl "http://100.100.100.200/latest/meta-data/instance/id" 2 ) >"$d/ali" 2>/dev/null & pids+=($!)
    ( hq_curl "http://metadata.tencentyun.com/latest/meta-data/instance-id" 2 ) >"$d/tc" 2>/dev/null & pids+=($!)

    wait "${pids[@]}" 2>/dev/null
    PROV_META_MATCH=""; PROV_META_DETAIL=""
    if [ -s "$d/aws" ]; then
        PROV_META_MATCH="Amazon AWS"; PROV_META_DETAIL="instance: $(head -c 60 "$d/aws")"
    elif [ -s "$d/gcp" ]; then
        PROV_META_MATCH="Google Cloud"; PROV_META_DETAIL="instance: $(head -c 60 "$d/gcp")"
    elif [ -s "$d/az" ]; then
        PROV_META_MATCH="Microsoft Azure"; PROV_META_DETAIL="$(head -c 60 "$d/az")"
    elif [ -s "$d/oci" ]; then
        PROV_META_MATCH="Oracle Cloud"
        PROV_META_DETAIL="region: $(jfield "$(cat "$d/oci")" canonicalRegionName)"
    elif [ -s "$d/do" ]; then
        PROV_META_MATCH="DigitalOcean"
        PROV_META_DETAIL="region: $(jfield "$(cat "$d/do")" region)"
    elif [ -s "$d/hz" ]; then
        PROV_META_MATCH="Hetzner"
        PROV_META_DETAIL="$(grep -m1 '^hostname:' "$d/hz" | head -c 60)"
    elif [ -s "$d/vultr" ]; then
        PROV_META_MATCH="Vultr"
        PROV_META_DETAIL="instance: $(jfield "$(cat "$d/vultr")" instance-id)"
    elif [ -s "$d/ali" ]; then
        PROV_META_MATCH="阿里云"; PROV_META_DETAIL="instance: $(head -c 60 "$d/ali")"
    elif [ -s "$d/tc" ]; then
        PROV_META_MATCH="腾讯云"; PROV_META_DETAIL="instance: $(head -c 60 "$d/tc")"
    fi
    rm -rf "$d" 2>/dev/null
}

prov_match_asn_org() {
    local hay
    hay="${1:-} $(printf '%s' "${G[ptr]:-}" | tr '[:upper:]' '[:lower:]')"
    local rule re brand
    for rule in "${PROV_ORG_RULES[@]}"; do
        IFS='@' read -r re brand <<< "$rule"
        if printf '%s' "$hay" | grep -qiE "$re"; then
            printf '%s' "$brand"
            return 0
        fi
    done
    return 1
}

# 展开 IPv6 并生成反转 nibble 串(32 个单字符标签,不含 .ip6.arpa 后缀)
# 供 origin6.asn.cymru.com / v6 DNSBL 查询使用
ipv6_nibbles() { # <ipv6> -> "1.1.1.1.0.0.....6.0.6.2"
    printf '%s' "$1" | awk '{
        ip = $0
        if (ip ~ /::/) {
            idx = index(ip, "::")
            head = substr(ip, 1, idx-1)
            tail = substr(ip, idx+2)
            nh = split(head, H, ":"); rh=0
            for (i=1; i<=nh; i++) if (H[i] != "") { rh++; HX[rh]=H[i] }
            nt = split(tail, T, ":"); rt=0
            for (i=1; i<=nt; i++) if (T[i] != "") { rt++; TX[rt]=T[i] }
            miss = 8 - rh - rt
            s = ""
            for (i=1; i<=rh; i++) s = s HX[i] ":"
            for (i=0; i<miss; i++) s = s "0:"
            for (i=1; i<=rt; i++) s = s TX[i] ":"
            ip = s
        }
        n = split(ip, A, ":")
        hex = ""
        for (i=1; i<=n; i++) {
            h = A[i]
            while (length(h) < 4) h = "0" h
            hex = hex h
        }
        out = ""
        for (i = length(hex); i >= 1; i--) out = out (out==""?"":".") substr(hex, i, 1)
        print out
    }'
}

# Team Cymru 单 IP 查询(v4/v6) -> "asn|注册国CC|AS名称"
# v2.6:Cymru verbose 输出已改为 ASN|IP|Prefix|CC|RIR|Date|ASName,按新格式解析;
#      43 端口失败时降级 DNS TXT(origin[6].asn.cymru.com,无 AS 名称)
cymru_lookup() { # <ip>
    local ip=$1 out
    out=$(with_timeout 8 bash -c "
        exec 3<>/dev/tcp/whois.cymru.com/43 || exit 1
        printf 'begin\nverbose\n%s\nend\n' '$ip' >&3
        cat <&3" 2>/dev/null | awk -F'|' 'NR>1 && NF>=7 {
            gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$7);
            print $1 "|" $4 "|" $7; exit }')
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    command -v dig >/dev/null 2>&1 || return 1
    local rev zone txt
    if ip_is_v4 "$ip"; then
        zone=origin.asn.cymru.com
        rev=$(printf '%s' "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
    else
        zone=origin6.asn.cymru.com
        rev=$(ipv6_nibbles "$ip")
    fi
    txt=$(dig +short +time=3 +tries=1 TXT "${rev}.${zone}" @8.8.8.8 2>/dev/null | head -n1 | tr -d '"')
    [ -n "$txt" ] && printf '%s|%s|\n' \
        "$(printf '%s' "$txt" | awk -F' *[|] *' '{print $1}')" \
        "$(printf '%s' "$txt" | awk -F' *[|] *' '{print $3}')"
}

mod_provider() {
    sec "$(L provider '商家识别') Provider"
    local asn_match="" upstream_note=""

    # 公网 IP 与归属信息(多级回退)
    local ip4="" ip6="" geo_json="" src=""
    if [[ $OPT_IPV == *4* ]]; then
        for u in "https://api.ip.sb/ip" "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ifconfig.me/ip"; do
            ip4=$(hq_curl "$u" 6 | tr -d '[:space:]') && ip_is_v4 "$ip4" && break || ip4=""
        done
    fi
    if [[ $OPT_IPV == *6* ]]; then
        for u in "https://api-ipv6.ip.sb/ip" "https://ipv6.icanhazip.com" "https://api6.ipify.org"; do
            ip6=$(hq_curl "$u" 6 | tr -d '[:space:]') && ip_is_v6 "$ip6" && break || ip6=""
        done
    fi
    G[ip4]="$ip4"; G[ip6]="$ip6"

    local qip="$ip4"; [ -z "$qip" ] && qip="$ip6"
    if [ -n "$qip" ]; then
        geo_json=$(hq_curl "http://ip-api.com/json/${qip}?fields=status,message,country,countryCode,regionName,city,lat,lon,isp,org,as,asname,reverse,mobile,proxy,hosting,query" 10)
        src="ip-api"
        if [ -z "$geo_json" ] || [ "$(jfield "$geo_json" status)" != success ]; then
            geo_json=$(hq_curl "https://ipwho.is/${qip}" 10) && src="ipwho.is"
        fi
        if [ -z "$geo_json" ] && [ -n "$ip4" ]; then
            geo_json=$(hq_curl "https://speed.cloudflare.com/meta" 10) && src="cf"
        fi
    fi
    G[geo_src]="$src"
    if [ -n "$geo_json" ]; then
        case "$src" in
            ip-api)
                G[loc_country]=$(jfield "$geo_json" country); G[loc_cc]=$(jfield "$geo_json" countryCode)
                G[loc_region]=$(jfield "$geo_json" regionName); G[loc_city]=$(jfield "$geo_json" city)
                G[isp]=$(jfield "$geo_json" isp); G[org]=$(jfield "$geo_json" org)
                G[as_full]=$(jfield "$geo_json" as)
                G[proxy]=$(jfield "$geo_json" proxy); G[hosting_flag]=$(jfield "$geo_json" hosting); G[mobile_flag]=$(jfield "$geo_json" mobile)
                G[lat]=$(jfield "$geo_json" lat); G[lon]=$(jfield "$geo_json" lon)
                [ -z "${G[ptr]:-}" ] && G[ptr]=$(jfield "$geo_json" reverse) ;;
            ipwho.is)
                G[loc_country]=$(jfield "$geo_json" country); G[loc_cc]=$(jfield "$geo_json" country_code)
                G[loc_region]=$(jfield "$geo_json" region); G[loc_city]=$(jfield "$geo_json" city)
                G[isp]=$(jfield "$geo_json" connection.isp); G[org]=$(jfield "$geo_json" connection.org)
                G[as_full]="AS$(jfield "$geo_json" connection.asn) $(jfield "$geo_json" connection.org)" ;;
            cf)
                G[loc_country]=$(jfield "$geo_json" country); G[loc_cc]=$(jfield "$geo_json" country)
                G[loc_city]=$(jfield "$geo_json" city)
                G[org]=$(jfield "$geo_json" asOrganization); G[as_full]=$(jfield "$geo_json" asOrganization)
                G[colo]=$(jfield "$geo_json" colo) ;;
        esac
    fi
    G[asn_num]=$(printf '%s' "${G[as_full]:-}" | grep -oE 'AS[0-9]+' | head -n1 | tr -d 'AS')

    # PTR(独立补充,ip-api 未给时)
    if [ -z "${G[ptr]:-}" ] && [ -n "$qip" ]; then
        if command -v dig >/dev/null 2>&1; then
            G[ptr]=$(dig +short -x "$qip" 2>/dev/null | head -n1 | sed 's/\.$//')
        fi
    fi

    # Team Cymru 单点查询(ASN 兜底 + 注册国,用于原生/广播判断;v2.6 修复新输出格式解析)
    G[cymru_cc]=""; G[cymru_asname]=""
    if [ -n "$qip" ]; then
        local cym _casn _ccc _casc
        cym=$(cymru_lookup "$qip")
        if [ -n "$cym" ]; then
            # cymru_lookup 输出: asn|注册国CC|AS名称
            IFS='|' read -r _casn _ccc _casc <<< "$cym"
            G[cymru_cc]=$_ccc
            G[cymru_asname]=$_casc
            if [ -z "${G[asn_num]:-}" ] && [ "$_casn" != "NA" ]; then G[asn_num]=$_casn; fi
            if [ -z "${G[as_full]:-}" ] && [ -n "$_casn" ] && [ "$_casn" != "NA" ] && [ -n "$_casc" ]; then
                G[as_full]="AS${_casn} ${_casc}"
            fi
        fi
    fi

    # ---- 识别优先级链 ----
    PROV_DMI_MATCH=""; PROV_META_MATCH=""
    prov_match_dmi
    prov_probe_metadata

    local name="" source="未知" conf=""
    if [ -n "$OPT_PROVIDER" ]; then
        name="$OPT_PROVIDER"; source="用户指定"; conf=high
    elif [ -n "${PROV_META_MATCH:-}" ]; then
        name="$PROV_META_MATCH"; source="云 Metadata"; conf=high
    elif [ -n "${PROV_DMI_MATCH:-}" ] && [ "${PROV_DMI_TYPE:-}" = cloud ]; then
        name="$PROV_DMI_MATCH"; source="DMI 主板信息"; conf=high
    else
        # 先按 ASN 号码精确匹配,再按 org/isp 关键词
        local asn_brand="" rule rasn rbrand
        if [ -n "${G[asn_num]:-}" ]; then
            for rule in "${PROV_ASN_RULES[@]}"; do
                IFS='|' read -r rasn rbrand <<< "$rule"
                if [ "$rasn" = "${G[asn_num]}" ]; then asn_brand=$rbrand; break; fi
            done
        fi
        if [ -n "$asn_brand" ]; then
            name="$asn_brand"; source="ASN 号码库"; conf=mid
        else
            asn_match=$(prov_match_asn_org "${G[org]:-} ${G[isp]:-}")
            if [ -n "$asn_match" ]; then
                name="$asn_match"; source="ASN/WHOIS 推测"; conf=mid
            elif [ -n "${PROV_DMI_MATCH:-}" ]; then
                : # DMI 仅命中虚拟化平台(非云商家):不冒充商家,虚拟化方式由 virt 字段单独展示
            fi
        fi
        if [ -n "$name" ] && printf '%s' "${G[org]:-} ${G[isp]:-}" | grep -qiE "$PROV_UPSTREAM"; then
            upstream_note="该网络为常见上游,商家可能是其下游品牌"
        fi
    fi
    [ -z "$name" ] && name="未识别(可用 -p 手动指定)"

    G[prov_name]="$name"; G[prov_source]="$source"; G[prov_conf]=$conf
    G[prov_dmi]="${PROV_DMI_MATCH:-}"; G[prov_meta]="${PROV_META_MATCH:-}"
    G[prov_upstream]="$upstream_note"

    # IP 段注册信息(RDAP:RIR 归属/网段/注册日期;参考 IPQuality Info 组)
    if [ -n "$qip" ]; then
        local rdap_json rdap_url rir="" regdate="" startaddr="" _flat _pf _ln
        rdap_json=$(hq_curl "https://rdap.org/ip/${qip}" 10)
        if [ -n "$rdap_json" ]; then
            _flat=$(printf '%s' "$rdap_json" | tr -d '\n ')
            # 注册日期:压平 JSON 后按事件对匹配(兼容 eventDate 在前/在后两种顺序)
            regdate=$(printf '%s' "$_flat" | grep -oE '"eventAction":"registration","eventDate":"[0-9]{4}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}' | head -n1)
            [ -z "$regdate" ] && regdate=$(printf '%s' "$_flat" | grep -oE '"eventDate":"[0-9]{4}-[0-9]{2}[^"]*","eventAction":"registration"' | grep -oE '[0-9]{4}-[0-9]{2}' | head -n1)
            # CIDR:ARIN 风格 cidr0_cidrs(v4prefix+length) 或通用 startAddress
            _pf=$(printf '%s' "$_flat" | grep -oE '"v4prefix":"[^"]+"' | head -n1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
            _ln=$(printf '%s' "$_flat" | grep -oE '"v4prefix":"[^"]+","length":[0-9]+' | head -n1 | grep -oE '[0-9]+$')
            [ -n "$_pf" ] && [ -n "$_ln" ] && startaddr="${_pf}/${_ln}"
            [ -z "$startaddr" ] && startaddr=$(printf '%s' "$_flat" | grep -oE '"startAddress":"[^"]+"' | head -n1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
            rdap_url=$(curl -s -o /dev/null -w '%{url_effective}' -L --max-time 8 "https://rdap.org/ip/${qip}" 2>/dev/null)
            case "$rdap_url" in *afrinic*) rir="AFRINIC" ;; *arin*) rir="ARIN" ;; *ripe*) rir="RIPE" ;; *apnic*) rir="APNIC" ;; *lacnic*) rir="LACNIC" ;; esac
            if [ -n "$rir$regdate$startaddr" ]; then
                G[ip_reg_rir]=$rir; G[ip_reg_date]=$regdate; G[ip_range_start]=$startaddr
                kv "$(L ipreg 'IP 段注册')" "${startaddr:+${startaddr}}${rir:+ · ${rir}}${regdate:+ · $(L regd '注册于') ${regdate}}${C_DIM} (RDAP)${C_OFF}"
            fi
        fi
    fi
    kv "商家"       "$name  ${C_DIM}[来源:$source]${C_OFF}"
    [ -n "$upstream_note" ] && warn "$upstream_note"
    kv "机房位置"   "${G[loc_country]:-?} ${G[loc_region]:-} ${G[loc_city]:-} ${G[colo]:+(CF节点 ${G[colo]})}"
    kv "IPv4"       "${ip4:-无}"
    kv "IPv6"       "${ip6:-无}"
    kv "ASN"        "${G[as_full]:-未知}"
    # ASN 邻居/前缀概况(RIPEstat 公共 API,参考 NetQuality BGP 组的轻量版)
    if [ -n "${G[asn_num]:-}" ]; then
        local rj nb_n="" pf_n=""
        rj=$(hq_curl "https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS${G[asn_num]}&lod=0" 8)
        [ -n "$rj" ] && nb_n=$(printf '%s' "$rj" | grep -oE '"asn":[0-9]+' | wc -l)
        rj=$(hq_curl "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${G[asn_num]}&lod=0" 8)
        [ -n "$rj" ] && pf_n=$(printf '%s' "$rj" | grep -oE '"prefix":"[^"]+"' | wc -l)
        if [ -n "$nb_n" ] && [ "$nb_n" -gt 0 ] 2>/dev/null; then
            G[asn_neighbours]=$nb_n
            [ -n "$pf_n" ] && [ "$pf_n" -gt 0 ] 2>/dev/null && G[asn_prefixes]=$pf_n
            kv "$(L asninfo 'ASN 概况')" "AS${G[asn_num]}: $(L asnnb '邻居') ${nb_n}${G[asn_prefixes]:+ · $(L asnpf '前缀') ${G[asn_prefixes]}}${C_DIM} (RIPEstat)${C_OFF}"
        fi
    fi
    [ -n "${G[ptr]:-}" ] && kv "PTR" "${G[ptr]}"
    [ -n "${PROV_META_DETAIL:-}" ] && kv "Metadata" "$PROV_META_DETAIL"
}
# ============================================================
# M2 性能:CPU 跑分(sha256 循环,零依赖) + 磁盘(dd / fio)
# ============================================================

# 单个工作线程:持续 sha256 小数据块,返回完成次数
cpu_bench_worker() {
    local blk=$1 dur=$2 n=0 i
    local end=$((SECONDS + dur))
    while [ "$SECONDS" -lt "$end" ]; do
        i=0
        while [ "$i" -lt 25 ]; do
            sha256sum "$blk" >/dev/null 2>&1 || break 2
            i=$((i + 1))
        done
        n=$((n + 25))
    done
    printf '%s' "$n"
}

# CPU 评级标签(按本项目 sha256 体系标定,仅作直观参考)
cpu_rating() { # <分数> -> 优秀/良好/中等/入门/较弱
    local v=$1
    is_num "$v" || { printf '%s' "-"; return; }
    awk -v v="$v" 'BEGIN{
        if (v>=800)      print "优秀";
        else if (v>=500) print "良好";
        else if (v>=300) print "中等";
        else if (v>=150) print "入门";
        else             print "较弱";
    }'
}

# 内存带宽(tmpfs dd 读写,零依赖;无 /dev/shm 或内存余量不足时跳过)
# v2.6:不再跟随低资源模式跳过(测试块已按余量收缩,256MB 即可测),余量下限降为 256MB
mem_bench() {
    G[mem_w_mb]=""; G[mem_r_mb]=""
    [ -d /dev/shm ] || return 1
    command -v df >/dev/null 2>&1 || return 1
    local mem_avail shm_free f o spd
    mem_avail=$(awk '/^MemAvailable:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    # tmpfs 写入直接消耗 RAM:余量 <256MB 不测,且文件 ≤ 余量 25%
    is_num "$mem_avail" && [ "$mem_avail" -ge 256 ] || { note "内存余量 ${mem_avail:-?}MB,跳过内存带宽测试"; return 1; }
    shm_free=$(df -Pm /dev/shm 2>/dev/null | awk 'NR==2{print $4}')
    is_num "$shm_free" || return 1
    local sz_mb=96
    [ "$HQ_MODE" = tiny ] && sz_mb=16
    [ $((mem_avail * 25 / 100)) -lt "$sz_mb" ] && sz_mb=$((mem_avail * 25 / 100))
    [ $((shm_free * 60 / 100)) -lt "$sz_mb" ] && sz_mb=$((shm_free * 60 / 100))
    [ "$sz_mb" -lt 8 ] && return 1
    G[mem_sz_mb]=$sz_mb
    f=/dev/shm/hq_memtest.$$
    local _t0 _t1
    _t0=$(_now_s)
    o=$(dd if=/dev/zero of="$f" bs=1M count="$sz_mb" ${DD_SYNC:+$DD_SYNC} 2>&1)
    _t1=$(_now_s)
    spd=$(dd_speed "$o" "$sz_mb" "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN{printf "%.3f", b-a}')"); is_num "$spd" && G[mem_w_mb]=$spd
    _t0=$(_now_s)
    o=$(dd if="$f" of=/dev/null bs=1M 2>&1)
    _t1=$(_now_s)
    spd=$(dd_speed "$o" "$sz_mb" "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN{printf "%.3f", b-a}')"); is_num "$spd" && G[mem_r_mb]=$spd
    rm -f "$f" 2>/dev/null
    [ -n "${G[mem_w_mb]}" ] || [ -n "${G[mem_r_mb]}" ]
}

mod_cpu() {
    sec "$(L cpu 'CPU 性能') CPU Benchmark"
    local dur=8 rounds=1
    if [ "$HQ_MODE" = full ]; then dur=10; rounds=2; fi   # 2 轮×10s 已稳定(sha256 吞吐波动小),较 3 轮缩短 20s
    if [ "$HQ_MODE" = tiny ] || [ "$OPT_LOWRES" = 1 ]; then dur=5; rounds=1; fi
    local blk="$HQ_TMP/cpu_blk"
    dd if=/dev/urandom of="$blk" bs=16k count=1 status=none 2>/dev/null || { warn "无法生成测试数据块"; return 1; }

    local threads=${G[cpu_threads]:-1}
    local total_single=0 total_multi=0 r t sum out
    for r in $(seq 1 "$rounds"); do
        out=$(cpu_bench_worker "$blk" "$dur")
        total_single=$((total_single + out))
        local -a pids=()
        rm -f "$HQ_TMP"/cpu_w.* 2>/dev/null
        for t in $(seq 1 "$threads"); do
            cpu_bench_worker "$blk" "$dur" >"$HQ_TMP/cpu_w.$t" &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null
        sum=0
        for t in $(seq 1 "$threads"); do
            [ -s "$HQ_TMP/cpu_w.$t" ] && sum=$((sum + $(cat "$HQ_TMP/cpu_w.$t")))
        done
        total_multi=$((total_multi + sum))
    done
    rm -f "$HQ_TMP"/cpu_w.* "$blk" 2>/dev/null

    G[cpu_score_single]=$((total_single / (dur * rounds)))
    G[cpu_score_multi]=$((total_multi / (dur * rounds)))
    local ratio="-"
    [ "$threads" -gt 1 ] && ratio=$(awk -v a="${G[cpu_score_single]}" -v b="${G[cpu_score_multi]}" 'BEGIN{printf "%.1f", b/a}')
    G[cpu_ratio]=$ratio

    # 内存带宽(共享内存盘读写)
    if mem_bench; then
        kv "内存带宽" "写 $(fmt_mb "${G[mem_w_mb]}") / 读 $(fmt_mb "${G[mem_r_mb]}") (tmpfs ${G[mem_sz_mb]}MB)"
    fi

    kv "单线程得分" "${G[cpu_score_single]} 分 ($(cpu_rating "${G[cpu_score_single]}"), sha256/s, ${dur}s×${rounds})"
    kv "${threads} 线程得分" "${G[cpu_score_multi]} 分 ($(cpu_rating "${G[cpu_score_multi]}") ÷${threads}, 并行比 $ratio)"
    if [ "${OPT_GB:-0}" = 1 ]; then
        warn "Geekbench 已移除:其 CLI 会把结果提交到厂商服务器,与本地留档原则不符"
    fi
}

# 计时兜底:bash5 EPOCHREALTIME,无该变量时回退 /proc/uptime
_now_s() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        awk -v t="$EPOCHREALTIME" 'BEGIN{printf "%.3f", t}'
    else
        awk '{printf "%.3f", $1}' /proc/uptime 2>/dev/null
    fi
}

# 解析 dd 输出的速度(MB/s,两位小数);busybox/非常规输出时按入参耗时计算
dd_speed() {  # <dd命令完整输出含stderr> [块MB] [耗时秒(可选,解析失败时启用)]
    local o=$1 bsmb=${2:-0} el=${3:-}
    local secs spd
    secs=$(printf '%s' "$o" | grep -oE 'copied, [0-9.]+ s' | grep -oE '[0-9.]+')
    [ -z "$secs" ] && secs=$(printf '%s' "$o" | grep -oE 'in [0-9.]+ secs' | grep -oE '[0-9.]+')
    spd=$(printf '%s' "$o" | grep -oE '\([0-9.]+ [kMG]B/s\)' | tr -d '()')
    if [ -n "$spd" ]; then
        awk -v s="$spd" 'BEGIN{
            if (s ~ /GB\/s/) { sub(/GB\/s/,"",s); printf "%.2f", s*1024 }
            else if (s ~ /kB\/s/) { sub(/kB\/s/,"",s); printf "%.2f", s/1024 }
            else { sub(/MB\/s/,"",s); printf "%.2f", s }
        }'
    elif [ -n "$secs" ] && [ "$secs" != 0 ]; then
        awk -v b="$bsmb" -v t="$secs" 'BEGIN{printf "%.2f", b/t}'
    elif [ -n "$el" ] && awk -v t="$el" 'BEGIN{exit !(t>0.01)}'; then
        awk -v b="$bsmb" -v t="$el" 'BEGIN{printf "%.2f", b/t}'
    else
        printf ''
    fi
}

# 磁盘介质类型识别(NVMe/SSD/HDD;参考 HardwareQuality Disk 组的轻量版)
detect_disk_type() {
    local src dev rot
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || src=$(df -P / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$src" ] || { printf ''; return; }
    dev=${src##*/}; dev=${dev%%[0-9]*}
    case "$dev" in
        nvme*)  printf 'NVMe SSD'; return ;;
        loop*|ram*) printf ''; return ;;
        vd*|xvd*)
            # virtio 云盘的 rotational 是驱动默认值,不反映物理介质
            printf '云盘(virtio)'; return ;;
    esac
    rot=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)
    [ "$rot" = 0 ] && printf 'SSD'
    [ "$rot" = 1 ] && printf 'HDD'
}

mod_disk() {
    sec "$(L disk '磁盘性能') Disk IO"
    G[disk_type]=$(detect_disk_type)
    local tdir="$HQ_TMP" f="$HQ_TMP/hq_disktest"
    # /tmp 若为 tmpfs(内存盘)则改测当前目录所在磁盘
    if command -v findmnt >/dev/null 2>&1 && [ "$(findmnt -n -o FSTYPE /tmp 2>/dev/null)" = "tmpfs" ]; then
        tdir="$PWD/hq_disktest_dir"
        if mkdir -p "$tdir"; then
            HQ_TDISK="$tdir"   # 标记给 cleanup():中途被打断也能清掉
        else
            tdir="$HQ_TMP"
        fi
        f="$tdir/hq_disktest"
        note "/tmp 为 tmpfs,改测 ${tdir} 所在磁盘"
    fi
    # 容量保护:测试文件不超过剩余空间 60%
    local avail_mb
    avail_mb=$(df -Pm "$tdir" 2>/dev/null | awk 'NR==2{print $4}')
    avail_mb=${avail_mb:-0}
    local sz_mb=256
    [ "$HQ_MODE" = full ] && sz_mb=1024
    [ "$HQ_MODE" = tiny ] && sz_mb=48
    [ "$OPT_LOWRES" = 1 ] && sz_mb=$((sz_mb / 2))
    [ $((avail_mb * 60 / 100)) -lt "$sz_mb" ] && sz_mb=$((avail_mb * 60 / 100))
    # 低内存且无 swap 时,写盘文件再受内存余量约束(避免脏页把小机压死)
    local mem_avail_mb swap_free_mb
    mem_avail_mb=$(awk '/^MemAvailable:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    swap_free_mb=$(awk '/^SwapFree:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    if is_num "$mem_avail_mb" && is_num "$swap_free_mb" && [ "$swap_free_mb" -lt 256 ]; then
        [ $((mem_avail_mb * 80 / 100)) -lt "$sz_mb" ] && sz_mb=$((mem_avail_mb * 80 / 100))
    fi
    local min_sz=64
    [ "$HQ_MODE" = tiny ] && min_sz=24
    if [ "$sz_mb" -lt "$min_sz" ]; then
        warn "磁盘剩余空间不足(${avail_mb}MB),跳过磁盘测试"
        return 1
    fi

    local o spd
    # 4K 小块写(常规 32MB / 极小 8MB,慢盘也可控)
    local t4mb=32
    [ "$HQ_MODE" = tiny ] && t4mb=8
    local c4=$((t4mb * 1024 / 4))
    o=$(dd if=/dev/zero of="$f" bs=4k count=$c4 ${DD_SYNC:+$DD_SYNC} 2>&1)
    spd=$(dd_speed "$o" "$t4mb")
    G[disk_4k_w]=$spd
    [ -n "${G[disk_type]:-}" ] && kv "$(L dtype '介质')" "${G[disk_type]}"
    kv "4K 小块写" "$(fmt_mb "$spd")"

    # 1M 顺序写
    o=$(dd if=/dev/zero of="$f" bs=1M count="$sz_mb" ${DD_SYNC:+$DD_SYNC} 2>&1)
    spd=$(dd_speed "$o" "$sz_mb")
    G[disk_1m_w]=$spd
    kv "顺序写(${sz_mb}MB)" "$(fmt_mb "$spd")"

    # 1M 顺序读(优先 O_DIRECT,绕过缓存)
    o=$(dd if="$f" of=/dev/null bs=1M iflag=direct 2>&1)
    if printf '%s' "$o" | grep -qE 'invalid argument|direct'; then
        o=$(dd if="$f" of=/dev/null bs=1M 2>&1)
        G[disk_1m_r]=$(dd_speed "$o" "$sz_mb")
        G[disk_1m_r_cached]=1
    else
        G[disk_1m_r]=$(dd_speed "$o" "$sz_mb")
    fi
    kv "顺序读(Direct)" "$(fmt_mb "${G[disk_1m_r]:-}")${G[disk_1m_r_cached]:+ ${C_DIM}(缓存)${C_OFF}}"
    rm -f "$f" 2>/dev/null

    # fio 磁盘测试(YABS 预编译静态二进制):完整=4 档×8s;精简=4K 快速 6s;tiny 跳过
    # v2.7:低资源模式不再整体跳过(direct=1 直写不占页缓存),仅压缩测试文件尺寸
    if [ "$HQ_MODE" != tiny ] && [ -n "$HQ_YABSARCH" ]; then
        local fio_cap=""
        [ "$OPT_LOWRES" = 1 ] && fio_cap=256
        if [ "$HQ_MODE" = full ]; then
            run_fio "$tdir" "$avail_mb" full "$fio_cap"
        else
            run_fio "$tdir" "$avail_mb" quick "$fio_cap"
        fi
    fi
    if [ "$tdir" = "$PWD/hq_disktest_dir" ]; then
        rm -rf "$tdir" 2>/dev/null
        HQ_TDISK=""
    fi
}

# IOPS 文本("4070"/"12.3k"/"1.2M")→ 整数
iops_num() {
    local v=${1:-}
    case "$v" in
        ""|"?") return 1 ;;
        *k) v=$(awk -v x="${v%k}" 'BEGIN{printf "%.0f", x*1000}') ;;
        *M) v=$(awk -v x="${v%M}" 'BEGIN{printf "%.0f", x*1000000}') ;;
    esac
    is_num "$v" || return 1
    printf '%s' "$v"
}

run_fio() { # <tdir> <avail_mb> [full|quick] [cap_mb(低资源模式压缩)]
    local tdir=$1 avail_mb=$2 fio_mode=${3:-full} fio_cap=${4:-0}
    local -a fio_bs=(4k 64k 512k 1m)
    local fio_rt=8   # 8s/档足以让 iodepth=64 进入稳态,较 12s 缩短总时长
    [ "$fio_mode" = quick ] && { fio_bs=(4k); fio_rt=6; }
    local fio_bin="$HQ_BIN/fio"
    if ! command -v fio >/dev/null 2>&1; then
        if [ ! -s "$fio_bin" ]; then
            local url="https://github.com/masonr/yet-another-bench-script/releases/download/fio-3.42/fio_${HQ_YABSARCH}"
            note "下载 fio 静态二进制..."
            hq_download "$url" "$fio_bin" || { warn "fio 下载失败,跳过详细磁盘测试"; return 1; }
            chmod +x "$fio_bin" 2>/dev/null
        fi
        fio_bin="$fio_bin"
    else
        fio_bin=$(command -v fio)
    fi
    local f="$tdir/hq_fio" sz=$(( avail_mb * 40 / 100 ))
    [ "$sz" -lt 256 ] && sz=256
    [ "$sz" -gt 2048 ] && sz=2048   # 2048M 足以承载 4 档测试,同时缩短大磁盘上的文件准备时间
    # 低资源模式:文件封顶(4K 档 256M 足够承载 iodepth=64)
    is_num "$fio_cap" && [ "$fio_cap" -gt 0 ] 2>/dev/null && [ "$sz" -gt "$fio_cap" ] && sz=$fio_cap
    local bs out rd wr riops wiops
    for bs in "${fio_bs[@]}"; do
        local out2=""
        if [ "$bs" = 4k ]; then
            # 4K 档读/写分开跑:randrw 混合作业两向同源,读写 IOPS 恒等无参考性
            out=$("$fio_bin" --name=hq --filename="$f" --size=${sz}M --bs=$bs --rw=randread \
                  --direct=1 --ioengine=libaio --iodepth=64 --gtod_reduce=1 --group_reporting \
                  --runtime=$fio_rt --time_based 2>&1) || { warn "fio $bs 读测试失败"; continue; }
            out2=$("$fio_bin" --name=hq --filename="$f" --size=${sz}M --bs=$bs --rw=randwrite \
                  --direct=1 --ioengine=libaio --iodepth=64 --gtod_reduce=1 --group_reporting \
                  --runtime=$fio_rt --time_based 2>&1) || out2=""
        else
            out=$("$fio_bin" --name=hq --filename="$f" --size=${sz}M --bs=$bs --rw=randrw --rwmixread=50 \
                  --direct=1 --ioengine=libaio --iodepth=64 --gtod_reduce=1 --group_reporting \
                  --runtime=$fio_rt --time_based 2>&1) || { warn "fio $bs 测试失败"; continue; }
        fi
        rd=$(printf '%s' "$out"  | grep -E '^\s*read\s*:'  | grep -oE '\([0-9.]+[kMG]?B/s\)'  | head -n1 | grep -oE '[0-9.]+' | head -n1)
        riops=$(printf '%s' "$out" | grep -E '^\s*read\s*:'  | grep -oE 'IOPS=[0-9.km]+' | head -n1 | cut -d= -f2)
        if [ -n "$out2" ]; then
            wr=$(printf '%s' "$out2" | grep -E '^\s*write\s*:' | grep -oE '\([0-9.]+[kMG]?B/s\)' | head -n1 | grep -oE '[0-9.]+' | head -n1)
            wiops=$(printf '%s' "$out2" | grep -E '^\s*write\s*:' | grep -oE 'IOPS=[0-9.km]+' | head -n1 | cut -d= -f2)
        else
            wr=$(printf '%s' "$out"  | grep -E '^\s*write\s*:' | grep -oE '\([0-9.]+[kMG]?B/s\)'  | head -n1 | grep -oE '[0-9.]+' | head -n1)
            wiops=$(printf '%s' "$out" | grep -E '^\s*write\s*:' | grep -oE 'IOPS=[0-9.km]+' | head -n1 | cut -d= -f2)
        fi
        # fio 括号内为 MB/s(大写 M = 10^6);4k/64k 数值小,G/M 前缀处理
        local mul=1
        printf '%s' "$out" | grep -E '^\s*read\s*:' | grep -q 'GiB/s' && mul=1024
        local rdm wdm
        rdm=$(awk -v v="${rd:-0}" -v m="$mul" 'BEGIN{printf "%.1f", v*m}')
        wdm=$(awk -v v="${wr:-0}" -v m="$mul" 'BEGIN{printf "%.1f", v*m}')
        FIO_ROWS+=("$bs|$rdm|$wdm|${riops:-?}|${wiops:-?}")
        # 4K IOPS 供评分使用(v2.7:DD 4K 写走页缓存虚高,FIO 直写才是真实随机性能)
        if [ "$bs" = 4k ]; then
            iops_num "$riops" >/dev/null && G[fio4k_ri]=$(iops_num "$riops")
            iops_num "$wiops" >/dev/null && G[fio4k_wi]=$(iops_num "$wiops")
        fi
        printf '  %-8s 读 %10s  写 %10s  (IOPS 读:%s 写:%s)\n' "$bs" "$(fmt_mb "$rdm")" "$(fmt_mb "$wdm")" "${riops:-?}" "${wiops:-?}"
    done
    rm -f "$f" 2>/dev/null
}
# ============================================================
# M3 网络:延迟探测 + 带宽测速(speedtest-go + 三网对象存储)
# ============================================================

# ---- 并发治理:小进程数限额的容器(Alpine/LXC/OpenVZ)避免 "fork: retry: Resource temporarily unavailable" ----
# 所有网络扇出点通过 hq_throttle 限槽,单模块某项探测失败只影响该项(页面如实标待测试),不中断后续检测
# cgroup pids 控制器文件定位(v2: pids.max / v1: pids/pids.max,含 /proc/self/cgroup 定位的嵌套路径)
hq_cgroup_file() { # <基名 pids.max|pids.current> -> 首个可读路径(失败返回1)
    local base=$1 line p
    for p in "/sys/fs/cgroup/$base" "/sys/fs/cgroup/pids/$base"; do
        [ -r "$p" ] && { printf '%s' "$p"; return 0; }
    done
    if [ -r /proc/self/cgroup ]; then
        while IFS= read -r line; do
            case "$line" in
                *:pids:*) p="/sys/fs/cgroup/pids${line#*:pids:}/$base" ;;
                0::*)    p="/sys/fs/cgroup${line#0::}/$base" ;;
                *) continue ;;
            esac
            [ -r "$p" ] && { printf '%s' "$p"; return 0; }
        done </proc/self/cgroup
    fi
    return 1
}

# 模块边界调用:按 PID 余量动态收缩并发——一旦余量不足,fork 会触发 bash 的
# "fork: retry" 指数退避(每次失败约 31s),整段检测会像卡死一样,提前收缩可完全避免
hq_pids_adjust() {
    local cf mf cur max hr
    cf=$(hq_cgroup_file pids.current) || return 0
    mf=$(hq_cgroup_file pids.max) || return 0
    cur=$(tr -d '[:space:]' <"$cf" 2>/dev/null)
    max=$(tr -d '[:space:]' <"$mf" 2>/dev/null)
    is_num "$cur" && is_num "$max" || return 0
    hr=$(( max - cur ))
    if [ "$hr" -lt 16 ]; then
        HQ_NET=2; HQ_PAR=1
    elif [ "$hr" -lt 40 ]; then
        [ "${HQ_NET:-8}" -gt 4 ] && HQ_NET=4
        [ "${HQ_PAR:-4}" -gt 2 ] && HQ_PAR=2
    fi
    export HQ_PAR HQ_NET
}

hq_par_init() { # 计算并发槽位(环境变量可覆盖):HQ_PAR=CPU 型基准,按 cgroup pids.max / RLIMIT_NPROC 收窄;
    #             HQ_NET=网络 I/O 型扇出(握手/DNS/轻请求),按 3×HQ_PAR 放宽至 8..24,避免小核机器被 nproc 过度限流
    if ! { is_num "${HQ_PAR:-}" && [ "${HQ_PAR:-0}" -ge 1 ] 2>/dev/null; }; then
        local np pl
        np=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
        is_num "$np" || np=4
        [ "$np" -gt 8 ] && np=8
        [ "$np" -lt 2 ] && np=2
        HQ_PAR=$np
        # cgroup PID 限额(v2/v1,含嵌套路径):预留系统进程后按 1/8 收窄
        pl=$(hq_cgroup_file pids.max) && pl=$(tr -d '[:space:]' <"$pl" 2>/dev/null)
        if is_num "${pl:-}"; then
            pl=$(( (pl - 20) / 8 ))
            [ "$pl" -lt "$HQ_PAR" ] && HQ_PAR=$pl
        fi
        # RLIMIT_NPROC:普通机器为大数不参与;OpenVZ 等返回真实限额时收窄
        pl=$(ulimit -u 2>/dev/null)
        if is_num "$pl" && [ "$pl" -lt 1024 ]; then
            pl=$(( (pl - 20) / 8 ))
            [ "$pl" -lt "$HQ_PAR" ] && HQ_PAR=$pl
        fi
        [ "$HQ_PAR" -lt 1 ] && HQ_PAR=1
    fi
    if ! { is_num "${HQ_NET:-}" && [ "${HQ_NET:-0}" -ge 1 ] 2>/dev/null; }; then
        HQ_NET=$(( HQ_PAR * 3 ))
        [ "$HQ_NET" -lt 8 ] && HQ_NET=8
        [ "$HQ_NET" -gt 24 ] && HQ_NET=24
        # PID 限额下网络扇出同样收窄(每槽 1-2 进程,预留 40 给系统/主 shell)
        pl=$(hq_cgroup_file pids.max) && pl=$(tr -d '[:space:]' <"$pl" 2>/dev/null)
        if is_num "${pl:-}" && [ "$pl" -gt 48 ]; then
            pl=$(( (pl - 40) / 4 ))
            [ "$pl" -gt 0 ] && [ "$pl" -lt "$HQ_NET" ] && HQ_NET=$pl
        fi
    fi
    export HQ_PAR HQ_NET
}

hq_throttle() { # 后台并发槽位:当前 shell 在跑的后台作业数达到上限时等待释放(可传自定义上限;默认网络扇出 HQ_NET)
    local cap=${1:-${HQ_NET:-8}}
    [ "$cap" -ge 1 ] 2>/dev/null || return 0
    while [ "$(jobs -rp | wc -l)" -ge "$cap" ]; do
        wait -n 2>/dev/null   # bash>=4.3 等待任一作业;更老版本由下方轮询兜底
        sleep 0.1
    done
}

PING_TARGETS_V4=(
    "中国电信·上海|202.96.209.133"
    "中国电信·成都|61.139.2.69"
    "中国联通·北京|61.135.169.121"
    "中国联通·广东|210.21.4.130"
    "中国移动·上海|211.136.112.50"
    "中国移动·广东|120.196.165.24"
    "教育网·清华|202.112.0.35"
    "阿里DNS|223.5.5.5"
    "腾讯DNS|119.29.29.29"
    "114DNS|114.114.114.114"
    "Cloudflare|1.1.1.1"
    "Quad9|9.9.9.9"
    "OpenDNS|208.67.222.222"
    "Google|8.8.8.8"
)
PING_TARGETS_V6=(
    "阿里DNS v6|2400:3200::9"
    "Cloudflare v6|2606:4700:4700::1111"
    "Google v6|2001:4860:4860::8888"
)

# IPv6 目标解析:多解析器回退(阿里→腾讯→系统)+ 12h 磁盘缓存;
# 三网延迟/大小包/回程线路三个 v6 块共用,单解析器瞬时超时不再各自失败
dig6() { # <hostname> -> 首个全局 v6 地址(空=未解析)
    local h=$1 d="$HQ_HOME/v6dns" f _rs _ip
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
    f="$d/$(printf '%s' "$h" | tr '/:' '__')"
    if [ -s "$f" ] && [ -z "$(find "$f" -mmin +720 2>/dev/null)" ]; then
        printf '%s' "$(cat "$f")"; return 0
    fi
    for _rs in @223.5.5.5 @119.29.29.29 ""; do
        _ip=$(dig +short +time=2 +tries=1 AAAA "$h" $_rs 2>/dev/null \
            | grep -Ei '^([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}$' \
            | grep -viE '^(fe80:|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|::1)$' | head -n1)
        if [ -n "$_ip" ]; then
            printf '%s' "$_ip" >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
            printf '%s' "$_ip"; return 0
        fi
    done
    # 仅 dig 缺失时回退(查询失败不回退):域名不存在的候选省份循环
    # 不会被 getent/DoH 逐个拖慢;无 dig 的机器则整体走 resolve_host_ip6 链
    if ! command -v dig >/dev/null 2>&1; then
        _ip=$(resolve_host_ip6 "$h" | grep -viE '^(fe80:|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|::1)$')
        if [ -n "$_ip" ]; then
            printf '%s' "$_ip" >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
            printf '%s' "$_ip"; return 0
        fi
    fi
    return 1
}

ping_cmd_for() {
    if ip_is_v6 "$1"; then
        if ping -6 -c1 -W1 ::1 >/dev/null 2>&1; then printf 'ping -6'
        elif command -v ping6 >/dev/null 2>&1; then printf 'ping6'
        else printf 'ping'; fi
    else
        printf 'ping'
    fi
}

ping_one() { # <名称> <ip> <输出文件>
    local name=$1 ip=$2 out=$3 n=8
    local cmd; cmd=$(ping_cmd_for "$ip")
    local o
    o=$($cmd -c "$n" -i 0.2 -W 1 "$ip" 2>/dev/null) || o=$($cmd -c "$n" -W 1 "$ip" 2>&1) || o=$($cmd -c "$n" "$ip" 2>&1)
    local avg loss rtts jitter
    loss=$(printf '%s' "$o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
    avg=$(printf '%s' "$o" | grep -oE '(min/avg/max(/mdev)? = )[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+$' | head -n1)
    # 逐包 RTT:自算抖动(相邻差均值),兼容 busybox(无 mdev 摘要行)
    rtts=$(printf '%s' "$o" | grep -oE 'time[=<][0-9.]+' | grep -oE '[0-9.]+$' | paste -sd, -)
    jitter=$(printf '%s' "$rtts" | awk -F, 'NF>1{d=0;for(i=2;i<=NF;i++){v=$i-$(i-1);if(v<0)v=-v;d+=v};printf "%.1f", d/(NF-1)}')
    printf '%s|%s|%s|%s|%s|%s' "$name" "$ip" "${avg:-}" "${loss:-100}" "${jitter:-}" "${rtts:-}" >"$out"
}

# TCP 握手延迟:ICMP 被限速/禁 ping 时的补充视角
# 目标为三网 TOS 对象存储入口(443 必开),零依赖 curl 计时
TCP_PING_TARGETS=(
    "电信·TOS|42.81.80.86"
    "联通·TOS|221.194.175.109"
    "移动·TOS|120.255.0.180"
)

tcp_ping_one() { # <名称> <ip> <探测次数> <输出文件> :N 次并行握手,汇总 延迟/失败率/逐次RTT
    local name=$1 ip=$2 probes=$3 out=$4 i t ms sum="" fail=0
    local pcap=$(( ${HQ_PAR:-8} / 2 )); [ "$pcap" -lt 1 ] && pcap=1   # 每方向并发握手减半,多方向叠加时防 fork 耗尽
    local -a pj=()
    local hip="$ip"
    case "$ip" in *:*) hip="[$ip]" ;; esac
    for i in $(seq 1 "$probes"); do
        (
            t=$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 2 --max-time 2 \
                "telnet://${hip}:443" </dev/null 2>/dev/null)
            if is_num "$t" && awk -v m="$t" 'BEGIN{exit !(m>0.001)}'; then
                printf '%s' "$(awk -v m="$t" 'BEGIN{printf "%.1f", m*1000}')"
            fi
        ) >"${out}.$i" &
        pj+=($!)
        hq_throttle "$pcap"
    done
    wait "${pj[@]}" 2>/dev/null
    for i in $(seq 1 "$probes"); do
        ms=$(cat "${out}.$i" 2>/dev/null)
        rm -f "${out}.$i"
        if [ -n "$ms" ]; then
            sum="${sum:+$sum }$ms"
        else
            fail=$((fail+1))
        fi
    done
    local avg=""
    [ -n "$sum" ] && avg=$(awk -v s="$sum" 'BEGIN{n=split(s,a," ");t=0;for(i=1;i<=n;i++)t+=a[i];printf "%.1f", t/n}')
    printf '%s|%s|%s|%s|%s' "$name" "$ip" "$avg" "$((fail*100/probes))" "$(printf '%s' "$sum" | tr ' ' ',')" >"$out"
}

mod_ping() {
    sec "$(L ping '网络延迟') Latency"
    local -a jobs=() files=()
    local t name ip i=0
    if [[ $OPT_IPV == *4* ]]; then
        for t in "${PING_TARGETS_V4[@]}"; do
            IFS='|' read -r name ip <<< "$t"
            ping_one "$name" "$ip" "$HQ_TMP/ping.$i" & jobs+=($!); files+=("$HQ_TMP/ping.$i"); i=$((i+1)); hq_throttle
        done
    fi
    if [[ $OPT_IPV == *6* ]] && [ -n "${G[ip6]:-}" ]; then
        for t in "${PING_TARGETS_V6[@]}"; do
            IFS='|' read -r name ip <<< "$t"
            ping_one "$name" "$ip" "$HQ_TMP/ping.$i" & jobs+=($!); files+=("$HQ_TMP/ping.$i"); i=$((i+1)); hq_throttle
        done
    fi
    # TCP 握手探测与 ICMP 并行(逐包统计:精简 5 探测/完整 10/极小 2,同方向并行发起)
    local -a tcp_files=() tcp_jobs=()
    local probes=5
    [ "$HQ_MODE" = full ] && probes=10
    [ "$HQ_MODE" = tiny ] && probes=2
    if [[ $OPT_IPV == *4* ]]; then
        local j=0
        for t in "${TCP_PING_TARGETS[@]}"; do
            IFS='|' read -r name ip <<< "$t"
            tcp_ping_one "$name" "$ip" "$probes" "$HQ_TMP/tcpping.$j" & tcp_jobs+=($!); tcp_files+=("$HQ_TMP/tcpping.$j"); j=$((j+1)); hq_throttle
        done
    fi
    # IPv6 TCP 握手(回程质量 v6 卡 TCP 行):TOS 公网入口无 AAAA(v4-only),
    # 改用三大运营商自有地址段(240e/2408/2409)的门户 v6 入口分运营商探测;
    # telnet:// 仅完成 TCP 三次握手,不依赖 HTTP 业务可用
    local -a tcp6_files=()
    if [ -n "${G[ip6]:-}" ] && [[ $OPT_IPV == *6* ]]; then
        local -a P6N=(电信 联通 移动) P6H=(www.189.cn www.wo.cn www.10086.cn)
        local p6i p6ip
        for ((p6i=0; p6i<3; p6i++)); do
            (
                p6ip=$(resolve_host_ip6 "${P6H[$p6i]}")
                [ -n "$p6ip" ] && tcp_ping_one "${P6N[$p6i]}·门户v6" "$p6ip" "$probes" "$HQ_TMP/tcpping6.$p6i"
            ) & tcp_jobs+=($!); tcp6_files+=("$HQ_TMP/tcpping6.$p6i"); hq_throttle
        done
    fi
    wait ${jobs[@]+"${jobs[@]}"} 2>/dev/null
    wait ${tcp_jobs[@]+"${tcp_jobs[@]}"} 2>/dev/null

    local row name ip avg loss jit rtts
    for f in "${files[@]}"; do
        [ -s "$f" ] || continue
        IFS='|' read -r name ip avg loss jit rtts <"$f"
        [ -z "$avg" ] && [ "$loss" = 100 ] && continue
        PING_ROWS+=("$name|$ip|$avg|$loss|$jit|$rtts")
        local mark="$C_GREEN"
        [ -z "$avg" ] && mark="$C_RED"
        printf '  %-16s %-20s %s%10s%s  %s %s%%  %s %s\n' "$name" "$ip" "$mark" "$(fmt_ms "$avg")" "$C_OFF" \
            "$(L loss '丢包')" "$loss" "$(L jitk '抖动')" "${jit:+±$(fmt_ms "$jit")}"
        rm -f "$f"
    done
    # TCP 握手结果
    local tip tavg tfail trtts tname f
    for f in "${tcp_files[@]}"; do
        [ -s "$f" ] || continue
        IFS='|' read -r tname tip tavg tfail trtts <"$f"
        TCP_ROWS+=("$tname|$tip|$tavg|$tfail|$trtts")
        local tmark="$C_GREEN"
        [ -z "$tavg" ] && tmark="$C_RED"
        printf '  %-16s %-20s %s%10s%s  %s %s%%  %s\n' "TCP $tname" "$tip" "$tmark" "$(fmt_ms "$tavg")" "$C_OFF" \
            "$(L failr '失败')" "$tfail" "${C_DIM}tcp/443${C_OFF}"
        rm -f "$f"
    done
    # IPv6 TCP 握手结果(回程质量 v6 卡 TCP 行;失败率=TCP 丢包率)
    for f in "${tcp6_files[@]}"; do
        [ -s "$f" ] || continue
        IFS='|' read -r tname tip tavg tfail trtts <"$f"
        TCP6_ROWS+=("$tname|$tip|$tavg|$tfail|$trtts")
        local v6mark="$C_GREEN"
        [ -z "$tavg" ] && v6mark="$C_RED"
        printf '  %-16s %-42s %s%10s%s  %s %s%%  %s\n' "TCP $tname" "$tip" "$v6mark" "$(fmt_ms "$tavg")" "$C_OFF" \
            "$(L failr '失败')" "$tfail" "${C_DIM}tcp/443${C_OFF}"
        rm -f "$f"
    done
    # 汇总:大陆方向平均延迟 + 平均抖动 + TCP 平均握手
    local cn_n=0 jit_sum=0 jit_n=0 r
    local -a cn_avgs=()
    [ ${#PING_ROWS[@]} -gt 0 ] && for r in "${PING_ROWS[@]}"; do
        IFS='|' read -r name ip avg loss jit _ <<< "$r"
        case "$name" in 中国*) is_num "$avg" && { cn_avgs+=("$avg"); cn_n=$((cn_n+1)); }
                                  is_num "$jit" && { jit_sum=$(awk -v a=$jit_sum -v b=$jit 'BEGIN{print a+b}'); jit_n=$((jit_n+1)); } ;; esac
    done
    if [ "$cn_n" -gt 0 ]; then
        # 中位数:算术平均会被个别低延迟节点拉偏(电信/联通 ~180ms 被移动 13ms 拉成 ~125ms)
        G[ping_cn_avg]=$(printf '%s\n' "${cn_avgs[@]}" | sort -n | awk '{a[NR]=$1} END{if(NR%2)printf "%.1f",a[(NR+1)/2]; else printf "%.1f",(a[NR/2]+a[NR/2+1])/2}')
        kv "$(L cn_avg '大陆方向延迟')" "$(fmt_ms "${G[ping_cn_avg]}") (${cn_n} $(L nodes '节点') · $(L median '中位数'))"
    fi
    if [ "$jit_n" -gt 0 ]; then
        G[ping_cn_jitter]=$(awk -v s=$jit_sum -v n=$jit_n 'BEGIN{printf "%.1f", s/n}')
        kv "$(L cn_jit '大陆平均抖动')" "±$(fmt_ms "${G[ping_cn_jitter]}")"
    fi
    local tcp_sum=0 tcp_n=0
    [ ${#TCP_ROWS[@]} -gt 0 ] && for r in "${TCP_ROWS[@]}"; do
        IFS='|' read -r name ip avg _ _ <<< "$r"
        is_num "$avg" && { tcp_sum=$(awk -v a=$tcp_sum -v b=$avg 'BEGIN{print a+b}'); tcp_n=$((tcp_n+1)); }
    done
    if [ "$tcp_n" -gt 0 ]; then
        G[tcp_cn_avg]=$(awk -v s=$tcp_sum -v n=$tcp_n 'BEGIN{printf "%.1f", s/n}')
        kv "$(L tcp_avg '大陆TCP握手均值')" "$(fmt_ms "${G[tcp_cn_avg]}") (${tcp_n} $(L dirs '方向'))"
    fi
    # NAT / UDP 出站检测
    nat_detect
    # 省份×三网延迟矩阵(完整模式)
    mod_provinces
    # IPv6 三网延迟行(原型 china 卡 v6 行:延迟/丢包实测,测速如实待检测)
    CHINA6_ROWS=()
    if [ -n "${G[ip6]:-}" ]; then
        local v6p=$(ping_cmd_for 2606:4700:4700::1111)
        if [ -n "$v6p" ]; then
            local -a c6n=(电信 联通 移动) c6c=(ct cu cm) j6=()
            local -a c6prov=(bj sh gd sn zj)
            local ci cc cn v6ip pv
            for ci in 0 1 2; do
                (
                    cc=${c6c[$ci]}; cn=${c6n[$ci]}
                    v6ip=""; _sent=0
                    for pv in "${c6prov[@]}"; do
                        _ip=$(dig6 "${pv}-${cc}-v6.ip.zstaticcdn.com")
                        [ -n "$_ip" ] || continue
                        _sent=1
                        $v6p -c 1 -W 1 "$_ip" >/dev/null 2>&1 && { v6ip=$_ip; break; }
                    done
                    if [ -n "$v6ip" ]; then :; elif [ "$_sent" = 1 ]; then printf '%s||100' "$cn"; exit 0; else printf '%s||' "$cn"; exit 0; fi
                    _o=$($v6p -c 4 -i 0.2 -W 1 "$v6ip" 2>/dev/null)
                    _l=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
                    # 100% 丢包复核一次(与 prov_ping_one 同口径,避开瞬时 ICMP 限速/抖动误判)
                    if [ -z "${_l:-}" ] || [ "${_l:-100}" -ge 100 ] 2>/dev/null; then
                        _o=$($v6p -c 2 -i 0.5 -W 1 "$v6ip" 2>/dev/null)
                        _l=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
                    fi
                    # 与 ping_one/prov_ping_one 同口径:[0-9./]+ 会把 min/avg/max/mdev
                    # 里的每个 / 匹配成独立空行,_a 带前导换行后 read 回读全丢
                    _a=$(printf '%s' "$_o" | grep -oE '(min/avg/max(/mdev)? = )[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+$' | head -n1)
                    printf '%s|%s|%s' "$cn" "${_a:-}" "${_l:-}"
                ) >"$HQ_TMP/cn6.$ci" &
                j6+=($!)
                hq_throttle
            done
            wait "${j6[@]}" 2>/dev/null
            for ci in 0 1 2; do
                if [ -s "$HQ_TMP/cn6.$ci" ]; then
                    IFS='|' read -r cn _a _l <"$HQ_TMP/cn6.$ci"
                    rm -f "$HQ_TMP/cn6.$ci"
                    CHINA6_ROWS+=("$cn|${_a:-}|${_l:-}")
                    printf '  %-14s %s(v6) %s%s%s %s\n' "中国$cn" "$(L lat '延迟')" "${C_GREEN}${_a:-—}ms${C_OFF}" "" "${_l:+${_l}%}"
                fi
            done
        fi
    fi
}

# ============================================================
# 省份延迟矩阵(完整模式):NetQuality 的 zstaticcdn 域名方案
# <省码>-{ct|cu|cm}-v4.ip.zstaticcdn.com 解析出省网内 IP 后 ICMP 4 包
# ============================================================
HQ_PROVINCES=(ah bj cq fj gd gs gx gz ha hb he hi hl hn jl js jx ln nm nx qh sc sd sh sn sx tj xj xz yn zj)
declare -A PROV_NAME=( [ah]=安徽 [bj]=北京 [cq]=重庆 [fj]=福建 [gd]=广东 [gs]=甘肃 [gx]=广西
    [gz]=贵州 [ha]=河南 [hb]=湖北 [he]=河北 [hi]=海南 [hl]=黑龙江 [hn]=湖南 [jl]=吉林 [js]=江苏
    [jx]=江西 [ln]=辽宁 [nm]=内蒙古 [nx]=宁夏 [qh]=青海 [sc]=四川 [sd]=山东 [sh]=上海 [sn]=陕西
    [sx]=山西 [tj]=天津 [xj]=新疆 [xz]=西藏 [yn]=云南 [zj]=浙江 )

# 域名 → IPv4 解析回退链(v2.6:海外/受限网络下单一阿里 DNS 可能全军覆没)
# 阿里DNS → 腾讯DNS → 系统 getent → DoH(阿里 JSON API → Cloudflare JSON API)
# 返回首个合法 IPv4;全部失败输出空串
resolve_host_ip() { # <host>
    local h=$1 ip r
    if command -v dig >/dev/null 2>&1; then
        for ns in 223.5.5.5 119.29.29.29 1.1.1.1; do
            ip=$(dig +short +time=2 +tries=1 "$h" @"$ns" 2>/dev/null \
                | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
            [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
        done
    elif command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup -type=A "$h" 2>/dev/null | grep -E '^Address( 1)?:' | tail -n+2 \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    fi
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | head -n1)
    case "$ip" in *[!0-9.]* | "") ;; *) printf '%s' "$ip"; return 0 ;; esac
    r=$(curl -s --noproxy '*' --connect-timeout 3 --max-time 5 \
        "https://223.5.5.5/resolve?name=${h}&type=A" 2>/dev/null \
        | grep -oE '"data"[ ]*:[ ]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | head -n1 \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    r=$(curl -s --noproxy '*' --connect-timeout 3 --max-time 5 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=${h}&type=A" 2>/dev/null \
        | grep -oE '"data"[ ]*:[ ]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | head -n1 \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    printf '%s' "$r"
}

# 域名 → IPv6 解析回退链(AAAA;结构与 v4 版一致)
resolve_host_ip6() { # <host>
    local h=$1 ip r
    if command -v dig >/dev/null 2>&1; then
        for ns in 223.5.5.5 119.29.29.29 240c::6666; do
            ip=$(dig +short +time=2 +tries=1 AAAA "$h" @"$ns" 2>/dev/null \
                | grep -E '^[0-9a-fA-F:]+$' | head -n1)
            [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
        done
    fi
    ip=$(getent ahosts "$h" 2>/dev/null | awk '$1 ~ /:/ {print $1}' | head -n1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    r=$(curl -s --noproxy '*' --connect-timeout 3 --max-time 5 \
        "https://223.5.5.5/resolve?name=${h}&type=AAAA" 2>/dev/null \
        | grep -oE '"data"[ ]*:[ ]*"[0-9a-fA-F:]+"' | head -n1 \
        | grep -oE '"[0-9a-fA-F:]+"' | tr -d '"')
    printf '%s' "$r"
}

prov_ping_one() { # <省码> <ct|cu|cm> <输出文件> -> "avg|loss"
    local p=$1 isp=$2 out=$3
    (
        _ip=$(resolve_host_ip "${p}-${isp}-v4.ip.zstaticcdn.com")
        [ -n "$_ip" ] || { printf '|'; exit 0; }
        _o=$(ping -c 4 -i 0.2 $PING_WOPT "$_ip" 2>/dev/null)
        _loss=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
        # 100% 丢包复核一次(避开瞬时 ICMP 限速/抖动误判)
        if [ -z "${_loss:-}" ] || [ "${_loss:-100}" -ge 100 ] 2>/dev/null; then
            _o=$(ping -c 2 -i 0.5 $PING_WOPT "$_ip" 2>/dev/null)
            _loss=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
        fi
        _avg=$(printf '%s' "$_o" | grep -oE '(min/avg/max(/mdev)? = )[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+$' | head -n1)
        printf '%s|%s' "${_avg:-}" "${_loss:-100}"
    ) >"$out" 2>/dev/null
}

mod_provinces() {
    [ "$HQ_MODE" = tiny ] && return 0
    sec "$(L provm '省份延迟矩阵') 31 Provinces"
    note "$(L provm_note '31 省 × 电信/联通/移动网内目标,每格发 4 个 ICMP 包') (zstaticcdn)"
    local p isp
    local -a batch=()
    for p in "${HQ_PROVINCES[@]}"; do
        for isp in ct cu cm; do
            prov_ping_one "$p" "$isp" "$HQ_TMP/prov.$p.$isp" &
            batch+=($!)
            if [ ${#batch[@]} -ge "$HQ_NET" ]; then
                wait "${batch[@]}" 2>/dev/null
                batch=()
            fi
        done
    done
    [ ${#batch[@]} -gt 0 ] && wait "${batch[@]}" 2>/dev/null

    local ct_v cu_v cm_v f cell_avg cell_loss
    local sum=0 n=0
    for p in "${HQ_PROVINCES[@]}"; do
        ct_v=""; cu_v=""; cm_v=""
        for isp in ct cu cm; do
            f="$HQ_TMP/prov.$p.$isp"
            [ -s "$f" ] || { rm -f "$f"; continue; }
            IFS='|' read -r cell_avg cell_loss <"$f"
            rm -f "$f"
            local v="-"
            if is_num "$cell_avg"; then
                v="$cell_avg"
                is_num "$cell_loss" && [ "$cell_loss" -gt 0 ] 2>/dev/null && v="${cell_avg}*${cell_loss}%"
                sum=$(awk -v a=$sum -v b=$cell_avg 'BEGIN{print a+b}'); n=$((n+1))
            elif is_num "$cell_loss" && [ "$cell_loss" -ge 100 ] 2>/dev/null; then
                v="×"
            fi
            case "$isp" in ct) ct_v=$v ;; cu) cu_v=$v ;; cm) cm_v=$v ;; esac
        done
        PROV_ROWS+=("${PROV_NAME[$p]}|$ct_v|$cu_v|$cm_v")
    done
    # 按电信列延迟排序(数值行优先,异常行殿后)
    # 注意:组内第二条 grep 不能再读 stdin(已被第一条耗尽),须重读 PROV_ROWS
    local sorted
    sorted=$({
        printf '%s\n' ${PROV_ROWS[@]+"${PROV_ROWS[@]}"} | grep -E '^[^|]+\|[0-9.]+' | sort -t'|' -k2 -n
        printf '%s\n' ${PROV_ROWS[@]+"${PROV_ROWS[@]}"} | grep -vE '^[^|]+\|[0-9.]+' || true
    })
    PROV_ROWS=()
    while IFS= read -r r; do
        [ -n "$r" ] && PROV_ROWS+=("$r")
    done <<< "$sorted"
    [ "$n" -gt 0 ] && G[prov_avg]=$(awk -v s=$sum -v n=$n 'BEGIN{printf "%.1f", s/n}')

    # 环形图统计(原型 IPv4/IPv6 回程质量卡):93 测点零丢包计数
    local pr ci cell p4ok=0 p4tot=0
    for pr in ${PROV_ROWS[@]+"${PROV_ROWS[@]}"}; do
        for ci in 2 3 4; do
            cell=$(printf '%s' "$pr" | cut -d'|' -f$ci)
            p4tot=$((p4tot+1))
            case "$cell" in
                [0-9.]*) [[ "$cell" != *\** ]] && p4ok=$((p4ok+1)) ;;
            esac
        done
    done
    G[prov4_ok]=$p4ok
    G[prov4_total]=$p4tot

    # IPv6 族:无 v6 地址 → 未检测(不写入伪 0/N);有则真测 v6 省份矩阵
    if [ -z "${G[ip6]:-}" ]; then
        :
    else
        local v6c="" p6ok=0 p6tot=0
        v6c=$(ping_cmd_for 2606:4700:4700::1111)
        if [ -n "$v6c" ]; then
            local -a vb=()
            for p in "${HQ_PROVINCES[@]}"; do
                for isp in ct cu cm; do
                    (
                        _ip=$(resolve_host_ip6 "${p}-${isp}-v6.ip.zstaticcdn.com")
                        [ -n "$_ip" ] || exit 0
                        _o=$($v6c -c 2 -i 0.3 -W 2 "$_ip" 2>/dev/null)
                        _loss=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '^[0-9]+')
                        [ "${_loss:-100}" = 0 ] && printf 'ok'
                    ) >"$HQ_TMP/prov6.$p.$isp" &
                    vb+=($!)
                    if [ ${#vb[@]} -ge "$HQ_NET" ]; then wait "${vb[@]}" 2>/dev/null; vb=(); fi
                done
            done
            [ ${#vb[@]} -gt 0 ] && wait "${vb[@]}" 2>/dev/null
            local vf
            for p in "${HQ_PROVINCES[@]}"; do
                for isp in ct cu cm; do
                    vf="$HQ_TMP/prov6.$p.$isp"
                    p6tot=$((p6tot+1))
                    [ -s "$vf" ] && grep -q '^ok$' "$vf" && p6ok=$((p6ok+1))
                    rm -f "$vf"
                done
            done
        fi
        G[prov6_ok]=$p6ok
        G[prov6_total]=$p6tot
    fi
    if [ "${G[prov6_total]:-0}" -gt 0 ]; then
        kv "$(L prov6 'IPv6 测点零丢包')" "${G[prov6_ok]:-0}/${G[prov6_total]}$( [ -z "${G[ip6]:-}" ] && printf ' %s' "$(L prov6_no '(无 IPv6,全部异常)')" )"
    fi
    if [ $n -gt 0 ]; then
        kv "$(L provm_avg '全网省份均值')" "$(fmt_ms "${G[prov_avg]}") (${n} $(L cells '个可用网格'))"
        note "$(L provm_hint '明细见报告完整模式/JSON;丢包格标注 |丢包%')"
    fi
}

# NAT / UDP 出站检测:轻量 STUN Binding(RFC5389,纯 bash /dev/udp,零依赖)
# 与公网 IP 比对:公网直连 / NAT 或共享出口(NAT 小鸡识别) / UDP 受限
STUN_SERVERS=(
    "stun.cloudflare.com|3478"
    "global.stun.twilio.com|3478"
    "stun.l.google.com|19302"
)

# 解析 STUN 域名为 IPv4(优先公共 DNS 直查,绕开可能被污染的系统解析)
stun_resolve() { # <host> -> IPv4
    local h=$1 ip r
    if command -v dig >/dev/null 2>&1; then
        for r in 1.1.1.1 8.8.8.8; do
            ip=$(dig +short +time=2 +tries=1 "$h" @"$r" 2>/dev/null \
                | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
            [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
        done
    fi
    getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}'
}

stun_probe() { # <server> <port> -> "mapped_ip|mapped_port" 或空
    local server=$1 port=$2 hex bin resp i m off
    server=$(stun_resolve "$server")
    [ -n "$server" ] || return 1
    hex=$(head -c 12 /dev/urandom | od -An -v -tx1 | tr -d ' \n')
    bin=""
    for ((i = 0; i < 24; i += 2)); do bin+="\\x${hex:i:2}"; done
    (
        exec 98<>/dev/udp/"$server"/"$port" 2>/dev/null || exit 1
        printf '\x00\x01\x00\x00\x21\x12\xa4\x42'"$bin" >&98
        # cat 流式转发:超时被杀前数据已进管道,不像 dd 会丢缓冲
        resp=$(timeout 3 cat <&98 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
        exec 98<&- 2>/dev/null
        # XOR-MAPPED-ADDRESS:布局 type|len|00(rsvd)|01(fam)|xport|xaddr;兼容无保留字节变体
        m=$(printf '%s' "$resp" | grep -oE '00200008(00)?01[0-9a-f]{12}' | head -n1)
        if [ -n "$m" ]; then
            off=$(( ${#m} - 12 ))
            local p1 p2 a1 a2 a3 a4
            p1=$(( 0x${m:off:2} )); p2=$(( 0x${m:off+2:2} ))
            a1=$(( 0x${m:off+4:2} ^ 0x21 )); a2=$(( 0x${m:off+6:2} ^ 0x12 ))
            a3=$(( 0x${m:off+8:2} ^ 0xa4 )); a4=$(( 0x${m:off+10:2} ^ 0x42 ))
            printf '%d.%d.%d.%d|%d' "$a1" "$a2" "$a3" "$a4" "$(( ((p1 << 8) | p2) ^ 0x2112 ))"
        else
            # MAPPED-ADDRESS(未异或,部分服务器返回)
            m=$(printf '%s' "$resp" | grep -oE '00010008(00)?01[0-9a-f]{12}' | head -n1)
            [ -n "$m" ] || exit 0
            off=$(( ${#m} - 12 ))
            printf '%d.%d.%d.%d|%d' \
                "0x${m:off+4:2}" "0x${m:off+6:2}" "0x${m:off+8:2}" "0x${m:off+10:2}" \
                "$(( 0x${m:off:2} * 256 + 0x${m:off+2:2} ))"
        fi
    ) 2>/dev/null
}

nat_detect() {
    G[nat_type]=""; G[nat_mapped]=""
    [ -n "${G[ip4]:-}" ] || return 1
    local s server port mapped=""
    for s in "${STUN_SERVERS[@]}"; do
        IFS='|' read -r server port <<< "$s"
        mapped=$(stun_probe "$server" "$port")
        [ -n "$mapped" ] && break
    done
    if [ -z "$mapped" ]; then
        G[nat_type]="UDP 受限"
        kv "$(L natk 'NAT/UDP')" "$C_YELLOW$(L nat_block 'UDP 出站受限或阻断')${C_OFF}"
        return 0
    fi
    G[nat_mapped]=$mapped
    local mip=${mapped%%|*}
    if [ "$mip" = "${G[ip4]}" ]; then
        G[nat_type]="公网直连"
        kv "$(L natk 'NAT/UDP')" "$C_GREEN$(L nat_direct '公网直连(UDP 正常)')${C_OFF} ${C_DIM}stun:${mip}${C_OFF}"
    else
        G[nat_type]="NAT/共享出口"
        kv "$(L natk 'NAT/UDP')" "$C_YELLOW$(L nat_shared 'NAT/共享出口(非独立公网 IP)')${C_OFF} ${C_DIM}stun:${mip}$( [ -n "${G[ip4]}" ] && printf ' / %s' "${G[ip4]}")${C_OFF}"
    fi
}


# ============================================================
# 大小包检测(ICMP DF 探测,零依赖;nexttrace 就绪后追加大包 TCP 检测)
# ============================================================
# 每运营商多个候选(实测部分节点屏蔽 ICMP DF);探测时选第一个应答者
MTU_TARGETS=(
    "电信|202.96.209.133|61.139.2.69"
    "联通|61.135.169.121|210.21.4.130|202.102.152.3"
    "移动|120.196.165.24|211.136.112.50|211.138.180.2"
    "教育网|202.112.0.35"
)
MTU_SIZES=(1372 1172 484 36)          # ICMP payload;线径 1400/1200/512/64B
MTU_SIZE_LABELS=(1400 1200 512 64)   # 对外展示的线径标签(B),与 TCP 档位一致(1500B 超 TCP MSS 且贴近链路 MTU,无区分度,已移除)
MTU_V6_SIZES=(1352 1152 464 16)    # v6 ICMP 载荷 = 线径-48B(40B IPv6 头 + 8B ICMPv6 头)
MTU_V6_TARGETS=(
    "2606:4700:4700::1111"
    "2400:3200::1"
)
MTU_TCP_LABELS=(1400 1200 512 64)  # TCP 模式档位:HTTP 请求总字节数(含首部,≤MSS 单段)

# 省网载荷探测节点网格(getNodes 接口):31省×三网×双栈,80 端口应答
# 输出每行 "fam|运营商|ip1,ip2,..."(12h 磁盘缓存)
npnodes_load() {
    local cf="$HQ_HOME/nping_nodes.tsv" fam isp ips got=0
    mkdir -p "$HQ_HOME" 2>/dev/null
    if [ ! -s "$cf" ] || [ -n "$(find "$cf" -mmin +720 2>/dev/null)" ]; then
        curl -fsSL --connect-timeout 5 --max-time 15 \
            "https://tcpquality.ibsgss.uk/getNodes?format=tsv&scope=nping" >"$cf" 2>/dev/null || true
    fi
    [ -s "$cf" ] || return 1
    for fam in 4 6; do
        for isp in 电信 联通 移动; do
            ips=$(awk -F'\t' -v f="$fam" -v isp="$isp" \
                '$1=="cdn" && $2==f && $4==isp && !seen[$6]++ {print $6}' "$cf" 2>/dev/null | head -4 | paste -sd, -)
            [ -n "$ips" ] && { printf '%s|%s|%s\n' "$fam" "$isp" "$ips"; got=1; }
        done
    done
    [ "$got" = 1 ]
}

# TCP 载荷大小包(以真实 TCP 数据包实现):
# 对省网节点 80 端口发送指定档位字节数的 HTTP 请求(填充 URL 到 64/512/1200/1400B),
# 每档 3 探测:丢包=失败率(超时/连接失败),延迟=请求发出→首字节(含载荷重传影响)。
# 成功产出 MTU_ROWS 行(名字与 ICMP 模式一致)并置 G[mtu_proto]=tcp;失败返回 1 走 ICMP 回退
mtu_tcp_run() {
    local nf="$HQ_TMP/npnodes.$$" fam isp ips idx=0 fo tcand
    npnodes_load >"$nf" 2>/dev/null || { rm -f "$nf" 2>/dev/null; return 1; }
    [ -s "$nf" ] || { rm -f "$nf" 2>/dev/null; return 1; }
    local PADMAX
    PADMAX=$(printf 'a%.0s' $(seq 1 1500) 2>/dev/null)
    local -a jobs=()
    while IFS='|' read -r fam isp ips; do
        [ -n "$ips" ] || continue
        [ "$fam" = 6 ] && [ -z "${G[ip6]:-}" ] && continue
        [ "$fam" = 4 ] && [ -z "${G[ip4]:-}" ] && [ -n "${G[ip6]:-}" ] && continue
        fo="$HQ_TMP/mtutcp.$idx.rows"; idx=$((idx+1))
        (
            local fopt="" pfx=""
            [ "$fam" = 6 ] && { fopt="-6"; pfx="v6"; }
            # 候选择优:首个 2s 内完成 TCP 握手的省网节点
            # (v6 字面量进 URL 必须加方括号,否则 curl 按 malformed URL 拒绝,v6 方向将整体无数据)
            local tip="" t _c _cu
            for _c in ${ips//,/ }; do
                _cu=$_c; case "$_c" in *:*) _cu="[$_c]" ;; esac
                t=$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 1.5 --max-time 2 $fopt \
                    "telnet://${_cu}:80/" </dev/null 2>/dev/null)
                if is_num "$t" && awk -v t="$t" 'BEGIN{exit !(t>0.001)}'; then tip=$_c; break; fi
            done
            [ -n "$tip" ] || exit 0
            local lbl ov pad url i tc tt ok nfail loss avg _tu
            _tu=$tip; case "$tip" in *:*) _tu="[$tip]" ;; esac
            for lbl in "${MTU_TCP_LABELS[@]}"; do
                ov=$(printf 'GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: hq\r\nAccept: */*\r\n\r\n' "$tip" | wc -c)
                pad=$((lbl - ov)); [ "$pad" -lt 0 ] && pad=0
                url="http://${_tu}:80/${PADMAX:0:$pad}"
                ok=""; nfail=0
                for i in 1 2 3; do
                    read -r tc tt <<< "$(curl -s -o /dev/null -w '%{time_connect} %{time_starttransfer}' \
                        --connect-timeout 3 --max-time 6 $fopt "$url" 2>/dev/null)"
                    if is_num "$tc" && is_num "$tt" && awk -v a="$tc" -v b="$tt" 'BEGIN{exit !(b>a && b>0)}'; then
                        ok="$ok $(awk -v a="$tc" -v b="$tt" 'BEGIN{printf "%.1f", (b-a)*1000}')"
                    else
                        nfail=$((nfail+1))
                    fi
                done
                loss=$(( nfail * 100 / 3 ))
                avg=$(printf '%s' "$ok" | awk '{if(NF>0){t=0;for(i=1;i<=NF;i++)t+=$i;printf "%.1f",t/NF}}')
                printf '%s|%sB|%s|%s\n' "${pfx}${isp}" "$lbl" "$loss" "${avg:-}" >>"$fo"
            done
        ) &
        jobs+=($!)
        hq_throttle
    done <"$nf"
    rm -f "$nf" 2>/dev/null
    wait "${jobs[@]}" 2>/dev/null
    local f _n _s _l _r n=0
    for f in "$HQ_TMP"/mtutcp.*.rows; do
        [ -s "$f" ] || continue
        while IFS='|' read -r _n _s _l _r; do
            [ -n "$_n" ] || continue
            MTU_ROWS+=("$_n|$_s|$_l|$_r")
            n=$((n+1))
        done <"$f"
        rm -f "$f"
    done
    [ "$n" -gt 0 ] || return 1
    G[mtu_proto]=tcp
    return 0
}

# 大小包汇总(ICMP/TCP 两模式共用,档位一致):最大可通过档 + 按档位聚合 PKT_ROWS + 终端输出
mtu_finalize() {
    local -a SZL=("${MTU_SIZE_LABELS[@]}")
    local summary="" row _n _s _l _r _ov si li fam agg t name ip
    local -A best=()
    for row in ${MTU_ROWS[@]+"${MTU_ROWS[@]}"}; do
        IFS='|' read -r _n _s _l _r _ov <<< "$row"
        case "$_n" in 电信|联通|移动|教育网|v6电信|v6联通|v6移动) ;; *) continue ;; esac
        if [ "${_l:-100}" -lt 50 ] 2>/dev/null; then
            local _msnum=${_s%B} _bsnum=${best[$_n]:-0}
            _bsnum=${_bsnum%B}   # best 存的是带B标签,比较前同样去B,避免 is_num 恒假
            is_num "$_msnum" && is_num "$_bsnum" && [ "$_msnum" -gt "$_bsnum" ] 2>/dev/null && best[$_n]=$_s
        fi
    done
    for t in "${MTU_TARGETS[@]}"; do
        IFS='|' read -r name ip <<< "$t"
        summary="${summary}${name}:${best[$name]:-<64B} "
    done
    G[mtu_summary]=$(printf '%s' "$summary" | xargs | tr ' ' '/')

    local _alat _aver _full _nn _vd
    for fam in v4 v6; do
        for si in "${!SZL[@]}"; do
            li="${SZL[$si]}B"
            agg=$( {
                if [ "$fam" = v4 ]; then
                    printf '%s\n' ${MTU_ROWS[@]+"${MTU_ROWS[@]}"} | grep -v '^v6'
                else
                    printf '%s\n' ${MTU_ROWS[@]+"${MTU_ROWS[@]}"} | grep '^v6'
                fi
            } | awk -F'|' -v want="$li" '$2==want && ($3!="" || $4!="") {
                    if ($3 != "") { ls+=$3; ln++ }
                    if ($4 != "") { rs+=$4; rn++ }
                    if ($3+0 >= 100) full++
                    n++
                } END {
                    if (n == 0) exit
                    printf "%.1f %.1f %d %d", (rn?rs/rn:0), (ln?ls/ln:0), full, n
                }' )
            if [ -n "$agg" ]; then
                read -r _alat _aver _full _nn <<< "$agg"
                _vd=$(awk -v l="$_aver" 'BEGIN{
                    if (l+0 >= 99.5) print "异常"
                    else if (l+0 >= 30) print "受限"
                    else if (l+0 >= 5) print "轻微丢包"
                    else print "正常"
                }')
                [ "$_nn" -gt 0 ] || _vd="待检测"
                [ "$_nn" -gt 0 ] && [ "$_full" = "$_nn" ] && _alat=""
                PKT_ROWS+=("$fam|$li|${_alat:-}|${_aver}|$_vd")
            else
                PKT_ROWS+=("$fam|$li|||待检测")
            fi
        done
    done

    for t in "${MTU_TARGETS[@]}"; do
        IFS='|' read -r name ip <<< "$t"
        local line="" cell
        for si in "${!SZL[@]}"; do
            for row in ${MTU_ROWS[@]+"${MTU_ROWS[@]}"}; do
                [ "${row%%|*}" = "$name" ] || continue
                IFS='|' read -r _n _s _l _r _ov <<< "$row"
                [ "$_s" = "${SZL[$si]}B" ] || continue
                if [ "${_ov:-}" = "1" ] || [ "${_ov:-}" = "over" ]; then cell="${C_DIM}${_s}⊘${C_OFF}"
                elif [ "$_l" -lt 50 ] 2>/dev/null; then cell="${C_GREEN}${_s}✓${C_OFF}"
                else cell="${C_RED}${_s}✗${C_OFF}"; fi
                line="${line} ${cell}"
            done
        done
        printf '  %-6s %s:%s\n' "$name" "$([ "${G[mtu_proto]}" = tcp ] && printf 'TCP' || printf 'DF')" "$line"
    done
    [ -n "${G[mtu_summary]}" ] && kv "最大可通过" "${G[mtu_summary]}"
    if [ "${G[mtu_proto]}" = tcp ]; then
        note "TCP 载荷探测:对三网省网节点 80 端口发 64/512/1200/1400B HTTP 请求,每档 3 次;丢包=失败率,延迟=请求→首字节(含节点响应,略高于纯 ping 属正常)"
    else
        note "ICMP 包径探测:64/512/1200/1400B(v4 载荷=线径-28B 且置 DF;v6 载荷=线径-48B,超链路 MTU 标超MTU)"
    fi
}


mod_tcpmtu() {
    sec "$(L tcpmtu '大小包检测') Packet Size"
    # 首选 TCP 载荷探测(真实 TCP 数据包);节点网格不可达时回退 ICMP DF
    G[mtu_proto]=""
    if mtu_tcp_run; then
        mtu_finalize
        return 0
    fi
    G[mtu_proto]=icmp
    note "TCP 探测网格不可达,回退 ICMP DF 大小包"
    local cmd
    cmd=$(ping_cmd_for 1.1.1.1)
    # 能力检测:iputils 支持 -M do,BusyBox 不支持则诚实降级
    if ! $cmd -M 'do' -c 1 -W 1 -s 16 127.0.0.1 >/dev/null 2>&1; then
        warn "当前 ping 不支持 DF 探测(-M do),跳过 ICMP 大小包检测"
        local _si
        for _si in 64 512 1200 1400; do
            PKT_ROWS+=("v4|${_si}B|||待检测")
            [ -n "${G[ip6]:-}" ] && PKT_ROWS+=("v6|${_si}B|||待检测")
        done
        return 1
    fi
    # 逐运营商 × 逐档(64/512/1200/1400B 线径,DF),3 探测/档;有 IPv6 时追加 v6 目标
    local -a jobs=()
    local t name ip ipcand i=0 j si li
    for t in "${MTU_TARGETS[@]}"; do
        IFS='|' read -r name ip <<< "$t"
        # 候选择优:首个 64B DF 应答的 IP(部分节点屏蔽 ICMP,逐个回退)
        ipcand=$(printf '%s' "$t" | cut -d'|' -f2- | tr '|' ' ')
        ip=""
        for _c in $ipcand; do
            ep_bad "mtu_${name}_${_c}" && continue
            if $cmd -M 'do' -c 1 -W 2 -s 36 "$_c" >/dev/null 2>&1; then ip=$_c; ep_ok "mtu_${name}_${_c}"; break; fi
            ep_fail "mtu_${name}_${_c}"
        done
        [ -n "$ip" ] || { warn "$name 候选目标均不应答 ICMP DF,该方向大小包标待检测"; continue; }
        for j in "${!MTU_SIZES[@]}"; do
            si=${MTU_SIZES[$j]}
            (
                _o=$($cmd -M 'do' -c 3 -W 2 -s "$si" "$ip" 2>/dev/null)
                _loss=$(printf '%s' "$_o" | awk '/packets? transmitted/{
                    tx=0+$1; if (match($0,/[0-9]+ received/)) rx=0+substr($0,RSTART,RLENGTH-9);
                    if (tx>0) printf "%d", (tx-rx>0)?(int((tx-rx)*100/tx+0.5)>100?100:int((tx-rx)*100/tx+0.5)):0 }' | head -n1)
                [ -n "$_loss" ] || _loss=$(printf '%s' "$_o" | grep -oE '[0-9]+% packet loss' | head -n1 | grep -oE '[0-9]+' | head -n1)
                [ -n "$_loss" ] || _loss=100
                is_num "$_loss" && { [ "$(awk -v v="$_loss" 'BEGIN{print (v>100)?1:0}')" = 1 ] && _loss=100; }
                _rtt=$(printf '%s' "$_o" | grep -oE '(min/avg/max(/mdev)? = )[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+$' | head -n1)
                printf '%s|%s|%s|%s' "$name" "${MTU_SIZE_LABELS[$j]}B" "$_loss" "${_rtt:-}"
            ) >"$HQ_TMP/mtu.$i.$j" &
            jobs+=($!)
            hq_throttle
        done
        i=$((i+1))
    done
    local v6cmd="" v6n=0
    local -a V6C_NAMES=(电信 联通 移动)
    local -a V6C_CODES=(ct cu cm)
    if [ -n "${G[ip6]:-}" ]; then
        v6cmd=$(ping_cmd_for 2606:4700:4700::1111)
        # -M do 仅 iputils 支持;IPv6 路由器本就不分片(DF 隐含),BusyBox 降级为普通 v6 ping 仍可测
        if $v6cmd -M 'do' -c 1 -W 1 -s 16 ::1 >/dev/null 2>&1; then
            v6cmd="$v6cmd -M do"
        else
            $v6cmd -c 1 -W 1 -s 16 ::1 >/dev/null 2>&1 || v6cmd=""
        fi
        if [ -n "$v6cmd" ]; then
            # 每运营商五省候选预选 v6 目标;载荷=线径-48B;IPv6 无 DF 位,超链路 MTU 记"超MTU"
            local ci ccode
            for ci in 0 1 2; do
                ccode=${V6C_CODES[$ci]}
                (
                    local _v6ip="" _pv6 _ip6 j si _o _loss _rtt _over
                    for _pv6 in bj sh gd sn zj; do
                        _ip6=$(dig6 "${_pv6}-${ccode}-v6.ip.zstaticcdn.com")
                        [ -n "$_ip6" ] || continue
                        $v6cmd -c 1 -W 1 -s 16 "$_ip6" >/dev/null 2>&1 && { _v6ip=$_ip6; break; }
                    done
                    [ -n "$_v6ip" ] || exit 0
                    for j in "${!MTU_V6_SIZES[@]}"; do
                        si=${MTU_V6_SIZES[$j]}
                        _over=""
                        _o=$($v6cmd -c 3 -W 2 -s "$si" "$_v6ip" 2>&1)
                        printf '%s' "$_o" | grep -qi 'too long' && _over=1
                        _loss=$(printf '%s' "$_o" | awk '/packets? transmitted/{
                            tx=0+$1; if (match($0,/[0-9]+ received/)) rx=0+substr($0,RSTART,RLENGTH-9);
                            if (tx>0) printf "%d", (tx-rx>0)?(int((tx-rx)*100/tx+0.5)>100?100:int((tx-rx)*100/tx+0.5)):0 }' | head -n1)
                        [ -n "$_over" ] && _loss=""
                        is_num "$_loss" && { [ "$(awk -v v="$_loss" 'BEGIN{print (v>100)?1:0}')" = 1 ] && _loss=100; }
                        _rtt=$(printf '%s' "$_o" | grep -oE '(min/avg/max(/mdev)? = )[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+$' | head -n1)
                        printf '%s|%s|%s|%s|%s\n' "v6${V6C_NAMES[$ci]}" "${MTU_SIZE_LABELS[$j]}B" "$_loss" "${_rtt:-}" "${_over}"
                    done >"$HQ_TMP/mtuv6.$ci.rows"
                ) &
                jobs+=($!)
                hq_throttle
            done
            v6n=3
        fi
    fi
    wait "${jobs[@]}" 2>/dev/null

    # 汇总:ICMP 明细文件 → MTU_ROWS(best/聚合在 mtu_finalize 统一处理)
    local mname msize mloss mrtt
    for ((j=0; j<i; j++)); do
        for si in "${!MTU_SIZES[@]}"; do
            [ -s "$HQ_TMP/mtu.$j.$si" ] || continue
            IFS='|' read -r mname msize mloss mrtt <"$HQ_TMP/mtu.$j.$si"
            MTU_ROWS+=("$mname|$msize|$mloss|$mrtt")
            rm -f "$HQ_TMP/mtu.$j.$si"
        done
    done

    # v6 明细行并入 MTU_ROWS(名字带 v6 前缀,供逐运营商 IPv6 包表)
    local idx _r6 _n6 _s6 _l6 _t6 _o6
    for ((idx=0; idx<v6n; idx++)); do
        [ -s "$HQ_TMP/mtuv6.$idx.rows" ] || continue
        while IFS='|' read -r _n6 _s6 _l6 _t6 _o6; do
            [ -n "$_n6" ] || continue
            MTU_ROWS+=("$_n6|$_s6|$_l6|$_t6|${_o6:-}")
        done <"$HQ_TMP/mtuv6.$idx.rows"
    done

    for ((idx=0; idx<v6n; idx++)); do rm -f "$HQ_TMP"/mtuv6.$idx.* 2>/dev/null; done
    mtu_finalize
    return 0
}

# ============================================================
# 国际互联检测(纯 curl 并行:10 站可达性 + TCP 握手延迟 + CDN 下行参考)
# ============================================================
INTL_TARGETS=(
    "Google|gstatic.com"
    "YouTube|www.youtube.com"
    "GitHub|github.com"
    "Cloudflare|www.cloudflare.com"
    "X|x.com"
    "Telegram|telegram.org"
    "Wikipedia|www.wikipedia.org"
    "Netflix|www.netflix.com"
    "Discord|discord.com"
    "ChatGPT|chatgpt.com"
)

# CDN 可达性组(拉真实静态资源,比裸 HTTP 码更贴近业务)
CDN_ASSETS=(
    "CDNjs|https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"
    "GoogleLib|https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js"
    "jsDelivr|https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"
    "UNPKG|https://unpkg.com/jquery@3.7.1/dist/jquery.min.js"
)

# DNS 出口检测:系统解析 vs DoH 双源参照(Cloudflare → AliDNS),识别劫持/污染
dns_hijack_check() {
    G[dns_hijack]=""; G[dns_note]=""
    local dom="www.google.com" doh="" sys=""
    doh=$(hq_curl -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${dom}&type=A" 6 \
        | grep -oE '"data":"[0-9.]+"' | grep -oE '[0-9.]+' | sort -u)
    [ -z "$doh" ] && doh=$(hq_curl "https://dns.alidns.com/resolve?name=${dom}&type=1" 6 \
        | grep -oE '"data":"[0-9.]+"' | grep -oE '[0-9.]+' | sort -u)
    if command -v getent >/dev/null 2>&1; then
        sys=$(with_timeout 8 getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    [ -z "$sys" ] && sys=$(with_timeout 8 nslookup "$dom" 2>/dev/null | awk '/^Address/ && !/#/ {print $NF}' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
    if [ -z "$sys" ]; then
        G[dns_hijack]=2; G[dns_note]=$(L dns_fail2 '系统解析失败(疑似阻断)')
        kv "$(L dnsc 'DNS 解析')" "$C_RED${G[dns_note]}${C_OFF}"
        return
    fi
    if [ -z "$doh" ]; then
        G[dns_hijack]=3; G[dns_note]=$(L dns_unk 'DoH 不可达,无法比对')
        kv "$(L dnsc 'DNS 解析')" "$(L dns_unk 'DoH 不可达,无法比对') ${C_DIM}$(printf '%s' "$sys" | paste -sd' ' -)${C_OFF}"
        return
    fi
    local bogon common
    bogon=$(printf '%s\n' "$sys" | grep -E '^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -n1)
    common=$(comm -12 <(printf '%s\n' "$sys") <(printf '%s\n' "$doh") | head -n1)
    if [ -n "$bogon" ]; then
        G[dns_hijack]=1; G[dns_note]="$(L dns_bad '疑似劫持') ${bogon}"
        kv "$(L dnsc 'DNS 解析')" "$C_RED$(L dns_bad '疑似劫持')${C_OFF} ${C_DIM}(返回保留地址 ${bogon})${C_OFF}"
    elif [ -n "$common" ]; then
        G[dns_hijack]=0; G[dns_note]=$(L dns_ok '正常(与 DoH 一致)')
        kv "$(L dnsc 'DNS 解析')" "$C_GREEN$(L dns_ok '正常(与 DoH 一致)')${C_OFF}"
    else
        G[dns_hijack]=1; G[dns_note]=$(L dns_bad2 '疑似污染(与 DoH 不一致)')
        kv "$(L dnsc 'DNS 解析')" "$C_RED$(L dns_bad2 '疑似污染')${C_OFF} ${C_DIM}sys=$(printf '%s' "$sys" | paste -sd' ' - | cut -c1-40) doh=$(printf '%s' "$doh" | paste -sd' ' - | cut -c1-40)${C_OFF}"
    fi
}

mod_intl() {
    sec "$(L intl '国际互联') International"
    note "$(L intl_tcp_note '延迟为纯 TCP 握手耗时(已剔除 DNS 解析),两次探测取最小,可与 ping 对照')"
    local i=0 t name host
    local -a jobs=()
    for t in "${INTL_TARGETS[@]}"; do
        IFS='|' read -r name host <<< "$t"
        (
            # 直连探测(绕过代理,反映主机真实国际连通性)
            # v2.6:time_connect 含 DNS 解析,慢速/被污染 DNS 会虚增数十~数百 ms;
            #      改为 (time_connect - time_namelookup) 取纯 TCP 握手,两次探测取最小
            _ms="" _code=000
            for _try in 1 2; do
                _o=$(curl -s -o /dev/null -w '%{http_code}|%{time_namelookup}|%{time_connect}' --noproxy '*' \
                    --connect-timeout 4 --max-time 6 -A "$HQ_UA" "https://${host}/" 2>/dev/null)
                _code=${_o%%|*}; _rest=${_o#*|}
                _nl=${_rest%%|*}; _ct=${_rest#*|}
                if [ "${_code:-000}" != 000 ] && [ -n "${_code:-}" ] && is_num "${_ct:-}" && is_num "${_nl:-}"; then
                    _td=$(awk -v c="$_ct" -v n="$_nl" 'BEGIN{d=c-n; if(d<0)d=0; printf "%.3f", d}')
                    if [ "$(awk -v x="$_td" 'BEGIN{print (x>0)?1:0}')" = 1 ]; then
                        if [ -z "$_ms" ]; then _ms=$_td; else
                            _ms=$(awk -v a="$_ms" -v b="$_td" 'BEGIN{print (a<b)?a:b}')
                        fi
                    fi
                fi
            done
            printf '%s|%s|%s' "$name" "$_code" "${_ms:-}"
        ) >"$HQ_TMP/intl.$i" &
        jobs+=($!)
        hq_throttle
        i=$((i+1))
    done
    # CDN 静态资源可达性组(与站点探测并行)
    local ci=0 cn url
    for cn in "${CDN_ASSETS[@]}"; do
        IFS='|' read -r name url <<< "$cn"
        (
            _o=$(curl -s -o /dev/null -w '%{http_code}|%{time_total}|%{speed_download}' --noproxy '*' \
                --connect-timeout 4 --max-time 8 -A "$HQ_UA" "$url" 2>/dev/null)
            printf '%s|%s' "$name" "$_o"
        ) >"$HQ_TMP/cdnasset.$ci" &
        jobs+=($!)
        hq_throttle
        ci=$((ci+1))
    done
    # 国际 CDN 下行参考(Cloudflare)
    local cdn_secs=5 cdn_bytes=50000000
    [ "$HQ_MODE" = tiny ] && { cdn_secs=3; cdn_bytes=20000000; }
    (
        _spd=$(curl -s -o /dev/null -w '%{speed_download}' --noproxy '*' \
            --connect-timeout 4 --max-time "$cdn_secs" \
            "https://speed.cloudflare.com/__down?bytes=${cdn_bytes}" 2>/dev/null)
        printf '%s' "$_spd"
    ) >"$HQ_TMP/intl.cdn" &
    jobs+=($!)
    hq_throttle
    wait "${jobs[@]}" 2>/dev/null

    local row iname icode ims ok_n=0
    for ((i=0; i<${#INTL_TARGETS[@]}; i++)); do
        [ -s "$HQ_TMP/intl.$i" ] || continue
        IFS='|' read -r iname icode ims <"$HQ_TMP/intl.$i"
        local lvl=bad disp="❌" imsms=""
        if [ "${icode:-000}" != 000 ] && [ -n "${icode:-}" ] && is_num "${ims:-}"; then
            ok_n=$((ok_n+1))
            lvl=good
            imsms=$(awk -v t="$ims" 'BEGIN{printf "%.1f", t*1000}')
            disp="${imsms}ms"
            awk -v t="$ims" 'BEGIN{exit !(t*1000>150)}' && lvl=warn
            awk -v t="$ims" 'BEGIN{exit !(t*1000>400)}' && lvl=bad
        fi
        INTL_ROWS+=("$iname|$disp|$imsms|$lvl")
        printf '  %-14s %s%s%s\n' "$iname" "$([ "$lvl" = good ] && printf '%s' "$C_GREEN" || { [ "$lvl" = warn ] && printf '%s' "$C_YELLOW" || printf '%s' "$C_RED"; })" "$disp" "$C_OFF"
        rm -f "$HQ_TMP/intl.$i"
    done
    G[intl_ok_n]=$ok_n
    G[intl_total]=${#INTL_TARGETS[@]}
    # CDN 资产结果:名称|显示|耗时ms|等级
    local cname ccode ct cdisp clvl cdn_ok=0
    for ((ci=0; ci<${#CDN_ASSETS[@]}; ci++)); do
        [ -s "$HQ_TMP/cdnasset.$ci" ] || continue
        IFS='|' read -r cname ccode ct _spd <"$HQ_TMP/cdnasset.$ci"
        clvl=bad; cdisp="❌"
        if [ "${ccode:-000}" = 200 ]; then
            cdn_ok=$((cdn_ok+1)); clvl=good
            cdisp=$(awk -v t="$ct" 'BEGIN{printf "%.0fms", t*1000}')
            awk -v t="$ct" 'BEGIN{exit !(t>1.5)}' && clvl=warn
        fi
        CDN_ROWS+=("$cname|$cdisp|$ct|$clvl")
        printf '  %-14s %s%s%s\n' "CDN·$cname" "$([ "$clvl" = good ] && printf '%s' "$C_GREEN" || { [ "$clvl" = warn ] && printf '%s' "$C_YELLOW" || printf '%s' "$C_RED"; })" "$cdisp" "$C_OFF"
        rm -f "$HQ_TMP/cdnasset.$ci"
    done
    [ ${#CDN_ROWS[@]} -gt 0 ] && kv "$(L cdngrp 'CDN 资源可达')" "$cdn_ok/${#CDN_ASSETS[@]} (jquery.min.js 真实拉取)"
    if [ -s "$HQ_TMP/intl.cdn" ]; then
        local spd
        spd=$(cat "$HQ_TMP/intl.cdn")
        if is_num "$spd" && [ "$(awk -v s="$spd" 'BEGIN{print (s>0)?1:0}')" = 1 ]; then
            G[intl_cdn]=$(awk -v s="$spd" 'BEGIN{printf "%.2f", s*8/1000000}')
        fi
        rm -f "$HQ_TMP/intl.cdn"
    fi
    kv "国际可达" "$ok_n/${#INTL_TARGETS[@]} 站${G[intl_cdn]:+ · CDN ↓$(fmt_mbps "${G[intl_cdn]}")}"
    # DNS 解析比对(劫持/污染检测)
    dns_hijack_check
    # 国际多区域单线程测速(原型第二行卡;tiny 模式跳过)
    [ "$HQ_MODE" = tiny ] || intlspd_run
    return 0
}

# ============================================================
# 国际多区域单线程测速(原型"国际多区域测速(单线程)"卡)
# 每区域:两次 TCP 握手 → 延迟对;顺序分块 range 下载(单连接语义)
#         + ss -ti 采样 TCP 重传率;上传无零依赖公共端点 → 如实"待检测"
# ============================================================
# 目标|下载URL|纬度|经度(经纬度用于解析该城市 Ookla 服务器的 upload.php 上行端点)
INTLSPD_TARGETS=(
    "日本东京|https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin|35.68|139.69"
    "新加坡|https://sgp-ping.vultr.com/vultr.com.100MB.bin|1.35|103.82"
    "中国香港|http://speedtest.hk.chinamobile.com:8080/speedtest/random4000x4000.jpg|22.32|114.17"
    "英国伦敦|https://lon-gb-ping.vultr.com/vultr.com.100MB.bin|51.51|-0.13"
    "美国西海岸|https://lax-ca-us-ping.vultr.com/vultr.com.100MB.bin|34.05|-118.24"
    "美国东海岸|https://ash-speed.hetzner.com/100MB.bin|38.9|-77.04"
    "德国法兰克福|https://fra-de-ping.vultr.com/vultr.com.100MB.bin|50.11|8.68"
    "巴西圣保罗|http://speedtest.sao01.softlayer.com/downloads/test100.zip|-23.55|-46.63"
    "澳大利亚悉尼|https://syd-au-ping.vultr.com/vultr.com.100MB.bin|-33.87|151.21"
    "加拿大多伦多|https://tor-ca-ping.vultr.com/vultr.com.100MB.bin|43.65|-79.38"
    "法国巴黎|https://par-fr-ping.vultr.com/vultr.com.100MB.bin|48.86|2.35"
    "荷兰阿姆斯特丹|https://ams-nl-ping.vultr.com/vultr.com.100MB.bin|52.37|4.90"
)

# Apple CDN 大文件:mesu 清单动态发现 swcdn ipsw(静态路径易失效,动态最稳)
apple_cdn_url() {
    local x u
    x=$(curl -s --compressed --connect-timeout 4 --max-time 12 -A "$M_UA" \
        "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml" 2>/dev/null | head -c 400000)
    u=$(printf '%s' "$x" | grep -oE 'https://swcdn\.apple\.com/content/downloads/[A-Za-z0-9_/.-]+' | head -n1)
    # 回退:ipsw.me 固件清单(同样落在 Apple 自家 CDN)
    if [ -z "$u" ]; then
        x=$(curl -s --compressed --connect-timeout 4 --max-time 10 -A "$M_UA" \
            "https://api.ipsw.me/v4/device/iPhone16,1" 2>/dev/null | head -c 200000)
        u=$(printf '%s' "$x" | grep -oE 'https://[a-z0-9.-]*(apple|mzstatic)[a-z0-9.-]*/[^"\\ ]+' | head -n1)
    fi
    printf '%s' "$u"
}

# ---------- 端点健康状态(跨运行持久;连续失败≥2 次且在 24h 内 → 视为故障,24h 后重新准入) ----------
_ep_dir() { printf '%s/ep' "$HQ_HOME"; mkdir -p "$(_ep_dir_raw)" 2>/dev/null; }
_ep_dir_raw() { printf '%s/ep' "$HQ_HOME"; }
ep_bad() { # <key> -> 返回 0=故障(跳过) 1=健康
    local f cnt ts
    f="$(_ep_dir_raw)/$1"
    [ -f "$f" ] || return 1
    read -r cnt ts <"$f" 2>/dev/null || return 1
    [ "${cnt:-0}" -ge 2 ] 2>/dev/null || return 1
    [ -z "$(find "$f" -mmin +1440 2>/dev/null)" ] && return 0   # 24h 内连续失败≥2
    rm -f "$f"; return 1   # 记录超过 24h:解除故障,重新尝试
}
ep_fail() { local f; f="$(_ep_dir_raw)/$1"; mkdir -p "$(_ep_dir_raw)" 2>/dev/null
    local cnt=0; [ -f "$f" ] && read -r cnt _ <"$f" 2>/dev/null
    printf '%d %s\n' "$(( ${cnt:-0} + 1 ))" "$(date +%s)" >"$f"; }
ep_ok() { rm -f "$(_ep_dir_raw)/$1" 2>/dev/null; }

# TOS 三网入口:优先社区远程节点表(含备份链),失败回退内置候选
# 输出每 ISP 一行: "isp|ip1,ip2,..."(target host 由 region 推导)
TOS_NODES_BUILTIN=(
    "电信|42.81.80.86,180.97.50.1,14.119.66.1"
    "联通|119.250.10.100,116.147.21.1,36.249.75.222,221.194.175.109"
    "移动|120.255.0.180,36.151.164.132,112.48.236.197"
)
tos_nodes_load() {
    local cf="$HQ_HOME/tos_nodes.tsv" out="" isp ips
    mkdir -p "$HQ_HOME" 2>/dev/null
    if [ ! -s "$cf" ] || [ -n "$(find "$cf" -mmin +720 2>/dev/null)" ]; then
        curl -fsSL --connect-timeout 5 --max-time 12             "https://tcpquality.ibsgss.uk/getNodes?format=tsv&scope=tos" >"$cf" 2>/dev/null || true
    fi
    local got=0
    if [ -s "$cf" ]; then
        for isp in 电信 联通 移动; do
            ips=$(awk -F'\t' -v isp="$isp" '$1=="tos" && $2==4 && $4==isp && !seen[$6]++ {print $6}' "$cf" 2>/dev/null | head -6 | paste -sd, - 2>/dev/null)
            if [ -n "$ips" ]; then printf '%s|%s\n' "$isp" "$ips"; got=1; fi
        done
        # family=6 行存在时输出 "运营商6|v6入口,...":mod_speed 据此做真实分运营商 v6 测速
        for isp in 电信 联通 移动; do
            ips=$(awk -F'\t' -v isp="$isp" '$1=="tos" && $2==6 && $4==isp && !seen[$6]++ {print $6}' "$cf" 2>/dev/null | head -4 | paste -sd, - 2>/dev/null)
            if [ -n "$ips" ]; then printf '%s6|%s\n' "$isp" "$ips"; got=1; fi
        done
    fi
    [ "$got" = 1 ] && return
    printf '%s\n' "${TOS_NODES_BUILTIN[@]}"
}

# tos_host_for <入口IP> -> SNI 主机(从远程表反查 target;内置表按 IP 段推导)
tos_host_for() { # <入口IP> -> SNI 主机(probe-bucket-<城市>.tos-<区域>.volces.com)
    local ip=$1 t city
    if [ -s "$HQ_HOME/tos_nodes.tsv" ]; then
        t=$(awk -F'\t' -v ip="$ip" '$6==ip {print $8; exit}' "$HQ_HOME/tos_nodes.tsv" 2>/dev/null)
    fi
    case "${t:-}" in
        tos-cn-beijing.volces.com)   city=beijing ;;
        tos-cn-shanghai.volces.com)  city=shanghai ;;
        tos-cn-guangzhou.volces.com) city=guangzhou ;;
        *) case "$ip" in
               42.81.80.86|119.250.10.100|221.194.175.109|120.255.0.180) city=beijing ;;
               180.97.50.1|116.147.21.1|36.151.164.132)                  city=shanghai ;;
               14.119.66.1|36.249.75.222|112.48.236.197)                 city=guangzhou ;;
               *)                                                       city=beijing ;;
           esac ;;
    esac
    printf 'probe-bucket-%s.tos-cn-%s.volces.com' "$city" "$city"
}

# intl_up_url <纬度> <经度> -> "url1 url2 url3"(Ookla 城市服务器 upload.php;带缓存与一次重试)
intl_up_url() {
    local lat=$1 lon=$2 api _try
    local cdir="${HQ_HOME}/ookla" cf="${HQ_HOME}/ookla/${lat}_${lon}"
    mkdir -p "$cdir" 2>/dev/null
    # 24h 持久缓存命中则不再查询(Ookla API 有 Cloudflare 限流)
    if [ -s "$cf" ] && [ -z "$(find "$cf" -mtime +1 2>/dev/null)" ]; then
        cat "$cf"; return
    fi
    for _try in 1 2 3; do
        api=$(curl -s --connect-timeout 4 --max-time 8 \
            "https://www.speedtest.net/api/js/servers?engine=js&lat=${lat}&lon=${lon}&limit=4" 2>/dev/null)
        case "$api" in
            *error*|'') sleep $(( _try * 3 )) ;;
            *) printf '%s' "$api" | grep -oE '"url":"[^"]*upload\.php"' \
                   | sed 's/"url":"//;s/"$//;s#\\/#/#g' | head -n3 >"$cf" 2>/dev/null
               sleep 1
               break ;;
        esac
    done
    [ -s "$cf" ] && cat "$cf"
}

# intl_spd_up <"url1 url2"> <秒> -> "mbps"(单连接 POST 上传)
intl_spd_up() {
    local upurls=$1 secs=$2 u spd f
    f="$HQ_TMP/ispdup.$$.$RANDOM"
    head -c 8388608 /dev/zero >"$f" 2>/dev/null || return
    for u in $upurls; do
        spd=$(curl -s -o /dev/null -L -X POST --data-binary @"$f" \
            -H 'Content-Type: application/octet-stream' \
            --connect-timeout 4 --max-time "$secs" \
            -w '%{speed_upload}' "$u" 2>/dev/null)
        is_num "$spd" && [ "$(awk -v v="$spd" 'BEGIN{print (v>0)?1:0}')" = 1 ] && {
            rm -f "$f"
            awk -v v="$spd" 'BEGIN{printf "%.1f", v*8/1000000}'
            return
        }
        head -c 8388608 /dev/zero >"$f" 2>/dev/null || break
    done
    rm -f "$f" 2>/dev/null
}

# intl_spd_dl <url> <秒> -> "mbps|retrans|remote_ip"
# 单线程语义:同一时刻只有一条下载连接;顺序 range 分块(30MB/块)循环拉取直到时间窗耗尽,
# 快管不因文件下载完而低估;期间采样一次 ss -ti 得重传率。
intl_spd_dl() {
    local url=$1 secs=$2
    local spd_file cpid line s_out s_re rip re sz t0 off bytes el left mbps sz_rip
    local t0 off=0 bytes=0 re=""
    local _h=${url#http://}; _h=${_h#https://}; _h=${_h%%/*}
    rip=$(getent ahostsv4 "$_h" 2>/dev/null | awk '{print $1}' | head -n1)
    local chunk=$((30*1024*1024))
    t0=$(date +%s)
    while :; do
        local el=$(( $(date +%s) - t0 ))
        [ "$el" -ge "$secs" ] && break
        local left=$(( secs - el ))
        local spd_file="$HQ_TMP/ispd.$$.$RANDOM" cpid line s_out s_re
        curl -s -o /dev/null -w '%{size_download}|%{remote_ip}' --connect-timeout 4 --max-time "$left" \
            -r "$off-$(( off + chunk ))" -A "$HQ_UA" "$url" >"$spd_file" 2>/dev/null &
        cpid=$!
        if [ -z "$re" ] && command -v ss >/dev/null 2>&1 && [ -n "$rip" ]; then
            sleep 1
            s_out=""; s_re=""
            line=$(ss -tin "dst $rip" 2>/dev/null | grep -E 'data_segs_out' | tail -n1)
            [ -n "$line" ] && {
                s_out=$(printf '%s' "$line" | grep -oE 'data_segs_out[: ]+[0-9]+' | grep -oE '[0-9]+' | tail -n1)
                s_re=$(printf '%s' "$line"  | grep -oE 'total_retrans[: ]+[0-9]+' | grep -oE '[0-9]+' | tail -n1)
                [ -n "$s_re" ] || s_re=$(printf '%s' "$line" | grep -oE 'retrans:[0-9]+/[0-9]+' | head -n1 | cut -d/ -f1 | grep -oE '[0-9]+')
                [ -n "$s_re" ] || s_re=0   # 内核在重传为 0 时不输出该字段
            }
            if is_num "$s_out" && [ "$s_out" -gt 0 ] 2>/dev/null && is_num "$s_re"; then
                re=$(awk -v r="$s_re" -v o="$s_out" 'BEGIN{printf "%.2f", r*100/o}')
            fi
        fi
        wait "$cpid" 2>/dev/null
        local sz_rip sz
        sz_rip=$(cat "$spd_file" 2>/dev/null); rm -f "$spd_file"
        sz=${sz_rip%%|*}; [ -n "$rip" ] || rip=${sz_rip#*|}
        is_num "$sz" || sz=0
        [ "$(awk -v a="$sz" 'BEGIN{print (a>0)?1:0}')" = 1 ] || break
        bytes=$(awk -v b="$bytes" -v s="$sz" 'BEGIN{printf "%.0f", b+s}')
        off=$(( off + chunk ))
        [ "$off" -ge 104857600 ] && off=0
    done
    local el=$(( $(date +%s) - t0 ))
    [ "$el" -lt 1 ] && el=1
    local mbps=""
    [ "$bytes" -gt 0 ] && mbps=$(awk -v b="$bytes" -v t="$el" 'BEGIN{printf "%.1f", b*8/t/1000000}')
    printf '%s|%s|%s' "$mbps" "${re:-}" "$rip"
}

intlspd_run() {
    note "$(L intlspd_note '国际区域单线程测速(每区域单连接 5s 下载 + Ookla 城市服务器单连接上行 + 重传采样)')"
    local i=0 t name url tlat tlon uurls
    local -a jobs=()
    for t in "${INTLSPD_TARGETS[@]}"; do
        IFS='|' read -r name url tlat tlon <<< "$t"
        uurls=""
        [ -n "${tlat:-}" ] && uurls=$(intl_up_url "$tlat" "$tlon")
        (
            _url=$url
            _r1="" _r2="" _dl="" _re="" _up=""
            if [ -n "$_url" ]; then
                # v2.6:握手延迟同样剔除 DNS 解析耗时(time_connect - time_namelookup)
                _c1=$(curl -s -o /dev/null -w '%{time_namelookup}|%{time_connect}' --connect-timeout 4 --max-time 6 "$_url" 2>/dev/null)
                _c2=$(curl -s -o /dev/null -w '%{time_namelookup}|%{time_connect}' --connect-timeout 4 --max-time 6 -r 0-1024 "$_url" 2>/dev/null)
                _t1=${_c1%%|*}; _u1=${_c1#*|}
                _t2=${_c2%%|*}; _u2=${_c2#*|}
                is_num "$_u1" && is_num "$_t1" && [ "$(awk -v c="$_u1" -v n="$_t1" 'BEGIN{print (c-n>0)?1:0}')" = 1 ] && _r1=$(awk -v c="$_u1" -v n="$_t1" 'BEGIN{printf "%.0f", (c-n)*1000}')
                is_num "$_u2" && is_num "$_t2" && [ "$(awk -v c="$_u2" -v n="$_t2" 'BEGIN{print (c-n>0)?1:0}')" = 1 ] && _r2=$(awk -v c="$_u2" -v n="$_t2" 'BEGIN{printf "%.0f", (c-n)*1000}')
                IFS='|' read -r _dl _re _rip <<< "$(intl_spd_dl "$_url" 5)"
                [ -n "${uurls:-}" ] && _up=$(intl_spd_up "$uurls" 5)
            fi
            printf '%s|%s|%s|%s|%s|%s|%s' "$name" "${_r1:-}" "${_r2:-}" "${_dl:-}" "${_up:-}" "${_re:-}" "${_url:+found}"
        ) >"$HQ_TMP/intlspd.$i" &
        jobs+=($!)
        hq_throttle
        i=$((i+1))
    done
    wait "${jobs[@]}" 2>/dev/null
    i=0
    local rname r1 r2 dl up re found st
    for t in "${INTLSPD_TARGETS[@]}"; do
        IFS='|' read -r name url _la _lo <<< "$t"
        [ -s "$HQ_TMP/intlspd.$i" ] || { INTLSPD_ROWS+=("$name|待检测||||||"); i=$((i+1)); continue; }
        IFS='|' read -r rname r1 r2 dl up re found <"$HQ_TMP/intlspd.$i"
        rm -f "$HQ_TMP/intlspd.$i"
        st="待检测"
        if is_num "$dl" && [ "$(awk -v d="$dl" 'BEGIN{print (d>0)?1:0}')" = 1 ]; then
            st=$(awk -v d="$dl" -v u="${up:-0}" 'BEGIN{print (d>=2000)?"优":(d>=300||u>=300)?"良好":"一般"}')
        elif is_num "$up" && [ "$(awk -v d="$up" 'BEGIN{print (d>0)?1:0}')" = 1 ]; then
            st="部分"   # 上行可用但下行未取得
        elif [ -n "${r1:-}" ] || [ -n "${r2:-}" ]; then
            st="部分"   # TCP 可达但未取得有效吞吐
        fi
        INTLSPD_ROWS+=("$rname|$st|${dl:-}|${up:-}|${r1:-}|${r2:-}|${re:-}")
        printf '  %-16s %s%s%s%s  ↓%s%s%s%s\n' "$rname" \
            "$([ "$st" = 优 ] || [ "$st" = 良好 ] && printf '%s' "$C_GREEN" || { [ "$st" = 一般 ] && printf '%s' "$C_YELLOW" || printf '%s' "$C_DIM"; })" \
            "$st" "$C_OFF" "$(fmt_mbps "$dl")" "${r1:+${C_DIM} 延迟 ${r1}/${r2}ms${C_OFF}}" "${re:+${C_DIM} 重传${re}%${C_OFF}}" ""
        i=$((i+1))
    done
}

# ---------- 测速 ----------

dl_speedtest_go() {  # 下载 speedtest-go 到 HQ_BIN,成功返回 0
    [ -n "$HQ_GOARCH" ] || return 1
    local bin="$HQ_BIN/speedtest-go"
    [ -s "$bin" ] && { printf '%s' "$bin"; return 0; }
    local url
    url=$(gh_asset_url "showwin/speedtest-go" "Linux_${HQ_GOARCH}\.tar\.gz$") || { warn "获取 speedtest-go 下载地址失败"; return 1; }
    hq_download "$url" "$HQ_TMP/st.tar.gz" || { warn "speedtest-go 下载失败"; return 1; }
    tar -xzf "$HQ_TMP/st.tar.gz" -C "$HQ_BIN" 2>/dev/null || return 1
    local found
    found=$(find "$HQ_BIN" -type f -name 'speedtest*' | head -n1)
    [ -n "$found" ] || return 1
    chmod +x "$found" 2>/dev/null
    printf '%s' "$found"
}

stgo_run() { # <额外参数...> -> 输出 "down|up|server|host"(速度 Mbps;host 供 TCP 握手测延迟)
    local bin=$1; shift
    local out down up server host nm sp
    # JSON 输出:dl_speed/ul_speed 单位为 bytes/s;不信任其 HTTP ping 延迟(长肥路径虚高)
    out=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        "$bin" --json "$@" 2>/dev/null) || true
    down=$(printf '%s' "$out" | grep -oE '"dl_speed":[0-9.]+' | grep -oE '[0-9.]+' | head -n1)
    up=$(printf '%s' "$out"   | grep -oE '"ul_speed":[0-9.]+' | grep -oE '[0-9.]+' | head -n1)
    host=$(printf '%s' "$out" | grep -oE '"host":"[^"]+"' | head -n1 | cut -d'"' -f4)
    nm=$(printf '%s' "$out"  | grep -oE '"name":"[^"]+"' | head -n1 | cut -d'"' -f4)
    sp=$(printf '%s' "$out"  | grep -oE '"sponsor":"[^"]+"' | head -n1 | cut -d'"' -f4)
    server="$(printf '%s' "$nm" | cut -c1-26)${sp:+ · $(printf '%s' "$sp" | cut -c1-14)}"
    if is_num "$down" && [ "$(awk -v s="$down" 'BEGIN{print (s>0)?1:0}')" = 1 ]; then
        down=$(awk -v s="$down" 'BEGIN{printf "%.2f", s*8/1000000}')
    else
        down=""
    fi
    if is_num "$up" && [ "$(awk -v s="$up" 'BEGIN{print (s>0)?1:0}')" = 1 ]; then
        up=$(awk -v s="$up" 'BEGIN{printf "%.2f", s*8/1000000}')
    else
        up=""
    fi
    printf '%s|%s|%s|%s' "${down:-}" "${up:-}" "${server:-}" "${host:-}"
}

# TOS 对象存储三网测速(固定入口 IP 方案)
tos_test() { # <bucket域名> <入口IP> <运营商> <下行秒> <上行秒>
    local host=$1 ip=$2 isp=$3 dsec=$4 usec=$5
    local down="" up="" spd uuid retrans=""
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo $$)
    local rip="$ip"; case "$ip" in *:*) rip="[$ip]" ;; esac   # curl --resolve / ss 的 v6 均需括号

    # 下行: range GET, 按时间截断;期间用 ss 采样该连接的重传率
    if command -v ss >/dev/null 2>&1 && [ "$HQ_MODE" != tiny ]; then
        local spd_file="$HQ_TMP/tos_spd.$$" cpid line s_out="" s_re=""
        curl -s -o /dev/null -w '%{speed_download}' --connect-timeout 4 --max-time "$dsec" \
            --resolve "$host:443:$rip" -r 0-536870911 "https://${host}/download/test" >"$spd_file" 2>/dev/null &
        cpid=$!
        local _i
        for _i in $(seq 1 "$dsec"); do
            sleep 1
            line=$(ss -tin "dst $rip" 2>/dev/null | grep -E 'data_segs_out' | tail -n1)
            [ -n "$line" ] && {
                s_out=$(printf '%s' "$line" | grep -oE 'data_segs_out[: ]+[0-9]+' | grep -oE '[0-9]+' | tail -n1)
                s_re=$(printf '%s' "$line"  | grep -oE 'total_retrans[: ]+[0-9]+' | grep -oE '[0-9]+' | tail -n1)
                [ -n "$s_re" ] || s_re=$(printf '%s' "$line" | grep -oE 'retrans:[0-9]+/[0-9]+' | head -n1 | cut -d/ -f1 | grep -oE '[0-9]+')
                [ -n "$s_re" ] || s_re=0   # 内核在重传为 0 时不输出该字段
            }
        done
        wait "$cpid" 2>/dev/null
        spd=$(cat "$spd_file" 2>/dev/null); rm -f "$spd_file"
        if is_num "$s_out" && [ "$s_out" -gt 0 ] 2>/dev/null && is_num "$s_re"; then
            retrans=$(awk -v r="$s_re" -v o="$s_out" 'BEGIN{printf "%.2f", r*100/o}')
            G[tos_retrans_${isp}]=$retrans
        fi
    else
        spd=$(curl -s -o /dev/null -w '%{speed_download}' --connect-timeout 4 --max-time "$dsec" \
            --resolve "$host:443:$ip" -r 0-536870911 "https://${host}/download/test" 2>/dev/null)
    fi
    # 连接失败时 %{speed_download} 为 0:视为不可达而非 0 速
    is_num "$spd" && [ "$(awk -v s="$spd" 'BEGIN{print (s>0)?1:0}')" = 1 ] && down=$(awk -v s="$spd" 'BEGIN{printf "%.2f", s*8/1000000}')
    [ -z "$down" ] && spd=$(curl -s -o /dev/null -w '%{speed_download}' --connect-timeout 4 --max-time "$dsec" \
        -r 0-536870911 "https://${host}/download/test" 2>/dev/null) && is_num "$spd" && \
        [ "$(awk -v s="$spd" 'BEGIN{print (s>0)?1:0}')" = 1 ] && down=$(awk -v s="$spd" 'BEGIN{printf "%.2f", s*8/1000000}')

    # 上行: 流式 PUT(-T - 为 chunked 传输,边读边发,RSS 恒定;
    #       不可用 --data-binary @-:它会把 stdin 全量缓冲进内存,小内存机器直接 OOM)
    local sent tsend up_mb=4096
    [ "$OPT_LOWRES" = 1 ] && up_mb=512
    read -r sent tsend <<< "$(dd if=/dev/zero bs=1M count=$up_mb status=none 2>/dev/null | \
        curl -s -o /dev/null -X PUT -T - --max-time "$usec" --connect-timeout 4 \
        --resolve "$host:443:$rip" -w '%{size_upload} %{time_total}' \
        "https://${host}/upload/${uuid}" 2>/dev/null | awk '{print $1, $2}')" || true
    if is_num "$sent" && [ "$sent" -gt 0 ] 2>/dev/null && is_num "$tsend" && [ "$(awk -v t="$tsend" 'BEGIN{print (t>0.5)?1:0}')" = 1 ]; then
        up=$(awk -v b="$sent" -v t="$tsend" 'BEGIN{printf "%.2f", b*8/t/1000000}')
    fi
    curl -s -o /dev/null --max-time 5 --resolve "$host:443:$rip" -X DELETE "https://${host}/upload/${uuid}" 2>/dev/null

    [ -z "$down" ] && [ -z "$up" ] && return 1
    printf '%s|%s|%s' "${down:-}" "${up:-}" "${retrans:-}"
}

# CDN 测速回退(仅下行,读 speed_download;0 视为失败)
cdn_dl() { # <url> -> Mbps
    local spd
    spd=$(curl -s -o /dev/null -w '%{speed_download}' --connect-timeout 4 --max-time 12 "$1" 2>/dev/null)
    is_num "$spd" && [ "$(awk -v s="$spd" 'BEGIN{print (s>0)?1:0}')" = 1 ] || { printf ''; return; }
    awk -v s="$spd" 'BEGIN{printf "%.2f", s*8/1000000}'
}

mod_speed() {
    sec "$(L speed '带宽测速') Speedtest"
    local dsec=10 usec=8
    [ "$HQ_MODE" = full ] && { dsec=12; usec=8; }
    [ "$HQ_MODE" = tiny ] && { dsec=6; usec=4; }
    [ "$OPT_LOW_TRAFFIC" = 1 ] && { dsec=$((dsec/2)); usec=$((usec/2)); }

    # 1) speedtest-go 就近节点(上下行);极小/低资源模式不下载二进制,纯 curl 测速
    local stbin=""
    if [ "$HQ_MODE" != tiny ] && [ "$OPT_LOWRES" != 1 ]; then
        stbin=$(dl_speedtest_go)
    else
        [ "$HQ_MODE" = tiny ] && note "极小模式:跳过 speedtest-go 下载,使用 curl 定向测速" \
                               || note "低资源模式:跳过 speedtest-go 下载,使用 curl 定向测速"
    fi
    if [ -n "$stbin" ]; then
        note "测试临近节点 (speedtest-go)..."
        local res down up slat server
        res=$(stgo_run "$stbin")
        local stgo_host=""
        IFS='|' read -r down up server stgo_host <<< "$res"
        if [ -n "$down" ]; then
            SPEED_ROWS+=("就近节点|${down}|${up:-}|${server:-}")
            kv "临近节点" "↓ $(fmt_mbps "$down")  ↑ $(fmt_mbps "$up") ${C_DIM}${server}${C_OFF}"
            G[best_down]=$down; G[best_up]=${up:-}
            G[spd_src]=stgo
            # 延迟:对选中服务器做两次 TCP 握手(不用 speedtest-go 的 HTTP ping,
            # 其整请求往返在长肥/受扰路径上会虚高数倍,且无法区分单值/双值口径)
            if [ -n "$stgo_host" ]; then
                local _shp="${stgo_host%%:*}" _spt="${stgo_host##*:}" _i _ct _ms
                [ "$_spt" = "$stgo_host" ] && _spt=8080
                G[stgo_tcp1]=""; G[stgo_tcp2]=""
                for _i in 1 2; do
                    _ct=$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 4 --max-time 6 \
                        --noproxy '*' "http://${_shp}:${_spt}/" 2>/dev/null)
                    if is_num "$_ct" && [ "$(awk -v t="$_ct" 'BEGIN{print (t>0)?1:0}')" = 1 ]; then
                        _ms=$(awk -v t="$_ct" 'BEGIN{printf "%.1f", t*1000}')
                        if [ -z "${G[stgo_tcp1]:-}" ]; then G[stgo_tcp1]=$_ms; else G[stgo_tcp2]=$_ms; fi
                    fi
                done
            fi
        else
            warn "speedtest-go 未取得结果,回退 CDN 测速"
        fi
        # 完整模式:补测 区域节点(仅下行——Ookla 上行窗口约占一半时长且远端上行参考价值低)
        if [ "$HQ_MODE" = full ]; then
            local cc cn stnu=""
            # 旧版缓存二进制可能无 --no-upload:先探测能力(带 --help 不会真正发起测试)
            "$stbin" --no-upload --help >/dev/null 2>&1 && stnu="--no-upload"
            [ -n "$stnu" ] && note "区域节点仅下行实测(跳过远端上行,缩短总耗时)"
            for cc in HK JP SG US; do
                case $cc in HK) cn="香港";; JP) cn="日本";; SG) cn="新加坡";; US) cn="美国";; esac
                res=$(stgo_run "$stbin" $stnu --filter-cc=$cc) || continue
                IFS='|' read -r down up server _stgoh <<< "$res"
                [ -z "$down" ] && continue
                SPEED_ROWS+=("$cn节点|${down}|${up:-}|${server:-}")
                kv "$cn节点" "↓ $(fmt_mbps "$down")  ↑ $( [ -n "${up:-}" ] && fmt_mbps "$up" || printf -- '—(仅下行)' ) ${C_DIM}${server}${C_OFF}"
            done
        fi
    else
        warn "speedtest-go 不可用,使用 CDN 回退测速"
    fi

    # 2) 三网方向(火山引擎 TOS 定向入口):远程节点表候选链 + 健康状态动态切换
    #    表中 family=6 行以 "运营商6|v6入口,..." 下发,有则做真实分运营商 v6 定向测速
    if [ -n "${G[ip4]:-}" ] || [ -n "${G[ip6]:-}" ]; then
        local th row down up rtr tnl tn isp ips tip host tried ispb isv6
        tos_nodes_load >"$HQ_TMP/tosnodes.$$" 2>/dev/null
        while IFS='|' read -r isp ips; do
            [ -n "$isp" ] || continue
            case "$isp" in
                *6) ispb=${isp%6}; isv6=1 ;;
                *)  ispb=$isp;    isv6=0 ;;
            esac
            row=""; tried=""
            for tip in ${ips//,/ }; do
                ep_bad "tos_${isp}_${tip}" && continue    # 24h 内连续失败:跳过
                host=$(tos_host_for "$tip")
                if row=$(tos_test "$host" "$tip" "$isp" "$dsec" "$usec"); then
                    ep_ok "tos_${isp}_${tip}"; tried=$tip; break
                fi
                ep_fail "tos_${isp}_${tip}"; tried="${tried:+$tried,}$tip"
            done
            if [ -n "$row" ]; then
                IFS='|' read -r down up rtr <<< "$row"
                is_num "${rtr:-}" && G[tos_retrans_${isp}]=$rtr
                if [ "$isv6" = 1 ]; then
                    V6TOS_ROWS+=("${ispb}|${down:-}|${up:-}|tos6")
                    SPEED_ROWS+=("中国${ispb}v6方向|${down:-}|${up:-}|TOS v6 定向${rtr:+ · $(L retr 重传)${rtr}%}")
                    kv "中国${ispb}(v6)方向" "↓ $(fmt_mbps "$down")  ↑ $(fmt_mbps "$up") ${C_DIM}TOS v6@${tip}${rtr:+ · $(L retr 重传)${rtr}%}${C_OFF}"
                else
                    SPEED_ROWS+=("中国${isp}方向|${down:-}|${up:-}|TOS 定向${rtr:+ · $(L retr 重传)${rtr}%}")
                    kv "中国${isp}方向" "↓ $(fmt_mbps "$down")  ↑ $(fmt_mbps "$up") ${C_DIM}TOS@${tip}${rtr:+ · $(L retr 重传)${rtr}%}${C_OFF}"
                fi
            else
                kv "${isp}方向" "不可达${tried:+ ${C_DIM}(尝试 $tried)${C_OFF}}"
            fi
        done <"$HQ_TMP/tosnodes.$$"
        rm -f "$HQ_TMP/tosnodes.$$"

    fi

    # 3) IPv6 双栈检测:Cloudflare v6 上下行(有 v6 地址时)
    if [ -n "${G[ip6]:-}" ] && [[ $OPT_IPV == *6* ]]; then
        local v6s v6d="" v6b v6t v6u="" v6_mb=1024
        [ "$OPT_LOWRES" = 1 ] && v6_mb=256
        local v6url
        for v6url in "https://speed.cloudflare.com/__down?bytes=200000000" \
                     "https://proof.ovh.net/files/100Mb.dat" \
                     "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz"; do
            v6s=$(curl -6 -s -o /dev/null -w '%{speed_download}' --noproxy '*' \
                --connect-timeout 4 --max-time "$dsec" "$v6url" 2>/dev/null)
            if is_num "$v6s" && [ "$(awk -v s="$v6s" 'BEGIN{print (s>125000)?1:0}')" = 1 ]; then
                v6d=$(awk -v s="$v6s" 'BEGIN{printf "%.2f", s*8/1000000}'); break
            fi
        done
        # -T - 流式上传(避免 --data-binary @- 的全量内存缓冲)
        read -r v6b v6t <<< "$(dd if=/dev/zero bs=1M count=$v6_mb status=none 2>/dev/null | \
            curl -6 -s -o /dev/null -X POST -T - --max-time "$usec" --connect-timeout 4 --noproxy '*' \
            -w '%{size_upload} %{time_total}' "https://speed.cloudflare.com/__up" 2>/dev/null | awk '{print $1, $2}')" || true
        if is_num "${v6b:-}" && is_num "${v6t:-}" && [ "$(awk -v t="$v6t" 'BEGIN{print (t>0.5)?1:0}')" = 1 ]; then
            v6u=$(awk -v b="$v6b" -v t="$v6t" 'BEGIN{printf "%.2f", b*8/t/1000000}')
        fi
        if [ -n "$v6d$v6u" ]; then
            SPEED_ROWS+=("CF v6|${v6d:-}|${v6u:-}|IPv6 CDN")
            kv "Cloudflare v6" "↓ $(fmt_mbps "$v6d")  ↑ $(fmt_mbps "$v6u") ${C_DIM}IPv6 CDN${C_OFF}"
            is_num "$v6d" && G[cf6_down]=$v6d
            is_num "$v6u" && G[cf6_up]=$v6u
        fi
    fi

    # 3b) 三网卡 IPv6 行测速:仅当 TOS 节点表出现 family=6 行时才有分运营商 v6 实测
    #     (见上方 电信6|联通6|移动6 分支);否则跳过、如实标未检测——
    #     不用 Cloudflare 国际 v6 单值冒充运营商方向速度,待节点可用后自动实测

    # 4) 无任何结果时 CDN 兜底
    if [ ${#SPEED_ROWS[@]} -eq 0 ]; then
        local d
        for row in "Cloudflare|https://speed.cloudflare.com/__down?bytes=200000000" \
                   "CacheFly|http://cachefly.cachefly.net/100mb.test" \
                   "OVH|https://proof.ovh.net/files/100Mb.dat"; do
            IFS='|' read -r name d <<< "$row"
            down=$(cdn_dl "$d")
            [ -z "$down" ] && continue
            SPEED_ROWS+=("${name}下载|${down}||CDN")
            kv "${name}下载" "↓ $(fmt_mbps "$down")"
        done
        [ -n "${down:-}" ] && G[best_down]=$down
    fi

    # 汇总最优值(记录来源,摘要"网络"行注明测试类型)
    local r best_d=0 best_u=0 best_dn="" best_un=""
    [ ${#SPEED_ROWS[@]} -gt 0 ] && for r in "${SPEED_ROWS[@]}"; do
        IFS='|' read -r name down up _ <<< "$r"
        is_num "$down" && awk -v a=$best_d -v b=$down 'BEGIN{exit !(b>a)}' && { best_d=$down; best_dn=$name; }
        is_num "$up"   && awk -v a=$best_u -v b=$up   'BEGIN{exit !(b>a)}' && { best_u=$up; best_un=$name; }
    done
    [ "$best_d" != 0 ] && G[best_down]=$best_d
    [ "$best_u" != 0 ] && G[best_up]=$best_u
    if [ "$best_d" != 0 ]; then G[best_src]=$(spd_src_label "$best_dn")
    elif [ "$best_u" != 0 ]; then G[best_src]=$(spd_src_label "$best_un"); fi
}
# ============================================================
# M4 IP 质量(Scamalytics / ipapi.is / 原生广播 / DNSBL / 25端口)
# ============================================================
# 使用类型归一化(nodequality 口径):输入 ipapi.is company.type / ip2location usage_type
# -> "类别|样式键"(如 机房|idc);未知返回空
usage_type_cat() { # <raw>
    local r
    r=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' -_')
    case "$r" in
        hosting|host|dch|datacenter|server) printf '机房|idc' ;;
        business|com|commercial)            printf '商业|biz' ;;
        isp)                                 printf '家宽|res' ;;
        mobile|mob)                          printf '手机|mob' ;;
        education|edu)                       printf '教育|edu' ;;
        government|gov)                      printf '政府|gov' ;;
        banking|bank)                        printf '银行|bank' ;;
        cdn)                                 printf 'CDN|cdn' ;;
        *) printf '' ;;
    esac
}

# DNSBL 兜底域(运行时下载全量列表失败时使用)
DNSBL_FALLBACK_ZONES="zen.spamhaus.org b.barracudacentral.org bl.spamcop.net dnsbl.sorbs.net dnsbl-1.uceprotect.net psbl.surriel.com bl.mailspike.net spam.spamrats.com db.wpbl.info dnsbl.dronebl.org bl.blocklist.de ips.backscatterer.org cbl.abuseat.org dul.dnsbl.sorbs.net http.dnsbl.sorbs.net socks.dnsbl.sorbs.net misc.dnsbl.sorbs.net smtp.dnsbl.sorbs.net web.dnsbl.sorbs.net spam.dnsbl.sorbs.net truncate.gbudb.net"

dnsbl_zone_list() {
    local f="$HQ_TMP/dnsbl.list" z
    [ -s "$f" ] && { cat "$f"; return 0; }
    z=$(curl -s --noproxy '*' --connect-timeout 4 --max-time 8 \
        "https://raw.githubusercontent.com/xykt/IPQuality/main/ref/dnsbl.list" 2>/dev/null \
        | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' | head -n 500)
    if [ -n "$z" ]; then
        printf '%s\n' "$z" >"$f" 2>/dev/null
        printf '%s\n' "$z"
    else
        printf '%s\n' $DNSBL_FALLBACK_ZONES
    fi
}

# IP 地址黑名单数据库(nodequality/xykt 同款全量域,~420 家)
# 分类:NXDOMAIN/无记录/127.255.255.* → 正常;127.0.0.2 → 黑名单;其他 127.* → 已标记
# 有效 = 得到明确应答(NXDOMAIN/NOERROR)的域数
# 结果写入 G[<pfx>valid/clean/marked/black](pfx 传 dnsbl_ 或 dnsbl6_)
dnsbl_check_ip() { # <ip> <v4|v6> <pfx:dnsbl_ 或 dnsbl6_>
    command -v dig >/dev/null 2>&1 || return 1
    local ip=$1 fam=$2 pfx=$3
    local rev zone
    if [ "$fam" = v4 ]; then
        rev=$(printf '%s' "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
    else
        rev=$(ipv6_nibbles "$ip")
        [ -n "$rev" ] || return 1
    fi
    local tmpd; tmpd=$(mktemp -d "$HQ_TMP/dnsblk.XXXXXX" 2>/dev/null) || return 1
    local -a batch=()
    local n=0 zone
    while IFS= read -r zone; do
        [ -n "$zone" ] || continue
        (
            # +comments 拿 status 行以区分 NXDOMAIN(未收录)与超时(无效)
            _o=$(dig +time=2 +tries=1 +noall +answer +comments A "${rev}.${zone}" @8.8.8.8 2>/dev/null)
            _st=$(printf '%s' "$_o" | grep -oE 'status: [A-Z]+' | head -n1 | awk '{print $2}')
            _a=$(printf '%s' "$_o" | grep -E '^[^;].*[[:space:]]IN[[:space:]]+A[[:space:]]' | grep -oE '127\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            case "$_st" in
                NOERROR|NXDOMAIN)
                    case "$_a" in
                        "")                                  printf 'clean' ;;
                        127.0.0.2)                          printf 'black' ;;
                        127.255.255.*)                      printf 'clean' ;;
                        127.*)                              printf 'marked' ;;
                        *)                                  printf 'clean' ;;
                    esac ;;
                *) printf 'inv' ;;
            esac
        ) >"$tmpd/$n" &
        batch+=($!)
        n=$((n+1))
        if [ ${#batch[@]} -ge $(( HQ_NET * 2 > 40 ? 40 : HQ_NET * 2 )) ]; then wait "${batch[@]}" 2>/dev/null; batch=(); fi
    done < <(dnsbl_zone_list)
    [ ${#batch[@]} -gt 0 ] && wait "${batch[@]}" 2>/dev/null
    local valid=0 clean=0 marked=0 black=0 i r
    for ((i=0; i<n; i++)); do
        [ -s "$tmpd/$i" ] || { rm -f "$tmpd/$i"; continue; }
        r=$(cat "$tmpd/$i" 2>/dev/null)
        rm -f "$tmpd/$i"
        case "$r" in
            clean)  valid=$((valid+1)); clean=$((clean+1)) ;;
            marked) valid=$((valid+1)); marked=$((marked+1)) ;;
            black)  valid=$((valid+1)); black=$((black+1)) ;;
        esac
    done
    rmdir "$tmpd" 2>/dev/null
    G[${pfx}valid]=$valid; G[${pfx}clean]=$clean; G[${pfx}marked]=$marked; G[${pfx}black]=$black
    # 兼容旧字段:total=有效、hits=黑名单
    G[${pfx}total]=$valid; G[${pfx}hits]=$black
    [ "$valid" -gt 0 ]
}

mod_ipq() {
    sec "$(L ipq 'IP 质量') IP Quality"
    local ip="${G[ip4]:-${G[ip6]:-}}"
    if [ -z "$ip" ]; then
        warn "未获取到公网 IP,跳过 IP 质量检测"
        return 1
    fi

    # 1) 基础标记(来自商家识别阶段的 ip-api 数据)
    local proxy="${G[proxy]:-}" hosting="${G[hosting_flag]:-}" mobile="${G[mobile_flag]:-}"
    ipq_add "代理/VPN 标记" "$([ "$proxy" = true ] && echo '是' || echo '否')" "$([ "$proxy" = true ] && echo warn || echo good)"
    ipq_add "机房 IP" "$([ "$hosting" = true ] && echo '是' || echo '否')" na
    ipq_add "移动网络" "$([ "$mobile" = true ] && echo '是' || echo '否')" na

    # 2) Scamalytics 欺诈分数(无 key 抓取)
    local scam scam_score="" scam_risk=""
    scam=$(hq_curl "https://scamalytics.com/ip/${ip}" 10 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36")
    if [ -n "$scam" ]; then
        scam_score=$(printf '%s' "$scam" | grep -oE 'Fraud Score: [0-9]+' | grep -oE '[0-9]+' | head -n1)
        scam_risk=$(printf '%s' "$scam" | grep -oE '(Very High|High|Medium|Low)( |</|[a-z])' | head -n1 | sed 's/[ <]//g')
    fi
    if [ -n "$scam_score" ]; then
        G[fraud_score]=$scam_score; G[fraud_risk]=${scam_risk:-未知}
        local lvl=good
        [ "$scam_score" -ge 25 ] 2>/dev/null && lvl=warn
        [ "$scam_score" -ge 60 ] 2>/dev/null && lvl=bad
        ipq_add "Scamalytics 欺诈分" "$scam_score (${scam_risk:-未知})" "$lvl"
    else
        ipq_add "Scamalytics 欺诈分" "获取失败" na
    fi

    # 2b) ipapi.is 风险分/用途/Tor(免费无 key,任何模式)
    local ipapi_json="" risk2 tor usage_t
    ipapi_json=$(hq_curl "https://api.ipapi.is/?q=${ip}" 10)
    if [ -n "$ipapi_json" ]; then
        risk2=$(jfield "$ipapi_json" risk_score)
        if is_num "$risk2"; then
            G[fraud2_score]=$risk2
            local lvl2=good
            [ "$risk2" -ge 25 ] 2>/dev/null && lvl2=warn
            [ "$risk2" -ge 60 ] 2>/dev/null && lvl2=bad
            ipq_add "ipapi.is 风险分" "$risk2/100" "$lvl2"
        fi
        tor=$(jfield "$ipapi_json" is_tor)
        [ "$tor" = true ] && ipq_add "Tor 出口" "是" bad
        usage_t=$(jfield "$ipapi_json" company.type)
        [ -n "$usage_t" ] && ipq_add "IP 用途 (ipapi.is)" "$usage_t" na
        [ -z "${G[ip_usage]:-}" ] && G[ip_usage]=$usage_t
        # 原型 IP 风险评分卡:公司类型 / 所属公司 / ASN 组织(兼容 ipapi.is 紧凑结构)
        [ -n "$usage_t" ] && G[company_type]=$usage_t
        local _asorg _comp
        _comp=$(jfield "$ipapi_json" company.name)
        [ -z "$_comp" ] && _comp=$(jfield "$ipapi_json" company)
        [ -n "$_comp" ] && G[company_name]=$_comp
        _asorg=$(jfield "$ipapi_json" asn.org)
        [ -z "$_asorg" ] && _asorg=$(jfield "$ipapi_json" asn.descr)
        [ -z "$_asorg" ] && _asorg=$(jfield "$ipapi_json" asn)
        [ -n "$_asorg" ] && G[as_org]=$_asorg
        [ -z "${G[as_org]:-}" ] && G[as_org]=${G[org]:-}
    fi

    # 2c) ip2location.io 用途类型(DCH 机房 / ISP 家宽等,免 key 容错)
    local ip2l usage2
    ip2l=$(hq_curl "https://api.ip2location.io/?ip=${ip}&format=json" 8)
    if [ -n "$ip2l" ]; then
        usage2=$(jfield "$ip2l" usage_type)
        [ -n "$usage2" ] && { ipq_add "IP 用途 (ip2location)" "$usage2" na; G[ip_usage]=$usage2; }
        [ "$(jfield "$ip2l" is_proxy)" = true ] && ipq_add "代理标记 (ip2location)" "是" warn
    fi

    # 2c2) ipinfo.io widget 免 key 使用类型(v2.7 新增:ipapi.is 免费层已改紧凑响应,
    #      不再返回 company.type/risk_score;ipinfo 的 asn.type/company.type 是当前最可靠的免费源)
    if [ -z "${G[ip_usage]:-}" ]; then
        local ipinfo_json _it=""
        ipinfo_json=$(hq_curl "https://ipinfo.io/widget/demo/${ip}" 8)
        if [ -n "$ipinfo_json" ]; then
            if command -v jq >/dev/null 2>&1; then
                _it=$(printf '%s' "$ipinfo_json" | jq -r '.data.asn.type // empty' 2>/dev/null)
                [ -z "$_it" ] && _it=$(printf '%s' "$ipinfo_json" | jq -r '.data.company.type // empty' 2>/dev/null)
            else
                _it=$(printf '%s' "$ipinfo_json" | sed -n '/"asn"[[:space:]]*:/,/}/p' \
                    | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
                    | sed -E 's/.*:[[:space:]]*"//; s/"$//')
                [ -z "$_it" ] && _it=$(printf '%s' "$ipinfo_json" | sed -n '/"company"[[:space:]]*:/,/}/p' \
                    | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
                    | sed -E 's/.*:[[:space:]]*"//; s/"$//')
            fi
            if [ -n "$_it" ]; then
                G[ip_usage]=$_it
                ipq_add "IP 用途 (ipinfo)" "$_it" na
                [ -z "${G[company_type]:-}" ] && G[company_type]=$_it
            fi
            if [ -z "${G[company_name]:-}" ]; then
                local _ic
                _ic=$(jfield "$ipinfo_json" data.company.name)
                [ -n "$_ic" ] && G[company_name]=$_ic
            fi
            if [ -z "${G[as_org]:-}" ]; then
                local _ia
                _ia=$(jfield "$ipinfo_json" data.asn.name)
                [ -n "$_ia" ] && G[as_org]="$(jfield "$ipinfo_json" data.asn.asn) $_ia"
            fi
        fi
    fi

    # 2d) proxycheck.io VPN 标记(免费无 key,约 100 次/日,失败容忍)
    local pcv pcvpn
    pcv=$(hq_curl "https://proxycheck.io/v1/${ip}?vpn=1" 8)
    if [ -n "$pcv" ]; then
        pcvpn=$(printf '%s' "$pcv" | grep -oE '"proxy"[ ]*:[ ]*"(yes|no)"' | grep -oE '(yes|no)' | head -n1)
        local _pct
        _pct=$(printf '%s' "$pcv" | grep -oE '"type"[ ]*:[ ]*"[^"]+"' | head -n1 | grep -oE '"[^"]+"$' | tr -d '"')
        [ -n "$pcvpn" ] && ipq_add "VPN 标记 (proxycheck)" "$([ "$pcvpn" = yes ] && printf '是%s' "${_pct:+ ($_pct)}" || echo '否')" "$([ "$pcvpn" = yes ] && echo warn || echo good)"
    fi

    # 2e) 使用类型归一化(v2.6):机房/商业/家宽/手机…;API 全失败时回退 ip-api hosting 标记
    local _ucat _hf
    _ucat=$(usage_type_cat "${G[ip_usage]:-}")
    if [ -z "$_ucat" ]; then
        _hf="${G[hosting_flag]:-}"
        { [ "$_hf" = true ] || [ "$_hf" = yes ]; } && _ucat="机房|idc"
    fi
    if [ -n "$_ucat" ]; then
        G[ip_usage_cat]=${_ucat%%|*}
        G[ip_usage_key]=${_ucat##*|}
        ipq_add "使用类型" "${G[ip_usage_cat]}${G[ip_usage]:+ (${G[ip_usage]})}" "$([ "${G[ip_usage_key]}" = idc ] && echo warn || echo good)"
    fi

    # 3) 原生 / 广播 IP(注册国 vs 部署国)
    if [ -n "${G[cymru_cc]:-}" ] && [ -n "${G[loc_cc]:-}" ]; then
        local reg geo
        reg=$(printf '%s' "${G[cymru_cc]}" | tr '[:lower:]' '[:upper:]')
        geo=$(printf '%s' "${G[loc_cc]}" | tr '[:lower:]' '[:upper:]')
        G[native_reg]=$reg
        G[native_geo]=$geo
        if [ "$reg" = "$geo" ]; then
            G[ip_native]=1
            ipq_add "IP 类型" "原生 ($geo)" good
        else
            G[ip_native]=0
            ipq_add "IP 类型" "广播/国际 (注册:$reg 部署:$geo)" bad
        fi
    else
        ipq_add "IP 类型" "无法判断" na
    fi

    # 3b) IP 地址黑名单数据库(v2.6:全量 ~420 域,分类统计 有效/正常/已标记/黑名单)
    if [ "$HQ_MODE" != tiny ] && ip_is_v4 "$ip"; then
        if dnsbl_check_ip "$ip" v4 dnsbl_; then
            ipq_add "IP 地址黑名单数据库" "有效 ${G[dnsbl_valid]} · 正常 ${G[dnsbl_clean]} · 已标记 ${G[dnsbl_marked]} · 黑名单 ${G[dnsbl_black]}" \
                "$([ "${G[dnsbl_black]}" -gt 0 ] 2>/dev/null && echo bad || echo good)"
        fi
    fi

    # 4) 完整模式追加:数据中心/滥用标记 + 25端口矩阵
    if [ "$HQ_MODE" = full ]; then
        if [ -n "$ipapi_json" ]; then
            local dc abuser
            dc=$(jfield "$ipapi_json" is_datacenter)
            abuser=$(jfield "$ipapi_json" is_abuser)
            G[abuser]=$abuser
            G[tor]=$(jfield "$ipapi_json" is_tor)
            ipq_add "数据中心 (ipapi.is)" "$([ "$dc" = true ] && echo '是' || echo '否')" na
            [ "$abuser" = true ] && ipq_add "滥用记录 (ipapi.is)" "有" bad
        fi

        # 25 端口矩阵(Gmail/Outlook/QQ/163 MX;参考 IPQuality Mail 模块)
        local dom mx
        for dom in gmail.com outlook.com qq.com 163.com; do
            mx=$(mx_of "$dom")
            [ -n "$mx" ] || continue
            if tcp_port_open "$mx" 25 6; then
                [ "$dom" = gmail.com ] && G[port25]=1
                ipq_add "25 端口 · $dom" "开放 ($mx)" good
            else
                [ "$dom" = gmail.com ] && G[port25]=0
                ipq_add "25 端口 · $dom" "封禁 ($mx)" warn
            fi
        done
    fi

    # 5) IPv6 风险明细(有 v6 时实测;报告页无数据则如实"待检测")
    if [ -n "${G[ip6]:-}" ]; then
        local v6=${G[ip6]} v6j v6t
        v6t=$(hq_curl "https://scamalytics.com/ip/${v6}" 10 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36" \
            | grep -oE 'Fraud Score: [0-9]+' | grep -oE '[0-9]+' | head -n1)
        is_num "$v6t" && G[ipq6_score]=$v6t
        v6j=$(hq_curl "https://api.ipapi.is/?q=${v6}" 10)
        if [ -n "$v6j" ]; then
            # ipapi.is 两种结构:完整版(risk_score/company.type/asn.org 对象)与
            # 紧凑版(company/asn 为字符串,顶层 country/city),逐级回退解析
            is_num "$(jfield "$v6j" risk_score)" && G[ipq6_score2]=$(jfield "$v6j" risk_score)
            v6t=$(jfield "$v6j" company.type)
            [ -n "$v6t" ] && G[ipq6_usage]=$v6t
            v6t=$(jfield "$v6j" company.name)
            [ -z "$v6t" ] && v6t=$(jfield "$v6j" company)
            [ -n "$v6t" ] && G[company6]=$v6t
            v6t=$(jfield "$v6j" asn.org)
            [ -z "$v6t" ] && v6t=$(jfield "$v6j" asn.descr)
            [ -z "$v6t" ] && v6t=$(jfield "$v6j" asn)
            [ -n "$v6t" ] && G[as6_org]=$v6t
            v6t=$(jfield "$v6j" asn.asn)
            [ -z "$v6t" ] && v6t=$(printf '%s' "${G[as6_org]:-}" | grep -oE 'AS[0-9]+' | grep -oE '[0-9]+' | head -n1)
            is_num "$v6t" && G[asn6]="AS$v6t ${G[as6_org]:-}"
            v6t="$(jfield "$v6j" country) $(jfield "$v6j" city)"
            [ -z "${v6t// /}" ] && v6t="$(jfield "$v6j" location.country) $(jfield "$v6j" location.city)"
            [ -n "${v6t// /}" ] && G[geo6]=$v6t
        fi
        # v6 使用类型 ipinfo 兜底(v2.7:ipapi 紧凑响应无 type 字段)
        if [ -z "${G[ipq6_usage]:-}" ]; then
            local v6i="" _it6="" _c6="" _a6=""
            v6i=$(hq_curl "https://ipinfo.io/widget/demo/${v6}" 8)
            if [ -n "$v6i" ]; then
                if command -v jq >/dev/null 2>&1; then
                    _it6=$(printf '%s' "$v6i" | jq -r '.data.asn.type // empty' 2>/dev/null)
                    [ -z "$_it6" ] && _it6=$(printf '%s' "$v6i" | jq -r '.data.company.type // empty' 2>/dev/null)
                else
                    _it6=$(printf '%s' "$v6i" | sed -n '/"asn"[[:space:]]*:/,/}/p' \
                        | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
                        | sed -E 's/.*:[[:space:]]*"//; s/"$//')
                    [ -z "$_it6" ] && _it6=$(printf '%s' "$v6i" | sed -n '/"company"[[:space:]]*:/,/}/p' \
                        | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
                        | sed -E 's/.*:[[:space:]]*"//; s/"$//')
                fi
                [ -n "$_it6" ] && G[ipq6_usage]=$_it6
                _c6=$(jfield "$v6i" data.company.name)
                [ -n "$_c6" ] && [ -z "${G[company6]:-}" ] && G[company6]=$_c6
                _a6=$(jfield "$v6i" data.asn.name)
                [ -n "$_a6" ] && [ -z "${G[as6_org]:-}" ] && G[as6_org]="$(jfield "$v6i" data.asn.asn) $_a6"
            fi
        fi
        # v6 使用类型归一(v2.6)
        local _u6cat
        _u6cat=$(usage_type_cat "${G[ipq6_usage]:-}")
        if [ -n "$_u6cat" ]; then
            G[ipq6_usage_cat]=${_u6cat%%|*}
            G[ipq6_usage_key]=${_u6cat##*|}
        fi
        # v6 原生 / 广播(v2.6:Cymru 注册国 vs ip-api v6 归属国)
        local _v6cc="" _v6reg="" _v6geo_j
        _v6geo_j=$(hq_curl "http://ip-api.com/json/${v6}?fields=countryCode" 6)
        [ -n "$_v6geo_j" ] && _v6cc=$(jfield "$_v6geo_j" countryCode)
        _v6cym=$(cymru_lookup "$v6")
        [ -n "$_v6cym" ] && _v6reg=$(printf '%s' "$_v6cym" | cut -d'|' -f2)
        _v6cc=$(printf '%s' "${_v6cc:-}" | tr '[:lower:]' '[:upper:]')
        _v6reg=$(printf '%s' "${_v6reg:-}" | tr '[:lower:]' '[:upper:]')
        if [ -n "$_v6cc" ] && [ -n "$_v6reg" ]; then
            G[native6_reg]=$_v6reg
            G[native6_geo]=$_v6cc
            if [ "$_v6reg" = "$_v6cc" ]; then
                G[ip_native6]=1
            else
                G[ip_native6]=0
            fi
        fi
        # v6 IP 地址黑名单数据库(v2.6:与 v4 同机制全量域;多数域不支持 v6,以有效应答数为准)
        [ "$HQ_MODE" != tiny ] && dnsbl_check_ip "$v6" v6 dnsbl6_
        local _nat6=""
        case "${G[ip_native6]:-}" in 1) _nat6=$(L native 原生) ;; 0) _nat6=$(L bcast 广播) ;; esac
        kv "IPv6 风险" "${G[ipq6_score]:-—}/${G[ipq6_score2]:-—}${G[dnsbl6_valid]:+ · 黑名单库 ${G[dnsbl6_black]:-0}/${G[dnsbl6_valid]}}${_nat6:+ · ${_nat6}}"
    fi

    local row name val lvl color
    for row in "${IPQ_ROWS[@]}"; do
        IFS='|' read -r name val lvl <<< "$row"
        color=$C_GREEN
        [ "$lvl" = warn ] && color=$C_YELLOW
        [ "$lvl" = bad ] && color=$C_RED
        [ "$lvl" = na ] && color=""
        printf '  %-24s %s%s%s\n' "$name" "$color" "$val" "$C_OFF"
    done
}

ipq_add() { IPQ_ROWS+=("$1|$2|$3"); }

mx_of() { # <domain> -> 首选 MX 主机
    if command -v dig >/dev/null 2>&1; then
        dig +short +time=3 +tries=1 MX "$1" 2>/dev/null | sort -n | head -n1 | awk '{print $NF}' | sed 's/\.$//'
    elif command -v nslookup >/dev/null 2>&1; then
        # busybox nslookup 输出 "Mail/Mail exchanger"(大小写不一),-i 兼容两者
        with_timeout 8 nslookup -type=mx "$1" 2>/dev/null | grep -im1 'mail exchanger' | awk '{print $NF}' | sed 's/\.$//'
    fi
}
# ============================================================
# M4b 邮件/邮局连通性(原型"邮件 / 邮局连通性"卡)
# 出站:7 协议端口 × 多目标 TCP 连通(/dev/tcp,零依赖,任一通即通);
# 入站需外部协助无法自测 → 如实"待检测"(na)
# ============================================================
MAIL_PORT_TARGETS=(
    "SMTP|25|aspmx.l.google.com mx.163.com"
    "SMTP (SSL)|465|smtp.gmail.com smtp.qq.com"
    "SMTP (TLS)|587|smtp.gmail.com smtp.office365.com"
    "IMAP|143|imap.gmail.com imap.qq.com"
    "IMAP (SSL)|993|imap.gmail.com imap.qq.com"
    "POP3|110|pop.gmail.com pop.qq.com"
    "POP3 (SSL)|995|pop.gmail.com pop.qq.com"
)

mod_mail() {
    sec "$(L mail '邮件端口连通性') Mail Ports"
    local i=0 spec proto port hosts h
    local -a jobs=()
    for spec in "${MAIL_PORT_TARGETS[@]}"; do
        IFS='|' read -r proto port hosts <<< "$spec"
        (
            _st="blocked"
            for h in $hosts; do
                if tcp_port_open "$h" "$port" 5; then _st="ok"; break; fi
            done
            printf '%s' "$_st"
        ) >"$HQ_TMP/mail.$i" &
        jobs+=($!)
        hq_throttle
        i=$((i+1))
    done
    wait "${jobs[@]}" 2>/dev/null

    # 入站:check-host.net 外部节点对本机逐端口 TCP 探测(真实入站视角;
    # "无监听"=端口路径可达但本机无服务监听;"阻断"=超时/过滤)
    local in_txt="" rid
    if [ -n "${G[ip4]:-}" ]; then
        i=0
        for spec in "${MAIL_PORT_TARGETS[@]}"; do
            IFS='|' read -r proto port hosts <<< "$spec"
            (
                _rid=$(curl -s --connect-timeout 4 --max-time 8 -H "Accept: application/json" \
                    "https://check-host.net/check-tcp?host=${G[ip4]}:${port}&max_nodes=1" 2>/dev/null \
                    | grep -oE '"request_id":"[^"]+"' | head -n1 | cut -d'"' -f4)
                printf '%s' "${_rid:-}"
            ) >"$HQ_TMP/mailin.$i" &
            jobs+=($!)
            hq_throttle
            i=$((i+1))
        done
        wait "${jobs[@]}" 2>/dev/null
        sleep 7
        i=0
        for spec in "${MAIL_PORT_TARGETS[@]}"; do
            IFS='|' read -r proto port hosts <<< "$spec"
            (
                _rid=$(cat "$HQ_TMP/mailin.$i" 2>/dev/null)
                _st="na"
                if [ -n "$_rid" ]; then
                    _j=$(curl -s --connect-timeout 4 --max-time 8 -H "Accept: application/json" \
                        "https://check-host.net/check-result/${_rid}" 2>/dev/null)
                    if printf '%s' "$_j" | grep -q '"time":'; then
                        _st="ok"
                    elif printf '%s' "$_j" | grep -qi 'refused'; then
                        _st="refused"
                    elif printf '%s' "$_j" | grep -q '"error"'; then
                        _st="blocked"
                    elif printf '%s' "$_j" | grep -q 'null'; then
                        sleep 3
                        _j=$(curl -s --connect-timeout 4 --max-time 8 -H "Accept: application/json" \
                            "https://check-host.net/check-result/${_rid}" 2>/dev/null)
                        printf '%s' "$_j" | grep -q '"time":' && _st="ok"
                        printf '%s' "$_j" | grep -qi 'refused' && _st="refused"
                        { printf '%s' "$_j" | grep -q '"error"'; } && _st="blocked"
                    fi
                fi
                printf '%s' "$_st"
            ) >"$HQ_TMP/mailinr.$i" &
            jobs+=($!)
            hq_throttle
            i=$((i+1))
        done
        wait "${jobs[@]}" 2>/dev/null
    fi

    local ok_n=0 bl_n=0 in_ok_n=0 in_bl_n=0 st in_st overall rowstr in_disp
    local -a rows=()
    i=0
    for spec in "${MAIL_PORT_TARGETS[@]}"; do
        IFS='|' read -r proto port hosts <<< "$spec"
        st=$(cat "$HQ_TMP/mail.$i" 2>/dev/null); rm -f "$HQ_TMP/mail.$i"
        [ "$st" = ok ] && ok_n=$((ok_n+1)) || { st=${st:-blocked}; bl_n=$((bl_n+1)); }
        in_st=$(cat "$HQ_TMP/mailinr.$i" 2>/dev/null); rm -f "$HQ_TMP/mailin.$i" "$HQ_TMP/mailinr.$i" 2>/dev/null
        in_st=${in_st:-na}
        [ "$in_st" = ok ] && in_ok_n=$((in_ok_n+1))
        [ "$in_st" = blocked ] && in_bl_n=$((in_bl_n+1))
        rows+=("$proto|$port|$st|$in_st")
        case "$in_st" in
            ok)      in_disp="${C_GREEN}$(L mail_in_ok '入站 ✓ 通')${C_OFF}" ;;
            refused) in_disp="${C_DIM}$(L mail_in_rf '入站 无监听')${C_OFF}" ;;
            blocked) in_disp="${C_RED}$(L mail_in_bl '入站 ✗ 阻断')${C_OFF}" ;;
            *)       in_disp="${C_DIM}$(L mail_in_na '入站 待检测')${C_OFF}" ;;
        esac
        printf '  %-12s %-5s %s  %s\n' "$proto" "$port" \
            "$([ "$st" = ok ] && printf '%s%s%s' "$C_GREEN" "$(L mail_ok '出站 ✓ 通')" "$C_OFF" || printf '%s%s%s' "$C_RED" "$(L mail_bl '出站 ✗ 阻断')" "$C_OFF")" \
            "$in_disp"
        i=$((i+1))
    done
    overall=blocked
    local tot=${#MAIL_PORT_TARGETS[@]}
    if [ "$ok_n" -gt 0 ] && [ "$bl_n" -eq 0 ] && [ "$in_bl_n" -eq 0 ]; then overall=ok; fi
    if [ "$bl_n" -gt 0 ] || [ "$in_bl_n" -gt 0 ]; then
        if [ "$(( ok_n + in_ok_n ))" -gt 0 ]; then overall=partial; else overall=blocked; fi
    fi
    for rowstr in "${rows[@]}"; do
        MAIL_ROWS+=("${rowstr}|$overall")
    done
    G[mail_summary]=$(awk -v o="$ok_n" -v io="$in_ok_n" -v t="$tot" \
        'BEGIN{printf "出站 %d/%d 通 · 入站 %d/%d 通", o, t, io, t}')
    kv "$(L mail_sum '端口连通')" "$(L mail_note2 '出站为本机直连目标 MX;入站为 check-host.net 外部节点探测本机(无监听=路径可达但无服务)')"

    # 原型邮局 12 服务商宫格:逐服务商解析 MX 并测 25 出站(任一 MX 通即 good)
    MAILPROV_ROWS=()
    local pd pm px pst okp=0
    local -a pj=()
    local -a MAIL_PROVIDER_LIST=(Gmail Outlook Yahoo "Apple Mail" "QQ 邮箱" Mail.ru AOL GMX Mail.com "网易 163" 搜狐 新浪)
    local -a MAIL_PROVIDER_DOMS=(gmail.com outlook.com yahoo.com icloud.com qq.com mail.ru aol.com gmx.com mail.com 163.com sohu.com sina.com)
    for px in "${!MAIL_PROVIDER_DOMS[@]}"; do
        (
            _st=pending
            _mxs=$(mx_of "${MAIL_PROVIDER_DOMS[$px]}")   # 只解析一次 MX(原实现调用两次,fork 翻倍)
            for _mx in $_mxs; do
                if tcp_port_open "$_mx" 25 5; then _st=ok; break; fi
            done
            [ "$_st" = ok ] || { [ -n "$_mxs" ] && _st=blocked; }
            printf '%s|%s' "${MAIL_PROVIDER_LIST[$px]}" "$_st"
        ) >"$HQ_TMP/mailprov.$px" &
        pj+=($!)
        hq_throttle
    done
    wait "${pj[@]}" 2>/dev/null
    for px in "${!MAIL_PROVIDER_DOMS[@]}"; do
        [ -s "$HQ_TMP/mailprov.$px" ] && { IFS='|' read -r pd pst <"$HQ_TMP/mailprov.$px"; rm -f "$HQ_TMP/mailprov.$px"; MAILPROV_ROWS+=("$pd|$pst"); }
    done
    G[mail_port25]=$(awk -v o="$ok_n" 'BEGIN{print (o>0)?"ok":"blocked"}')
    return 0
}

# ============================================================
# M5 流媒体/AI 解锁(纯 curl 探测,RegionRestrictionCheck 思路)
# ============================================================
M_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
m_curl() { curl -fsSL --connect-timeout 4 --max-time 10 -A "$M_UA" "$@" 2>/dev/null; }
m_code() { curl -sL -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10 -A "$M_UA" "$@" 2>/dev/null; }

# _hq6_probe <host> -> yes(v6 可达)/no(v6 路由不通,或 4xx 拒绝=可达但未解锁)
#                 /na(服务本身无 AAAA,v6 不适用)/fail(超时等探测失败)
_hq6_probe() {
    local h=$1 out rc code
    out=$(curl -6 -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 6 -A "$M_UA" "https://${h}/" 2>/dev/null)
    rc=$?
    code=$(printf '%s' "$out" | tr -dc '0-9')
    if [ "$rc" = 0 ] && [ "${code:-0}" -ge 200 ] 2>/dev/null && [ "${code:-0}" -lt 400 ] 2>/dev/null; then
        printf 'yes'; return
    fi
    if [ "$rc" = 0 ] && [ "${code:-0}" -ge 400 ] 2>/dev/null && [ "${code:-0}" -lt 500 ] 2>/dev/null; then
        printf 'no'; return   # v6 链路通但服务端拒绝(如 Netflix 403):未解锁而非探测失败
    fi
    case "$rc" in
        6) printf 'na' ;;     # 无法解析:服务无 AAAA(v4 检查可佐证 DNS 正常),v6 不适用
        7) printf 'no' ;;     # 无法连接:v6 路由不通/被过滤
        *) printf 'fail' ;;
    esac
}

# ---- 各服务检测:输出 "状态|地区" (状态: yes/no/orig/fail) ----
chk_netflix() {
    local c1 c2 rg
    c1=$(m_code "https://www.netflix.com/title/81280792")
    c2=$(m_code "https://www.netflix.com/title/70143836")
    if [ "$c1" = 200 ] && [ "$c2" = 200 ]; then
        local _nfp="${HQ_TMP:-/tmp}/nfdbg.$$.html"
        curl -s --connect-timeout 5 --max-time 14 -A "$M_UA" "https://www.netflix.com/" -o "$_nfp" 2>/dev/null
        rg=$(grep -oE '"(currentCountry|country)":"[A-Z]{2}"' "$_nfp" 2>/dev/null | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
        rm -f "$_nfp" 2>/dev/null
        printf 'yes|%s' "${rg:-支持完整内容}"
    elif [ "$c1" = 200 ]; then
        printf 'orig|'
    elif [ "$c1" = 404 ] || [ "$c2" = 404 ] || [ "$c1" = 403 ]; then
        printf 'no|'
    else
        printf 'fail|'
    fi
}

chk_disney() {
    local token='ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84'
    local d1 assertion d2 region=""
    d1=$(curl -fsSL --connect-timeout 4 --max-time 10 -X POST \
        -H "authorization: Bearer $token" -H 'content-type: application/json; charset=UTF-8' \
        -A "$M_UA" \
        --data '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' \
        "https://disney.api.edge.bamgrid.com/devices" 2>/dev/null)
    [ -z "$d1" ] && { printf 'fail|'; return; }
    assertion=$(printf '%s' "$d1" | grep -oE '"assertion":"[^"]+"' | cut -d'"' -f4)
    [ -z "$assertion" ] && { printf 'no|'; return; }
    d2=$(curl -fsSL --connect-timeout 4 --max-time 10 -X POST \
        -H "authorization: Bearer $token" \
        -A "$M_UA" \
        --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
        --data-urlencode 'latitude=0' --data-urlencode 'longitude=0' \
        --data-urlencode 'platform=browser' \
        --data-urlencode "subject_token=${assertion}" \
        --data-urlencode 'subject_token_type=urn:bamtech:params:oauth:token-type:device' \
        "https://disney.api.edge.bamgrid.com/token" 2>/dev/null)
    if printf '%s' "$d2" | grep -qE 'forbidden-location|403 ERROR'; then
        printf 'no|'
    elif printf '%s' "$d2" | grep -q 'refresh_token'; then
        # 区域探测: graphql 简化(可容错失败)
        local refresh graphql
        refresh=$(printf '%s' "$d2" | grep -oE '"refresh_token":"[^"]+"' | cut -d'"' -f4)
        if [ -n "$refresh" ]; then
            graphql=$(curl -fsSL --connect-timeout 4 --max-time 10 -X POST \
                -H 'content-type: application/json' -H "authorization: Bearer $token" -A "$M_UA" \
                --data '{"query":"mutation refreshToken($refreshToken: String!){refreshToken(refreshToken: $refreshToken){activeSession{sessionId}}}"}' \
                "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" 2>/dev/null)
        fi
        region=$(printf '%s' "${graphql:-}" | grep -oE '"countryCode":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
        printf 'yes|%s' "${region:-}"
    else
        printf 'fail|'
    fi
}

chk_ytpremium() {
    local r
    r=$(m_curl -b 'CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI' \
        -H 'Accept-Language: en' "https://www.youtube.com/premium")
    if printf '%s' "$r" | grep -q 'Premium is not available in your country'; then
        printf 'no|'
    elif printf '%s' "$r" | grep -q 'www.google.cn'; then
        printf 'no|CN'
    elif printf '%s' "$r" | grep -q 'ad-free'; then
        local cc
        cc=$(printf '%s' "$r" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
        printf 'yes|%s' "${cc:-}"
    else
        printf 'fail|'
    fi
}

chk_tiktok() {
    local r region
    r=$(m_curl "https://www.tiktok.com/")
    [ -z "$r" ] && { printf 'fail|'; return; }
    region=$(printf '%s' "$r" | grep -oE '"region":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
    if [ -n "$region" ]; then
        printf 'yes|%s' "$region"
    elif printf '%s' "$r" | grep -qiE 'not available|page not found'; then
        printf 'no|'
    else
        printf 'yes|未知区域'
    fi
}

chk_chatgpt() {
    local r1 r2
    r1=$(m_curl "https://api.openai.com/compliance/cookie_requirements")
    r2=$(m_curl "https://ios.chat.openai.com/public-api/mobile/server_status_ios")
    if printf '%s' "$r1" | grep -q 'unsupported_country_region_territory'; then
        printf 'no|'
    elif [ -z "$r1$r2" ]; then
        printf 'fail|'
    else
        local cc
        cc=$(printf '%s' "$r2" | grep -oE '"country":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
        printf 'yes|%s' "${cc:-}"
    fi
}

chk_claude() {
    local final
    final=$(curl -s -o /dev/null -w '%{url_effective}' -L --connect-timeout 4 --max-time 12 -A "$M_UA" "https://claude.ai/login" 2>/dev/null)
    if printf '%s' "$final" | grep -qiE 'app-unavailable-in-region|unsupported'; then
        printf 'no|'
    elif printf '%s' "$final" | grep -q 'claude.ai'; then
        printf 'yes|'
    else
        printf 'fail|'
    fi
}

chk_gemini() {
    local r cc
    r=$(m_curl -L "https://gemini.google.com/")
    cc=$(printf '%s' "$r" | grep -oE ',2,1,200,"[A-Z]{2}"' | grep -oE '"[A-Z]{2}"' | tr -d '"')
    if printf '%s' "$r" | grep -q '45631641,null,true'; then
        printf 'no|'
    elif printf '%s' "$r" | grep -qiE 'support.google.com|not available in your country'; then
        printf 'no|'
    elif [ -n "$r" ] && printf '%s' "$r" | grep -q '<title>'; then
        printf 'yes|%s' "${cc:-}"
    else
        printf 'fail|'
    fi
}

chk_spotify() {
    local r
    r=$(curl -fsSL --connect-timeout 4 --max-time 10 -A "$M_UA" \
        --data 'browser_platform=Linux+x86_64&os_name=Linux&cf_cache_status=HIT&visit_id=57ac4ee4-46fb-48aa-b072-32be649a148e_1730954877678&create_source=www_signup&referrer=&key=browser_frontend_mac&p13n_source=signup_v4&campaign=www_signup&surface=signup_page_v4&page_layout=signup_v4&create_point=https%3A%2F%2Fopen.spotify.com%2F&parent_platform=www&sp_t=&sp_landing=https%3A%2F%2Fopen.spotify.com%2Fsignup&intent=signup&display_locale=zh-CN&validate=1&email=' \
        "https://spclient.wg.spotify.com/signup/public/v1/account" 2>/dev/null)
    if [ -z "$r" ]; then
        printf 'fail|'
    elif printf '%s' "$r" | grep -q '"is_country_launched":true'; then
        local cc
        cc=$(printf '%s' "$r" | grep -oE '"country":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
        printf 'yes|%s' "${cc:-}"
    elif printf '%s' "$r" | grep -q '"is_country_launched":false'; then
        printf 'no|'
    else
        printf 'fail|'
    fi
}

# ---- 完整模式扩展项 ----
chk_prime() {
    local r
    r=$(m_curl "https://www.primevideo.com")
    if printf '%s' "$r" | grep -q 'isServiceRestricted'; then
        printf 'no|'
    else
        local cc
        cc=$(printf '%s' "$r" | grep -oE '"currentTerritory":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
        [ -n "$cc" ] && printf 'yes|%s' "$cc" || printf 'fail|'
    fi
}

bilibili_region() { # <期望region_id> : 7=HK 8=TW
    local want=$1
    local r
    r=$(m_curl "https://api.bilibili.com/pgc/player/web/playurl?avid=50762638&cid=100279316&qn=64&type=&otype=json&ep_id=324452&fnver=0&fnval=16")
    [ -z "$r" ] && { printf 'fail|'; return; }
    local code rid
    code=$(printf '%s' "$r" | grep -oE '"code":-?[0-9]+' | head -n1 | grep -oE '[-0-9]+$')
    rid=$(printf '%s' "$r" | grep -oE '"region_id":[0-9]+' | head -n1 | grep -oE '[0-9]+$')
    if [ "$code" = 0 ] && [ "$rid" = "$want" ]; then
        printf 'yes|'
    elif [ "$code" = "-10403" ]; then
        printf 'no|'
    else
        printf 'no|'
    fi
}

chk_bili_hkmt() { bilibili_region 7; }
chk_bili_tw()   { bilibili_region 8; }

chk_abema() {
    local r
    r=$(m_curl "https://api.abema.io/v1/ip/check?device=android")
    local cc
    cc=$(printf '%s' "$r" | grep -oE '"isoCountryCode":"[A-Z]{2}"' | grep -oE '[A-Z]{2}"$' | tr -d '"')
    if [ "$cc" = JP ]; then printf 'yes|JP'
    elif [ -n "$cc" ]; then printf 'no|'
    else printf 'fail|'; fi
}

chk_dazn() {
    local r
    r=$(m_curl "https://startup.core.indazn.com/metadata_ops/backend--ops/v1/availability?includeMetadata=false" \
        -H 'x-device-info: {"os":"android","platform":"mobile"}')
    if [ -z "$r" ]; then printf 'fail|'; return; fi
    local allowed cc
    allowed=$(printf '%s' "$r" | grep -oE '"isAllowed":(true|false)' | grep -oE '(true|false)$')
    cc=$(printf '%s' "$r" | grep -oE '"GeolocatedCountry":"[A-Z]{2}"' | grep -oE '[A-Z]{2}"$' | tr -d '"')
    if [ "$allowed" = true ]; then printf 'yes|%s' "${cc:-}"
    else printf 'no|'; fi
}

chk_bbc() {
    local r
    r=$(m_curl -o /dev/null -w '%{http_code}' "https://www.bbc.co.uk/mediaselector/6/version/2.0/mediaset/pc/vpid/bbc_one_london?format=json")
    case "$r" in
        200) printf 'yes|UK' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_hbomax() {
    local hdr
    hdr=$(curl -sI -o /dev/null -w '%{redirect_url}' --connect-timeout 4 --max-time 10 -A "$M_UA" "https://www.max.com/" 2>/dev/null)
    local cc
    cc=$(printf '%s' "$hdr" | grep -oE 'countryCode=[A-Z]{2}' | grep -oE '[A-Z]{2}$')
    if [ -n "$cc" ]; then printf 'yes|%s' "$cc"
    elif printf '%s' "$hdr" | grep -qi 'unavailable'; then printf 'no|'
    else printf 'fail|'; fi
}

# ---- 出口归属类:YouTube CDN 机位 / Steam 货币区(参考 RegionRestrictionCheck WebTest) ----
chk_ytcdn() {
    local r node
    r=$(m_curl "https://redirector.googlevideo.com/report_mapping")
    node=$(printf '%s' "$r" | grep -oE '=> [a-z]{3}[0-9a-z]*' | head -n1 | grep -oE '[a-z0-9]+$')
    if [ -n "$node" ]; then
        printf 'yes|%s' "$(printf '%s' "$node" | tr 'a-z' 'A-Z' | cut -c1-3)·${node}"
    elif [ -z "$r" ]; then
        printf 'fail|'
    else
        printf 'no|'
    fi
}

chk_steam() {
    local r cur
    r=$(m_curl "https://store.steampowered.com/steamaccount/addfunds")
    cur=$(printf '%s' "$r" | grep -oE 'data-currency="[A-Z]{3}"' | head -n1 | grep -oE '[A-Z]{3}')
    if [ -n "$cur" ]; then
        printf 'yes|%s' "$cur"
    elif [ -z "$r" ]; then
        printf 'fail|'
    else
        printf 'no|'
    fi
}

# ---- 原型三组扩展:基础 YouTube / Hulu / Reddit / X / Instagram / Perplexity / Copilot / Grok ----
chk_youtube() {
    local r cc
    r=$(m_curl -b 'CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI' -H 'Accept-Language: en' "https://www.youtube.com/")
    if printf '%s' "$r" | grep -q '<title>YouTube</title>\|<title>油管'; then
        cc=$(printf '%s' "$r" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
        printf 'yes|%s' "${cc:-}"
    elif printf '%s' "$r" | grep -q 'www.google.cn'; then
        printf 'no|CN'
    elif [ -n "$r" ]; then
        printf 'yes|'
    else
        printf 'fail|'
    fi
}

chk_hulu() {
    local c
    c=$(m_code "https://www.hulu.com/welcome")
    case "$c" in
        200|302) printf 'yes|US' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_reddit() {
    local c
    c=$(m_code -L "https://www.reddit.com/")
    case "$c" in
        200) printf 'yes|' ;;
        403|404|451) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_x() {
    local c
    c=$(m_code -L "https://x.com/robots.txt")
    case "$c" in
        200) printf 'yes|' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_instagram() {
    local c
    c=$(m_code -L "https://www.instagram.com/")
    case "$c" in
        200) printf 'yes|' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_perplexity() {
    local c
    c=$(m_code -L "https://www.perplexity.ai/")
    case "$c" in
        200) printf 'yes|' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_copilot() {
    local c
    c=$(m_code -L "https://copilot.microsoft.com/")
    case "$c" in
        200) printf 'yes|' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

chk_grok() {
    local c
    c=$(m_code -L "https://grok.com/")
    case "$c" in
        200) printf 'yes|' ;;
        403|404) printf 'no|' ;;
        *) printf 'fail|' ;;
    esac
}

mod_media() {
    sec "$(L media '流媒体/社交/AI 解锁') Streaming · Social · AI"
    # 格式: 名称|检测函数|组别(md=流媒体 sq=社交 ai=AI)
    local -a checks=(
        "Netflix|chk_netflix|md|www.netflix.com"
        "YouTube|chk_youtube|md|www.youtube.com"
        "YouTube Premium|chk_ytpremium|md|www.youtube.com"
        "Disney+|chk_disney|md|www.disneyplus.com"
        "Prime Video|chk_prime|md|www.primevideo.com"
        "Spotify|chk_spotify|md|open.spotify.com"
        "TikTok|chk_tiktok|sq|www.tiktok.com"
        "Reddit|chk_reddit|sq|www.reddit.com"
        "X (Twitter)|chk_x|sq|x.com"
        "Instagram|chk_instagram|sq|www.instagram.com"
        "ChatGPT/OpenAI|chk_chatgpt|ai|chatgpt.com"
        "Claude|chk_claude|ai|claude.ai"
        "Google Gemini|chk_gemini|ai|gemini.google.com"
        "Perplexity|chk_perplexity|ai|www.perplexity.ai"
        "Microsoft Copilot|chk_copilot|ai|copilot.microsoft.com"
        "Grok|chk_grok|ai|grok.com"
    )
    if [ "$HQ_MODE" = full ]; then
        checks+=(
            "Hulu|chk_hulu|md|www.hulu.com"
            "YouTube CDN|chk_ytcdn|md|www.youtube.com"
            "Steam 货币|chk_steam|sq|store.steampowered.com"
        )
    fi

    local i=0 item name fn grp res
    local -a pids=()
    # IPv6 连通性预检(有 v6 时):每服务域名 curl -6 探测,产出 st6
    local -A ST6MAP=()
    if [ -n "${G[ip6]:-}" ] && [[ $OPT_IPV == *6* ]]; then
        local _p6i=0 _p6n _p6h _p6f
        local -a _p6pids=()
        for item in "${checks[@]}"; do
            IFS='|' read -r _p6n _ _ _p6h <<< "$item"
            [ -n "${_p6h:-}" ] || continue
            (
                _c=$(_hq6_probe "$_p6h")
                printf '%s' "$_c"
            ) >"$HQ_TMP/mst6.$_p6i" &
            _p6pids+=($!)
            hq_throttle
            _p6i=$((_p6i+1))
        done
        wait "${_p6pids[@]}" 2>/dev/null
        local _p6k=0 _p6v
        for item in "${checks[@]}"; do
            IFS='|' read -r _p6n _ _ _p6h <<< "$item"
            _p6v=""
            [ -s "$HQ_TMP/mst6.$_p6k" ] && _p6v=$(cat "$HQ_TMP/mst6.$_p6k" 2>/dev/null)
            rm -f "$HQ_TMP/mst6.$_p6k" 2>/dev/null
            ST6MAP[$_p6n]="${_p6v:-}"
            _p6k=$((_p6k+1))
        done
    fi
    for item in "${checks[@]}"; do
        IFS='|' read -r name fn grp mhost <<< "$item"
        (
            res=$(eval "$fn")
            printf '%s|%s|%s|%s' "$name" "$res" "$grp" "${ST6MAP[$name]:-}"
        ) >"$HQ_TMP/media.$i" &
        pids+=($!)
        hq_throttle
        i=$((i+1))
    done
    wait "${pids[@]}" 2>/dev/null

    local yes_n=0
    local idx=0 row svc status region color txt f
    while [ "$idx" -lt "${#checks[@]}" ]; do
        f="$HQ_TMP/media.$idx"
        if [ -s "$f" ]; then
            row=$(cat "$f")
            IFS='|' read -r svc status region grp st6 <<< "$row"
        else
            IFS='|' read -r svc _fn grp mhost <<< "${checks[$idx]}"
            status=fail; region=""; st6=""
        fi
        case "$status" in
            yes)  color=$C_GREEN; txt=$(L yes '支持');  yes_n=$((yes_n+1)) ;;
            no)   color=$C_RED;   txt=$(L no '不支持') ;;
            orig) color=$C_YELLOW; txt=$(L orig '仅自制') ;;
            *)    color=$C_DIM;   txt=$(L fail '失败') ;;
        esac
        MEDIA_ROWS+=("$svc|$status|${region:-}|$grp|${st6:-}")
        printf '  %-18s %s%s%s %s\n' "$svc" "$color" "$txt" "$C_OFF" "${region:+${C_DIM}($region)${C_OFF}}"
        rm -f "$f"
        idx=$((idx+1))
    done
    G[media_yes_n]=$yes_n
    G[media_total_n]=${#checks[@]}
    kv "解锁统计" "$yes_n/${#checks[@]} 项支持"
}
# ============================================================
# M6 回程路由(仅完整模式):nexttrace/traceroute + Cymru 批量ASN + 线路分类
# ============================================================
ROUTE_TARGETS_DEF=(
    "中国电信|202.96.209.133"
    "中国联通|61.135.169.121"
    "中国移动|120.196.165.24"
    "中国教育网|202.112.0.35"
    "Cloudflare|1.1.1.1"
    "Google|8.8.8.8"
)

dl_nexttrace() {
    local bin="$HQ_BIN/nexttrace"
    [ -s "$bin" ] && { printf '%s' "$bin"; return 0; }
    local arch=""
    case "${HQ_ARCH:-}" in
        x86_64) arch="amd64" ;;
        arm64)  arch="arm64" ;;
        *) return 1 ;;
    esac
    local url
    url=$(gh_asset_url "nxtrace/NTrace-core" "nexttrace_linux_${arch}\$") || return 1
    hq_download "$url" "$bin" || return 1
    chmod +x "$bin" 2>/dev/null
    printf '%s' "$bin"
}

trace_one() { # <目标名> <ip> <输出文件> <bin> [fam:4|6]
    local name=$1 ip=$2 out=$3 bin=$4 fam="${5:-4}"
    local f6="" ; [ "$fam" = 6 ] && f6="-6"
    local o hops=""
    if [ -n "$bin" ]; then
        o=$(with_timeout 45 "$bin" -n -q 1 -m 30 -T -p 443 $f6 "$ip" 2>/dev/null)
        # nexttrace 管道输出仍带 ANSI 颜色码:先剥离再解析
        # 行首为跳号,取行内首个 IP;过滤内网跳(ASN 恒为 NA,徒增查询)
        if [ "$fam" = 6 ]; then
            hops=$(printf '%s' "$o" | sed 's/\x1b\[[0-9;]*m//g' \
                | awk '/^[[:space:]]*[0-9]+[[:space:]]/ {
                    if (match($0, /([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}/)) {
                        ip = substr($0, RSTART, RLENGTH)
                        if (ip !~ /^[Ff][Ee]80:/) print ip
                    }
                }')
        else
            hops=$(printf '%s' "$o" | sed 's/\x1b\[[0-9;]*m//g' \
                | awk '/^[[:space:]]*[0-9]+[[:space:]]/ {
                    if (match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
                        ip = substr($0, RSTART, RLENGTH)
                        if (ip !~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.)/) print ip
                    }
                }')
        fi
    elif command -v traceroute >/dev/null 2>&1; then
        o=$(with_timeout 45 traceroute -n -T -p 443 -q 1 -w 2 -m 30 $f6 "$ip" 2>/dev/null)
        if [ "$fam" = 6 ]; then
            hops=$(printf '%s' "$o" | awk 'NR>1 && $2 ~ /^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$/ && $2 !~ /^[Ff][Ee]80:/ {print $2}')
        else
            hops=$(printf '%s' "$o" | awk 'NR>1 && $2 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print $2}')
        fi
    else
        return 1
    fi
    [ -z "$hops" ] && return 1
    printf '%s' "$hops" >"$out"
}

# Cymru 批量 ASN 解析: stdin=IP列表, stdout="ip|asn|cc|asname" 每行
cymru_bulk() {
    local ips=$1 out ip rev
    out=$({
        printf 'begin\nverbose\n'
        printf '%s\n' "$ips"
        printf 'end\n'
    } | with_timeout 40 bash -c '
        exec 3<>/dev/tcp/whois.cymru.com/43 || exit 1
        cat >&3
        cat <&3
    ' 2>/dev/null | awk -F'|' 'NR>1 && NF>=7 {gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$7); print $2 "|" $1 "|" $4 "|" $7}')
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    # 43 端口失败/超时降级:DNS TXT 逐 IP 并行(origin.asn.cymru.com,无 asname)
    local -a jobs=()
    for ip in $ips; do
        rev=$(printf '%s' "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
        (
            _t=$(dig +short +time=3 +tries=1 TXT "${rev}.origin.asn.cymru.com" @8.8.8.8 2>/dev/null | head -n1 | tr -d '"')
            _a=$(printf '%s' "$_t" | awk -F' *[|] *' '{gsub(/^ +| +$/,"",$1); print $1}')
            _c=$(printf '%s' "$_t" | awk -F' *[|] *' '{gsub(/^ +| +$/,"",$3); print $3}')
            printf '%s|%s|%s|\n' "$ip" "$_a" "$_c"
        ) &
        jobs+=($!)
        if [ ${#jobs[@]} -ge $(( HQ_NET * 2 > 24 ? 24 : HQ_NET * 2 )) ]; then wait "${jobs[@]}" 2>/dev/null; jobs=(); fi
    done
    [ ${#jobs[@]} -gt 0 ] && wait "${jobs[@]}" 2>/dev/null
    return 0
}

# Tier1 骨干运营商表(参考 NetQuality Tier1 连通性清单):AS号 -> 名称
declare -A TIER1_ASNS=(
    [174]="Cogent" [3356]="Lumen" [1299]="Arelion" [2914]="NTT" [6939]="HE"
    [6461]="Zayo" [6453]="Tata" [6762]="Sparkle" [3491]="PCCW" [3320]="DT"
    [5511]="Orange" [701]="Verizon" [1239]="Sprint" [7018]="AT&T" [6830]="Liberty"
)

# 根据跳数 ASN/前缀归类大陆方向线路
classify_route() { # <ASN列表(空格)> <IP列表(空格)> -> 标签
    local -a asns; read -ra asns <<< "$1"
    local ips=$2
    local has_4809=0 has_5943=0
    local a found="" tok
    _cr_add() { case " $found " in *" $1 "*) ;; *) found="$found $1" ;; esac; }
    for a in "${asns[@]}"; do
        case $a in
            4809) has_4809=1 ;;
            4134|4811|4812|4813) _cr_add 163 ;;   # ChinaNet 骨干(含沪/粤等区域 AS)
            4837) _cr_add 4837 ;;
            9929) _cr_add 9929 ;;
            10099) _cr_add CUG ;;
            58807) _cr_add CMIN2 ;;
            58453) _cr_add CMI ;;
            9808) _cr_add CMNET ;;
            23764) _cr_add 电信国际 ;;
            4538) _cr_add CERNET ;;
            7497) _cr_add 科技网 ;;
        esac
    done
    printf '%s' "$ips" | grep -q '59\.43\.' && has_5943=1
    if [ "$has_4809" = 1 ]; then
        if [ "$has_5943" = 1 ]; then found="CN2 GIA $found"; else found="CN2 GT $found"; fi
    fi
    found=$(printf '%s' "$found" | xargs)
    [ -n "$found" ] && printf '%s' "$found" || printf '%s' "普通线路"
}

mod_route() {
    sec "$(L route '三网线路') Route"
    if [ "$HQ_MODE" != full ] && [ "$OPT_LOW_TRAFFIC" != 1 ]; then
        note "精简模式:仅测三网方向线路(完整模式含国际目标与逐跳明细)"
    fi
    local ntbin=""
    ntbin=$(dl_nexttrace) || { ntbin=""; }
    if [ -z "$ntbin" ] && ! command -v traceroute >/dev/null 2>&1; then
        warn "nexttrace/traceroute 均不可用,跳过线路检测"
        return 1
    fi

    local -a jobs=() tfiles=()
    local all_route_asns=""
    local t name ip i=0
    for t in "${ROUTE_TARGETS_DEF[@]}"; do
        IFS='|' read -r name ip <<< "$t"
        # 精简模式只测三网目标
        if [ "$HQ_MODE" != full ]; then
            case "$name" in 中国*) ;; *) continue ;; esac
        fi
        trace_one "$name" "$ip" "$HQ_TMP/route.$i" "$ntbin" & jobs+=($!)
        hq_throttle
        tfiles+=("$name:$ip:$HQ_TMP/route.$i")
        i=$((i+1))
    done
    [ ${#jobs[@]} -gt 0 ] && wait "${jobs[@]}" 2>/dev/null

    # 汇总全部跳数 IP 一次性批量解析
    local all_ips="" f spec hops
    for spec in "${tfiles[@]}"; do
        f=${spec##*:}
        [ -s "$f" ] && all_ips="$all_ips
$(cat "$f")"
    done
    all_ips=$(printf '%s' "$all_ips" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
    [ -z "$all_ips" ] && { warn "未获取到任何路由跳数"; return 1; }

    declare -A IP2ASN=() ASN2NAME=()
    local rip rasn _rcc rname
    while IFS='|' read -r rip rasn _rcc rname; do
        [ -n "$rip" ] || continue
        IP2ASN[$rip]=${rasn:-}
        [ -n "$rasn" ] && ASN2NAME[$rasn]=${rname:-}
    done < <(cymru_bulk "$all_ips")

    # 逐目标归类 + 生成明细
    for spec in "${tfiles[@]}"; do
        name=${spec%%:*}
        local rest=${spec#*:}
        ip=${rest%%:*}
        f=${rest##*:}
        [ -s "$f" ] || { ROUTE_TARGETS+=("$name|$ip|不可达|"); continue; }
        local asn_set="" hop_detail="" hop_ip hop_asn hop_org n=0
        while read -r hop_ip; do
            n=$((n+1))
            hop_asn=${IP2ASN[$hop_ip]:-}
            hop_org=${ASN2NAME[$hop_asn]:-}
            [ -n "$hop_asn" ] && asn_set="$asn_set $hop_asn"
            hop_detail="${hop_detail}${n}|${hop_ip}|${hop_asn:--}|$(printf '%s' "$hop_org" | cut -c1-36)
"
        done <"$f"
        ROUTE_HOPS[$name]="$hop_detail"
        local label
        case "$name" in
            中国*) label=$(classify_route "$asn_set" "$(cat "$f" | tr '\n' ' ')") ;;
            *)  # 国际目标:标注主要国际转接
                local a top_asn cnt best_cnt=0
                for a in $asn_set; do
                    cnt=$(printf '%s' "$asn_set" | tr ' ' '\n' | grep -cx "$a")
                    [ "$cnt" -gt "$best_cnt" ] && { best_cnt=$cnt; top_asn=$a; }
                done
                label="国际线路${top_asn:+ (主要 AS${top_asn} ${ASN2NAME[$top_asn]:-})}" ;;
        esac
        ROUTE_TARGETS+=("$name|$ip|$label|$(printf '%s' "$asn_set" | xargs | tr ' ' ',')")
        all_route_asns="${all_route_asns} ${asn_set}"
        kv "$name" "$label"
        rm -f "$f"
    done

    # IPv6 回程线路(双栈机):五省候选目标 -6 traceroute + 同一套 ASN 规则 → V6LINE_ROWS
    if [ -n "${G[ip6]:-}" ]; then
        local -a v6jobs=() v6specs=()
        local vk v6isp v6cc v6pv v6tip v6all="" v6sp v6f v6hop v6asn v6lbl
        local -a V6RT_ISP=(电信 联通 移动) V6RT_CC=(ct cu cm)
        for vk in 0 1 2; do
            v6isp=${V6RT_ISP[$vk]}; v6cc=${V6RT_CC[$vk]}
            v6tip=""
            for v6pv in bj sh gd sn zj; do
                v6tip=$(dig6 "${v6pv}-${v6cc}-v6.ip.zstaticcdn.com")
                [ -n "$v6tip" ] && break
            done
            [ -n "$v6tip" ] || continue
            trace_one "中国${v6isp}v6" "$v6tip" "$HQ_TMP/route6.$vk" "$ntbin" 6 & v6jobs+=($!)
            v6specs+=("${v6isp}:$HQ_TMP/route6.$vk")
        done
        [ ${#v6jobs[@]} -gt 0 ] && wait "${v6jobs[@]}" 2>/dev/null
        for v6sp in "${v6specs[@]}"; do
            v6f=${v6sp##*:}
            [ -s "$v6f" ] && v6all="$v6all
$(cat "$v6f")"
        done
        v6all=$(printf '%s' "$v6all" | grep -Ei '^([0-9a-f]{0,4}:){2,}[0-9a-f:]*$' \
            | grep -viE '^(fe80:|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:)' | sort -u)
        if [ -n "$v6all" ]; then
            declare -A V6IP2ASN=()
            local _rx _ra _rc _rn
            while IFS='|' read -r v6hop _ra _rc _rn; do
                [ -n "$v6hop" ] && V6IP2ASN[$v6hop]=${_ra:-}
            done < <(cymru_bulk "$v6all")
            for v6sp in "${v6specs[@]}"; do
                v6isp=${v6sp%%:*}; v6f=${v6sp##*:}
                v6asn=""; v6lbl=""
                if [ -s "$v6f" ]; then
                    while read -r v6hop; do
                        [ -n "${V6IP2ASN[$v6hop]:-}" ] && v6asn="$v6asn ${V6IP2ASN[$v6hop]}"
                    done <"$v6f"
                    # 无任何 ASN 信息时不强行归类(空集会被 classify 成"普通线路"造成误导)
                    [ -n "$v6asn" ] && v6lbl=$(classify_route "$v6asn" "")
                fi
                if [ -n "$v6lbl" ]; then
                    V6LINE_ROWS+=("${v6isp}|${v6lbl}")
                    kv "中国${v6isp}(v6)" "$v6lbl"
                fi
                rm -f "$v6f" 2>/dev/null
            done
        else
            for v6sp in "${v6specs[@]}"; do rm -f "${v6sp##*:}" 2>/dev/null; done
        fi
    fi

    # 生成线路汇总: "电信:CN2 GIA / 联通:4837 / 移动:CMIN2"
    local r _n _i _l _a summary=""
    for r in "${ROUTE_TARGETS[@]:-}"; do
        [ -n "$r" ] || continue
        IFS='|' read -r _n _i _l _a <<< "$r"
        case "$_n" in
            中国电信) summary="${summary}电信:${_l} " ;;
            中国联通) summary="${summary}联通:${_l} " ;;
            中国移动) summary="${summary}移动:${_l} " ;;
            中国教育网) summary="${summary}教育:${_l} " ;;
        esac
    done
    summary=$(printf '%s' "$summary" | xargs | tr ' ' '/')
    [ -n "$summary" ] && G[route_summary]="$summary"
    # Tier1 骨干命中(参考 NetQuality Tier1 连通性清单)
    local a t1_hits="" t1_seen=""
    for a in $all_route_asns; do
        if [ -n "${TIER1_ASNS[$a]:-}" ] && ! printf '%s' "$t1_seen" | grep -qw "${TIER1_ASNS[$a]}"; then
            t1_hits="${t1_hits}${TIER1_ASNS[$a]}·AS${a} "
            t1_seen="$t1_seen ${TIER1_ASNS[$a]}"
        fi
    done
    if [ -n "$t1_hits" ]; then
        G[tier1]=$(printf '%s' "$t1_hits" | xargs | tr ' ' '/')
        kv "$(L tier1k 'Tier1 骨干')" "${G[tier1]}"
    fi
    note "线路标签基于 ASN 规则(163/4837/9929/CN2/CMIN2/CMI 等)"
}
# ============================================================
# 三网按运营商汇总(矩阵/分享摘要共用)
# <电信|联通|移动> -> "avgms|jitter|loss%|tcpms|down|up|retrans|line"
# ============================================================
cn_isp_stat() {
    local isp=$1 r _n _i _a _f _nr avg loss jit
    local sum=0 n=0 jsum=0 jn=0 lsum=0 t="" d="" u="" rt="" ln=""
    [ ${#PING_ROWS[@]} -gt 0 ] && for r in ${PING_ROWS[@]+"${PING_ROWS[@]}"}; do
        IFS='|' read -r _n _i avg loss jit _ <<<"$r"
        case "$_n" in 中国${isp}·*)
            is_num "$avg"  && { sum=$(awk -v a=$sum -v b=$avg 'BEGIN{print a+b}'); n=$((n+1)); }
            is_num "$jit"  && { jsum=$(awk -v a=$jsum -v b=$jit 'BEGIN{print a+b}'); jn=$((jn+1)); }
            is_num "$loss" && lsum=$((lsum + loss)) ;; esac
    done
    local o="" j="" l=""
    [ "$n" -gt 0 ] && { o=$(awk -v s=$sum -v n=$n 'BEGIN{printf "%.1f",s/n}'); l=$(( (lsum + n / 2) / n )); }
    [ "$jn" -gt 0 ] && j=$(awk -v s=$jsum -v n=$jn 'BEGIN{printf "%.1f",s/n}')
    [ ${#TCP_ROWS[@]} -gt 0 ] && for r in ${TCP_ROWS[@]+"${TCP_ROWS[@]}"}; do
        IFS='|' read -r _n _i _a _f _nr <<<"$r"
        [ "$_n" = "${isp}·TOS" ] && t=$_a
    done
    for r in ${SPEED_ROWS[@]+"${SPEED_ROWS[@]}"}; do
        IFS='|' read -r _n _d _u _nr <<<"$r"
        [ "$_n" = "中国${isp}方向" ] && { d=$_d; u=$_u; }
    done
    rt=${G[tos_retrans_${isp}]:-}
    [ ${#ROUTE_TARGETS[@]} -gt 0 ] && for r in ${ROUTE_TARGETS[@]+"${ROUTE_TARGETS[@]}"}; do
        IFS='|' read -r _n _i _a _f2 <<<"$r"
        [ "$_n" = "中国${isp}" ] && ln=$_a
    done
    printf '%s|%s|%s|%s|%s|%s|%s|%s' "$o" "$j" "$l" "$t" "$d" "$u" "$rt" "$ln"
}

# ============================================================
# 分享摘要(纯文本,无 ANSI):适合直接粘贴论坛/聊天
# ============================================================
share_summary() {
    local dur=$(( $(date +%s) - HQ_START_TS )) durs isp avg jit loss tcp down up rtr line
    durs=$(awk -v s=$dur 'BEGIN{printf "%dm%02ds", int(s/60), s%60}')
    local bar="────────────────────────────────────────"
    local out="" eol=$'\n'
    out+="$(L ss_head "HostQoS v${HQ_VERSION}") · ${G[hostname]:-host}${eol}"
    out+="${bar}${eol}"
    out+="$(L ss_loc 位置)    ${G[loc_country]:-?} ${G[loc_city]:-} · $(L ss_prov 商家) ${G[prov_name]:-?}${G[virt]:+ · $(L ss_virt 虚拟化) ${G[virt]}}${eol}"
    [ -n "${G[grade_total]:-}" ] && out+="$(L ss_score 评分)    ${G[grade_total]} $(grade_cn "${G[grade_label]:-}") (cpu ${G[grade_cpu]:--} · disk ${G[grade_disk]:--} · net ${G[grade_net]:--} · ip ${G[grade_ip]:--})${eol}"
    [ -n "${G[cpu_score_single]:-}" ] && out+="CPU     $(L ss_single 单核) ${G[cpu_score_single]} · $(L ss_multi 多核) ${G[cpu_score_multi]} $(cpu_rating "${G[cpu_score_single]}") · ${G[cpu_threads]:-?}T${G[l3_cache]:+ · L3 ${G[l3_cache]}}${eol}"
    [ -n "$(fmt_mem_gb "${G[mem_total_mb]:-}")" ] && out+="$(L ss_mem 内存)    $(fmt_mem_gb "${G[mem_total_mb]}")${G[mem_w_mb]:+ · $(L ss_membw 带宽) $(fmt_mb "${G[mem_w_mb]}")/$(fmt_mb "${G[mem_r_mb]}")}${eol}"
    [ -n "${G[disk_4k_w]:-}" ] && out+="$(L ss_disk 磁盘)    4K $(fmt_mb "${G[disk_4k_w]}") · $(L ss_seq 顺序) $(fmt_mb "${G[disk_1m_w]:-}")${G[disk_type]:+ · ${G[disk_type]}}${eol}"
    if [ ${#PING_ROWS[@]} -gt 0 ] || [ ${#TCP_ROWS[@]} -gt 0 ] || [ ${#SPEED_ROWS[@]} -gt 0 ]; then
        out+="$(L ss_cn 三网)    "
        local first=1 had_line=0
        for isp in 电信 联通 移动; do
            IFS='|' read -r avg jit loss tcp down up rtr line <<<"$(cn_isp_stat "$isp")"
            [ -z "$avg$jit$tcp$down$up$line" ] && continue
            [ $first = 0 ] && out+="        "
            if [ -n "$avg" ]; then
                out+="$(printf '%s %.1fms' "$isp" "$avg")"
            elif [ -n "$tcp" ]; then
                out+="$(printf '%s TCP%.1fms' "$isp" "$tcp")"
            else
                out+="${isp} --"
            fi
            [ -n "$jit" ] && out+=" 抖${jit}"
            [ -n "$loss" ] && out+=" 丢${loss}%"
            [ -n "$down" ] && out+=" ↓$(printf '%.1f' "$down")M"
            [ -n "$up" ] && out+=" ↑$(printf '%.1f' "$up")M"
            [ -n "$rtr" ] && out+=" 重传${rtr}%"
            [ -n "$line" ] && { out+=" $line"; had_line=1; }
            out+="${eol}"
            first=0
        done
        [ $first = 1 ] && out+="${eol}"
        [ "$had_line" = 0 ] && [ -n "${G[route_summary]:-}" ] && out+="$(L ss_route 回程)    ${G[route_summary]}${eol}"
    else
        [ -n "${G[route_summary]:-}" ] && out+="$(L ss_route 回程)    ${G[route_summary]}${eol}"
    fi
    [ -n "${G[tier1]:-}" ] && out+="Tier1   ${G[tier1]}${eol}"
    [ -n "${G[mtu_summary]:-}" ] && out+="$(L ss_pkt 大小包)  ${G[mtu_summary]}${eol}"
    if [ -n "${G[fraud_score]:-}" ]; then
        out+="IP      $(L ss_fraud 欺诈) ${G[fraud_score]} (${G[fraud_risk]:-})"
        [ -n "${G[fraud2_score]:-}" ] && out+=" · ipapi ${G[fraud2_score]}"
        [ -n "${G[ip_usage]:-}" ] && out+=" · ${G[ip_usage_cat]:-${G[ip_usage]}}"
        case "${G[ip_native]:-}" in 1) out+=" · $(L native 原生)" ;; 0) out+=" · $(L bcast 广播)" ;; esac
        out+="${eol}"
    fi
    [ -n "${G[media_total_n]:-}" ] && out+="$(L ss_media 解锁)    ${G[media_yes_n]:-0}/${G[media_total_n]}${eol}"
    [ -n "${G[intl_total]:-}" ] && out+="$(L ss_intl 国际)    ${G[intl_ok_n]}/${G[intl_total]}$( [ "${OPT_LANG}" = en ] && echo ' up' || echo ' 可达')${G[intl_cdn]:+ · CDN $(fmt_mbps "${G[intl_cdn]}")}${G[dns_note]:+ · DNS ${G[dns_note]}}${eol}"
    [ -n "${G[nat_type]:-}" ] && out+="NAT     ${G[nat_type]}${eol}"
    out+="$(L ss_time 耗时)    $durs · ${HQ_START_TIME}${eol}"
    out+="${bar}${eol}"
    out+="hostqos · https://hostqos.com"
    printf '%s' "$out"
}

# ============================================================
# 三网质量矩阵(全宽表):运营商 × 延迟/抖动/丢包/TCP/下行/上行/重传/线路
# ============================================================
cn_matrix_html() {
    local isp avg jit loss tcp down up rtr line out="" any=0
    for isp in 电信 联通 移动; do
        IFS='|' read -r avg jit loss tcp down up rtr line <<<"$(cn_isp_stat "$isp")"
        [ -z "$avg$jit$tcp$down$up$line" ] || any=1
    done
    [ "$any" = 0 ] && { printf '%s' ""; return; }
    out='<table class="tbl mtxw"><tr><th>运营商</th><th>延迟</th><th>抖动</th><th>丢包</th><th>TCP握手</th><th>下行</th><th>上行</th><th>重传</th><th>回程线路</th></tr>'
    for isp in 电信 联通 移动; do
        IFS='|' read -r avg jit loss tcp down up rtr line <<<"$(cn_isp_stat "$isp")"
        [ -z "$avg$jit$tcp$down$up$line" ] && continue
        out+="<tr><td><b>${isp}</b></td>"
        out+="<td class=\"$(ms_class "$avg")\">$(fmt_ms "$avg")</td>"
        out+="<td class=\"dim\">$(esc "${jit:+±$(fmt_ms "$jit")}")</td>"
        out+="<td class=\"$(loss_class "$loss")\">$(esc "${loss:-}")${loss:+%}</td>"
        out+="<td class=\"$(ms_class "$tcp")\">$(fmt_ms "$tcp")</td>"
        out+="<td class=\"$(mbps_class "$down")\">$(esc "$(fmt_mbps "$down")")</td>"
        out+="<td class=\"$(mbps_class "$up")\">$(esc "$(fmt_mbps "$up")")</td>"
        local rtcls="lv-na"
        is_num "$rtr" && { rtcls=$(awk -v v="$rtr" 'BEGIN{print (v<1)?"lv-good":(v<5)?"lv-warn":"lv-bad"}'); }
        out+="<td class=\"${rtcls}\">$(esc "${rtr:-}")${rtr:+%}</td>"
        out+="<td class=\"c\">$(esc "${line:-—}")</td></tr>"
    done
    printf '%s</table>' "$out"
}

# ============================================================
# 综合参考评分(参考 HardwareQuality 的 score/label 模式,本地标定)
# 原型四分项:CPU(25%) 内存(10%) 磁盘(20%) 网络(35%) + IP质量(10%),缺项自动重归一
# ============================================================
calc_grade() {
    G[grade_total]=""; G[grade_label]=""
    local -a av=()
    is_num "${G[cpu_score_single]:-}" && av+=(-v "cpu=${G[cpu_score_single]}")
    is_num "${G[mem_w_mb]:-}" && av+=(-v "mw=${G[mem_w_mb]}")
    is_num "${G[fio4k_ri]:-}" && av+=(-v "fr=${G[fio4k_ri]}")
    is_num "${G[fio4k_wi]:-}" && av+=(-v "fw=${G[fio4k_wi]}")
    is_num "${G[disk_4k_w]:-}" && is_num "${G[disk_1m_w]:-}" && av+=(-v "d4=${G[disk_4k_w]}" -v "d1=${G[disk_1m_w]}")
    is_num "${G[best_down]:-}" && av+=(-v "dn=${G[best_down]}")
    is_num "${G[best_up]:-}" && av+=(-v "up=${G[best_up]}")
    is_num "${G[fraud_score]:-}" && av+=(-v "f=${G[fraud_score]}")
    [ ${#av[@]} -gt 0 ] || return 0
    local out
    out=$(awk "${av[@]}" -v ob="${G[oversell_balloon]:-0}" -v ok="${G[oversell_ksm]:-0}" 'BEGIN{
        c=""; m=""; d=""; n=""; p=""; ws=0; ts=0
        if (cpu != "") {
            c = cpu<150 ? cpu*30/150 : cpu<300 ? 30+(cpu-150)*20/150 : cpu<500 ? 50+(cpu-300)*20/200 \
              : cpu<800 ? 70+(cpu-500)*20/300 : cpu<1000 ? 90+(cpu-800)*0.05 : 100
            ws+=0.25; ts+=0.25*c
        }
        if (mw != "") {
            m = mw>=4000 ? 100 : sqrt(mw)*1.581   # 实测口径:单线程 tmpfs 写入,2124MB/s≈73 分
            # 超开扣分(参考 HardwareQuality):气球回收 ×0.8,KSM 复用 ×0.5(可叠加)
            if (ob==1) m*=0.8
            if (ok==1) m*=0.5
            ws+=0.10; ts+=0.10*m
        }
        if (d4 != "" && d1 != "") {
            # v2.7:4K 分量优先 FIO 4K 随机读写 IOPS 均值(10 万 IOPS 满分,direct=1 真实随机);
            #      无 FIO 时回退 DD 4K 写(注意 DD 经页缓存普遍虚高)
            if (fr != "" || fw != "") {
                fi4 = (fr != "" && fw != "") ? (fr+fw)/2 : (fr != "" ? fr : fw)
                d4s = fi4/1000; if (d4s>100) d4s=100
            } else {
                d4s = d4*0.66; if (d4s>100) d4s=100
            }
            d = 0.6*d4s + 0.4*(d1*0.2>100?100:d1*0.2)
            ws+=0.20; ts+=0.20*d
        }
        if (dn != "") {
            pd = (sqrt(dn)*3.16<100?sqrt(dn)*3.16:100)
            if (up != "") { pu=(sqrt(up)*3.16<100?sqrt(up)*3.16:100); n=0.6*pd+0.4*pu }
            else n=pd
            ws+=0.35; ts+=0.35*n
        }
        if (f != "") {
            p = f<=25 ? 100-f : f<=50 ? 75-(f-25)*0.8 : f<=75 ? 55-(f-50)*0.8 : (35-(f-75)*0.7>5?35-(f-75)*0.7:5)
            ws+=0.10; ts+=0.10*p
        }
        if (ws==0) exit
        t=ts/ws
        lbl = t>=90?"A+":t>=80?"A":t>=70?"B+":t>=60?"B":t>=45?"C":"D"
        cs = c=="" ? "-" : sprintf("%.0f",c)
        ms = m=="" ? "-" : sprintf("%.0f",m)
        ds = d=="" ? "-" : sprintf("%.0f",d)
        ns = n=="" ? "-" : sprintf("%.0f",n)
        ps = p=="" ? "-" : sprintf("%.0f",p)
        printf "%.0f %s %s %s %s %s %s", t, lbl, cs, ms, ds, ns, ps
    }')
    [ -n "$out" ] || return 0
    local gt gl gc gm gd gn gp _
    read -r gt gl gc gm gd gn gp _ <<< "$out"
    G[grade_total]=$gt; G[grade_label]=$gl
    [ "$gc" != "-" ] && G[grade_cpu]=$gc
    [ "$gm" != "-" ] && G[grade_mem]=$gm
    [ "$gd" != "-" ] && G[grade_disk]=$gd
    [ "$gn" != "-" ] && G[grade_net]=$gn
    [ "$gp" != "-" ] && G[grade_ip]=$gp
}

# 等级字母 → 中文(页面/终端摘要统一口径,避免两套阈值各说各话)
grade_cn() {
    case "${1:-}" in
        A+|A) printf '%s' 优秀 ;;
        B+|B) printf '%s' 良好 ;;
        C)    printf '%s' 一般 ;;
        D)    printf '%s' 较差 ;;
        *)    printf '%s' 待检测 ;;
    esac
}

# 最优测速值来源标注(摘要"网络"行注明测试类型)
spd_src_label() {
    case "$1" in
        就近节点) printf '临近节点·多线程' ;;
        中国电信方向|中国联通方向|中国移动方向) printf '%s TOS·单线程' "${1%方向}" ;;
        *下载) printf '%s CDN·单线程' "${1%下载}" ;;
        *) printf '%s·单线程' "$1" ;;
    esac
}

# 内存容量自适应显示:<1GB 用 MB,≥1GB 用 GB;无效/缺失输出空串(由调用方显示待检测)
fmt_mem_gb() {
    awk -v m="${1:-}" 'BEGIN{
        if (m == "" || m + 0 <= 0) exit
        if (m < 1024) { printf "%d MB", m + 0.5; exit }
        gb = m / 1024
        if (gb < 10) printf "%.1f GB", gb; else printf "%.0f GB", gb
    }'
}

# 原型"中国大陆三网线路与单线程测速"卡数据:每运营商一行
# CNMTX_ROWS: 运营商|回程线路|下行|上行|延迟|丢包|重传|评价
build_cn_matrix() {
    CNMTX_ROWS=()
    local isp avg jit loss tcp down up rtr line vd
    for isp in 电信 联通 移动; do
        IFS='|' read -r avg jit loss tcp down up rtr line <<<"$(cn_isp_stat "$isp")"
        [ -z "$avg$tcp$down$up$line" ] && continue
        vd=$(awk -v d="${down:-0}" -v u="${up:-0}" -v l="${loss:-0}" -v r="${rtr:-0}" -v a="${avg:-}" 'BEGIN{
            if (d+0 >= 100 && l+0 <= 1 && r+0 < 1) print "优秀"
            else if ((d+0 >= 50 || u+0 >= 100) && l+0 <= 5) print "良好"
            else if (d+0 > 0) print "一般"
            else if (l+0 > 0 || r+0 >= 5) print "一般"
            else if (a != "") print "良好"
            else print "待检测"
        }')
        CNMTX_ROWS+=("中国$isp|${line:-—}|${down:-}|${up:-}|${avg:-}|${loss:-}|${rtr:-}|$vd")
    done
    return 0
}

# ============================================================
# 终端摘要输出
# ============================================================
term_summary() {
    # 分享摘要:纯文本块,可直接复制粘贴到论坛(NodeSeek 等)
    sec "$(L report '测试报告') Summary"
    printf '%s\n' "${C_CYAN}$(share_summary)${C_OFF}"
}
# ============================================================
# M7 HTML 单页报告 + 历史索引 + JSON
# ============================================================
hq_level_class() { # good/warn/bad/na
    case ${1:-na} in
        good) printf 'lv-good' ;; warn) printf 'lv-warn' ;;
        bad)  printf 'lv-bad'  ;; *)    printf 'lv-na'  ;;
    esac
}
grade_cls() { # A+/A/B+/B/C/D -> CSS 类
    case ${1:-} in
        A+|A) printf 'gA' ;; B+|B) printf 'gB' ;;
        C)    printf 'gC' ;; D)    printf 'gD' ;; *) printf '' ;;
    esac
}
ms_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v<=80) print "lv-good"; else if (v<=200) print "lv-warn"; else print "lv-bad"; }'
}
# 逐包 RTT -> min/max
csv_stat() { # <csv> <min|max>
    printf '%s' "$1" | awk -F, -v s="$2" '{
        n=NF; if (n==0) exit
        mn=1e18; mx=-1e18
        for (i=1;i<=n;i++){ v=$i+0; if(v<mn)mn=v; if(v>mx)mx=v }
        if (s=="min") printf "%.1f", mn; else printf "%.1f", mx
    }'
}
# 逐包 RTT -> Unicode 块字符波形(参考 NetQuality sparkline)
rtt_spark() { # <csv>
    local csv=$1
    [ -n "$csv" ] || { printf '%s' "—"; return; }
    local -a lv SP=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    mapfile -t lv < <(printf '%s' "$csv" | awk -F, '{
        n=NF; if(n==0) exit; mn=1e18; mx=-1e18
        for(i=1;i<=n;i++){v=$i+0;if(v<mn)mn=v;if(v>mx)mx=v}
        s=mx-mn; if(s<0.0001)s=1
        for(i=1;i<=n;i++){l=int(($i+0-mn)/s*7)+1; if(l>8)l=8; print l}
    }')
    local i out=""
    for i in "${lv[@]}"; do out+=${SP[$((i-1))]}; done
    printf '%s' "$out"
}
loss_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    # 丢包三级色:0% 绿 / 1-20% 黄 / >20% 红
    awk -v v="$v" 'BEGIN{ if (v==0) print "lv-good"; else if (v<=20) print "lv-warn"; else print "lv-bad"; }'
}
cpu1_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v>=800) print "lv-good"; else if (v>=300) print "lv-warn"; else print "lv-bad"; }'
}
cpuN_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v>=3500) print "lv-good"; else if (v>=1200) print "lv-warn"; else print "lv-bad"; }'
}
disk4k_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v>=100) print "lv-good"; else if (v>=30) print "lv-warn"; else print "lv-bad"; }'
}
diskseq_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v>=400) print "lv-good"; else if (v>=100) print "lv-warn"; else print "lv-bad"; }'
}
mbps_class() {
    local v=$1
    is_num "$v" || { printf 'lv-na'; return; }
    awk -v v="$v" 'BEGIN{ if (v>=300) print "lv-good"; else if (v>=100) print "lv-warn"; else print "lv-bad"; }'
}

html_media_chips() {
    local row svc status region cls label
    [ ${#MEDIA_ROWS[@]} -eq 0 ] && { printf '%s' '<span class="muted">NT</span>'; return; }
    for row in "${MEDIA_ROWS[@]}"; do
        IFS='|' read -r svc status region <<< "$row"
        case $status in
            yes)  cls='st-yes';  label='支持' ;;
            no)   cls='st-no';   label='不支持' ;;
            orig) cls='st-orig'; label='仅自制' ;;
            *)    cls='st-fail'; label='失败' ;;
        esac
        printf '<div class="chip %s"><span class="chip-s">%s</span><span class="chip-t">%s</span>%s</div>' \
            "$cls" "$(esc "$svc")" "$label" "${region:+<span class=\"chip-r\">$(esc "$region")</span>}"
    done
}

html_speed_table() {
    local row name down up note out="" maxd=0
    [ ${#SPEED_ROWS[@]} -eq 0 ] && { printf '%s' '<span class="muted">未测速</span>'; return; }
    for row in "${SPEED_ROWS[@]}"; do
        IFS='|' read -r name down up note <<< "$row"
        is_num "$down" && awk -v a=$maxd -v b=$down 'BEGIN{exit !(b>a)}' && maxd=$down
    done
    out='<table class="tbl"><tr><th>节点</th><th>下行</th><th style="width:30%"></th><th>上行</th><th>备注</th></tr>'
    for row in "${SPEED_ROWS[@]}"; do
        IFS='|' read -r name down up note <<< "$row"
        local w=0
        is_num "$down" && [ "$maxd" != 0 ] && w=$(awk -v d=$down -v m=$maxd 'BEGIN{printf "%d", d/m*100}')
        out="${out}<tr><td>$(esc "$name")</td><td class=\"$(mbps_class "$down")\">$(esc "$(fmt_mbps "$down")")</td>"
        out="${out}<td><div class=\"bar\"><div class=\"bar-fill bf-dn\" style=\"width:${w}%\"></div></div></td>"
        out="${out}<td class=\"$(mbps_class "$up")\">$(esc "$(fmt_mbps "$up")")</td><td class=\"dim note\" title=\"$(esc "$note")\">$(esc "$note")</td></tr>"
    done
    printf '%s</table>' "$out"
}


# 大小包明细表(完整模式)
html_mtu_table() {
    local row name sz loss rtt out=""
    out='<table class="tbl"><tr><th>方向</th><th>档位</th><th>丢包</th><th>延迟</th></tr>'
    [ ${#MTU_ROWS[@]} -eq 0 ] && { printf '%s</table>' "$out"; return; }
    for row in "${MTU_ROWS[@]}"; do
        IFS='|' read -r name sz loss rtt <<< "$row"
        out="${out}<tr><td>$(esc "$name")</td><td>$(esc "$sz")</td><td class=\"$(loss_class "$loss")\">$(esc "$loss")%</td><td>$(esc "$(fmt_ms "$rtt")")</td></tr>"
    done
    printf '%s</table>' "$out"
}

# 国际互联明细表(完整模式)
html_intl_table() {
    local row name disp _ms lvl out=""
    out='<table class="tbl"><tr><th>目标</th><th>状态</th><th>握手延迟</th></tr>'
    [ ${#INTL_ROWS[@]} -eq 0 ] && { printf '%s</table>' "$out"; return; }
    for row in "${INTL_ROWS[@]}"; do
        IFS='|' read -r name disp _ms lvl <<< "$row"
        out="${out}<tr><td>$(esc "$name")</td><td class=\"$(hq_level_class "$lvl")\">$(esc "$disp")</td><td>$(esc "$(fmt_ms "$_ms")")</td></tr>"
    done
    printf '%s</table>' "$out"
}

html_ping_table() {
    local row name ip avg loss jit rtts out="" mn mx
    [ ${#PING_ROWS[@]} -eq 0 ] && [ ${#TCP_ROWS[@]} -eq 0 ] && { printf '%s' '<span class="muted">NT</span>'; return; }
    out='<table class="tbl"><tr><th>协议</th><th>目标</th><th>IP</th><th>平均</th><th>最好</th><th>最差</th><th>抖动</th><th>丢包</th><th>波形</th></tr>'
    for row in ${PING_ROWS[@]+"${PING_ROWS[@]}"}; do
        IFS='|' read -r name ip avg loss jit rtts <<< "$row"
        mn=$(csv_stat "$rtts" min); mx=$(csv_stat "$rtts" max)
        out="${out}<tr><td class=\"dim\">ICMP</td><td>$(esc "$name")</td><td class=\"mono\">$(esc "$ip")</td>"
        out="${out}<td class=\"$(ms_class "$avg")\">$(esc "$(fmt_ms "$avg")")</td><td class=\"dim\">$(esc "$(fmt_ms "$mn")")</td><td class=\"dim\">$(esc "$(fmt_ms "$mx")")</td>"
        out="${out}<td>$(esc "${jit:+±$(fmt_ms "$jit")}")</td><td class=\"$(loss_class "$loss")\">$(esc "$loss")%</td>"
        out="${out}<td class=\"spark $(ms_class "$avg")\" title=\"$(esc "$rtts")\">$(rtt_spark "$rtts")</td></tr>"
    done
    for row in ${TCP_ROWS[@]+"${TCP_ROWS[@]}"}; do
        IFS='|' read -r name ip avg loss rtts <<< "$row"
        mn=$(csv_stat "$rtts" min); mx=$(csv_stat "$rtts" max)
        out="${out}<tr><td class=\"dim\">TCP</td><td>$(esc "$name")</td><td class=\"mono\">$(esc "$ip")</td>"
        out="${out}<td class=\"$(ms_class "$avg")\">$(esc "$(fmt_ms "$avg")")</td><td class=\"dim\">$(esc "$(fmt_ms "$mn")")</td><td class=\"dim\">$(esc "$(fmt_ms "$mx")")</td>"
        out="${out}<td class=\"dim\">—</td><td class=\"$(loss_class "$loss")\">$(esc "$loss")%</td>"
        out="${out}<td class=\"spark $(ms_class "$avg")\" title=\"$(esc "$rtts")\">$(rtt_spark "$rtts")</td></tr>"
    done
    printf '%s</table>' "$out"
}

html_ipq_table() {
    local row name val lvl out=""
    out='<table class="tbl"><tr><th>项目</th><th>结果</th></tr>'
    [ ${#IPQ_ROWS[@]} -eq 0 ] && { printf '%s</table>' "$out"; return; }
    for row in "${IPQ_ROWS[@]}"; do
        IFS='|' read -r name val lvl <<< "$row"
        out="${out}<tr><td>$(esc "$name")</td><td class=\"$(hq_level_class "$lvl")\">$(esc "$val")</td></tr>"
    done
    [ ${#DNSBL_ROWS[@]} -eq 0 ] || for row in "${DNSBL_ROWS[@]}"; do
        IFS='|' read -r name val lvl <<< "$row"
        out="${out}<tr><td>DNSBL: $(esc "$name")</td><td class=\"$(hq_level_class "$lvl")\">$(esc "$val")</td></tr>"
    done
    printf '%s</table>' "$out"
}

html_fio_table() {
    local row bs rd wr ri wi out=""
    out='<table class="tbl"><tr><th>块大小</th><th>读</th><th>写</th><th>读 IOPS</th><th>写 IOPS</th></tr>'
    [ ${#FIO_ROWS[@]} -eq 0 ] && { printf '%s</table>' "$out"; return; }
    for row in "${FIO_ROWS[@]}"; do
        IFS='|' read -r bs rd wr ri wi <<< "$row"
        out="${out}<tr><td>$(esc "$bs")</td><td>$(esc "$(fmt_mb "$rd")")</td><td>$(esc "$(fmt_mb "$wr")")</td><td>$(esc "$ri")</td><td>$(esc "$wi")</td></tr>"
    done
    printf '%s</table>' "$out"
}

html_route_detail() {
    local out="" t name ip label asns hops row hop_no hop_ip hop_asn hop_org
    [ ${#ROUTE_TARGETS[@]} -eq 0 ] && { printf '%s' '<span class="muted">NT</span>'; return; }
    for t in "${ROUTE_TARGETS[@]}"; do
        IFS='|' read -r name ip label asns <<< "$t"
        hops=${ROUTE_HOPS[$name]:-}
        out="${out}<div class=\"route-t\"><b>$(esc "$name")</b> <span class=\"mono muted\">$(esc "$ip")</span></div>"
        out="${out}<table class=\"tbl tbl-sm\"><tr><th>#</th><th>跳点 IP</th><th>ASN</th><th>组织</th></tr>"
        while IFS='|' read -r hop_no hop_ip hop_asn hop_org; do
            [ -n "${hop_ip:-}" ] || continue
            out="${out}<tr><td>${hop_no}</td><td class=\"mono\">$(esc "$hop_ip")</td><td>$(esc "$hop_asn")</td><td>$(esc "$hop_org")</td></tr>"
        done <<< "$hops"
        out="${out}</table>"
    done
    printf '%s' "$out"
}

# 省份延迟矩阵表(完整模式):单元格 42.5 / 42.5*25%(带丢包) / × / -
html_prov_table() {
    local row prov ct cu cm out="" cls cell
    [ ${#PROV_ROWS[@]} -eq 0 ] && { printf '%s' '<span class="muted">NT</span>'; return; }
    out='<table class="tbl provt"><tr><th>省份</th><th>电信</th><th>联通</th><th>移动</th></tr>'
    for row in ${PROV_ROWS[@]+"${PROV_ROWS[@]}"}; do
        IFS='|' read -r prov ct cu cm <<<"$row"
        out+="<tr><td>$(esc "$prov")</td>"
        for cell in "$ct" "$cu" "$cm"; do
            case "$cell" in
                -)    cls="lv-na" ;;
                ×)       cls="lv-bad" ;;
                *\**)    cls="lv-warn" ;;   # 带丢包标注
                *)       cls=$(ms_class "$cell") ;;
            esac
            out+="<td class=\"${cls}\">$(esc "$cell")</td>"
        done
        out+="</tr>"
    done
    printf '%s</table>' "$out"
}

# 简单 KV 表格: html_kv_table "标题1;标题2" "行数组(格式 v1|v2)"
html_kv_table() {
    local h1=$1 h2=$2; shift 2
    local out
    out="<table class=\"tbl\"><tr><th>$(esc "$h1")</th><th>$(esc "$h2")</th></tr>"
    local row a b
    for row in "$@"; do
        IFS='|' read -r a b <<< "$row"
        out="${out}<tr><td>$(esc "$a")</td><td>$(esc "$b")</td></tr>"
    done
    printf '%s</table>' "$out"
}

# ============================================================
# 原型 v3 报告渲染层(自绘仪表盘 · 卡片网格 · 一屏自适应 · 零依赖)
# ============================================================
HQ_PROTO_CSS=$(cat <<'HQCSSEOF'

:root{--navy:#102f69;--blue:#0968df;--blue2:#2788ff;--line:#d8e9fa;--muted:#6b82a3;--green:#159c59;--greenbg:#e8f8ee;--amber:#e58a05;--amberbg:#fff4d8;--red:#dc2345;--redbg:#fff0f2;--purple:#7b2de2;--card:#fff;--shadow:0 2px 8px #176db009;--radius:10px}
*{box-sizing:border-box}html,body{margin:0;min-height:100%;font-family:Inter,"Microsoft YaHei","PingFang SC","Noto Sans SC",Arial,sans-serif;color:#142f62;background:linear-gradient(135deg,#eaf5ff,#f5faff 50%,#e7f3ff);font-size:11px}body{line-height:1.25}button,select{font:inherit}button{cursor:pointer}a{color:inherit;text-decoration:none}
.topbar{height:52px;display:flex;align-items:center;gap:12px;padding:6px 14px;color:#fff;background:linear-gradient(105deg,#184c9e,#0758b6 55%,#0878d9);position:relative;z-index:10;box-shadow:0 3px 12px #074f9b20;overflow:visible}.brand{display:flex;align-items:center;gap:9px;flex:0 0 255px;min-width:220px}.brand-cube{width:39px;height:39px;display:block;flex:0 0 auto}.brand-title{font-size:26px;line-height:1;font-weight:850;letter-spacing:.2px;white-space:nowrap}.brand-sub{font-size:11px;opacity:.94;margin-top:3px;letter-spacing:.25px}.vdivider{height:39px;width:1px;background:#ffffff50;flex:0 0 auto}.server-head{flex:1;min-width:160px}.server-name{font-weight:850;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.server-meta{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:4px;font-size:9.5px;opacity:.92}.server-meta i{opacity:.5;font-style:normal}.head-actions{display:flex;gap:6px;align-items:center;flex:0 0 auto}.head-btn{border:1px solid #ffffff91;border-radius:7px;background:#ffffff12;color:#fff;padding:7px 9px;display:inline-flex;align-items:center;gap:5px;font-size:10px;font-weight:800;white-space:nowrap}.head-btn:hover{background:#ffffff2a}.head-btn svg{width:13px;height:13px;fill:none;stroke:currentColor;stroke-width:2}.case-select{display:none;background:#ffffff14;color:white;border:1px solid #ffffff88;border-radius:7px;padding:6px 8px;max-width:155px}.case-select option{color:#102f69}.show-cases .case-select{display:block}.dashboard{padding:5px 10px 5px;max-width:1920px;margin:0 auto;display:flex;flex-direction:column;gap:5px}.top-grid{display:grid;grid-template-columns:1fr 1.08fr 1.28fr;gap:7px;align-items:stretch}.card{background:rgba(255,255,255,.96);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);min-width:0;overflow:visible}.section-head{height:25px;padding:0 8px;display:flex;align-items:center;gap:6px;border-bottom:1px solid #e5f0fc;min-width:0}.section-head.no-border{border-bottom:0}.section-icon{width:21px;height:21px;flex:0 0 auto;border-radius:5px;display:grid;place-items:center;color:#fff;background:linear-gradient(145deg,#2193ff,#075ce0)}.section-icon svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}.section-title{font-size:12.5px;font-weight:850;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin:0;line-height:1.15}.help{position:relative;width:14px;height:14px;flex:0 0 auto;border:1px solid #2878de;border-radius:50%;background:#fff;color:#176ad0;font-size:9px;font-weight:900;line-height:1;padding:0;display:inline-grid;place-items:center}.tooltip{display:none;position:absolute;top:calc(100% + 7px);left:0;width:260px;padding:8px 10px;background:#fff;border:1px solid #c7ddf5;border-radius:8px;box-shadow:0 8px 24px #14386e2b;color:#294b79;font-size:10px;white-space:pre-line;line-height:1.45;font-weight:500;text-align:left;z-index:80}.help:hover .tooltip,.help:focus-visible .tooltip,.help.open .tooltip{display:block}.pill{padding:3px 7px;border-radius:5px;background:var(--greenbg);color:#09864a;font-size:9px;font-weight:900;white-space:nowrap}.pill.good{background:var(--greenbg);color:#0a884b}.pill.warn{background:var(--amberbg);color:#b66c00}.pill.bad{background:var(--redbg);color:#c41638}.pill.pending{background:#edf3fa;color:#657c9b}.pill.error{background:#f1eaff;color:#6b37bd}
/* Host score */
.score-body{display:grid;grid-template-columns:38% 62%;gap:4px;padding:3px 7px 4px;align-items:center}.score-hero{height:78px;display:flex;flex-direction:column;align-items:center;justify-content:center;border-radius:8px;background:linear-gradient(135deg,#fffaf1,#f3f9ff)}.gauge{width:115px;height:47px;position:relative}.gauge svg{width:100%;height:100%;overflow:visible}.gauge-number{position:absolute;bottom:0;left:0;right:0;text-align:center;font-size:25px;font-weight:900;color:#dc2345;line-height:1}.gauge-number small{font-size:12px;color:#7085a5}.score-caption{margin-top:3px;padding:3px 7px;border-radius:5px;background:#fff1cc;color:#df7100;font-size:10px;font-weight:850;width:88%;text-align:center}.score-bars{display:flex;flex-direction:column;gap:5px;padding:2px 2px 2px 4px}.bar-row{display:grid;grid-template-columns:13px 50px minmax(25px,1fr) 39px;gap:4px;align-items:center;font-size:9.5px;min-width:0}.bar-name{white-space:nowrap}.bar-track{height:7px;border-radius:12px;background:#e7eef5;overflow:hidden}.bar-fill{height:100%;background:linear-gradient(90deg,#1eac64,#53cb84);border-radius:12px}.bar-fill.warn{background:linear-gradient(90deg,#ffaf18,#ffd34d)}.bar-fill.bad{background:linear-gradient(90deg,#e23e51,#ff8290)}.bar-value{font-size:9.5px;text-align:right;font-weight:900;color:#0c924f;white-space:nowrap}.bar-value.warn{color:#c77b00}.bar-value.bad{color:#d21a3b}
/* Server specs */
.spec-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));padding:3px 5px 4px}.spec{display:flex;align-items:center;gap:5px;padding:3px 4px;min-width:0;border-right:1px solid #e3eef9;border-bottom:1px solid #e3eef9}.spec:nth-child(3n){border-right:0}.spec:nth-last-child(-n+3){border-bottom:0}.spec-icon{width:21px;height:21px;color:#0877f7;flex:0 0 auto;display:grid;place-items:center}.spec-icon svg{width:100%;height:100%;fill:none;stroke:currentColor;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}.spec-copy{min-width:0}.spec-value{display:flex;align-items:center;gap:4px;font-size:10.5px;font-weight:850;white-space:nowrap;min-width:0}.spec-label{font-size:8.5px;color:var(--muted);margin-top:1px;white-space:nowrap}.os-mark{width:20px;height:20px;display:grid;place-items:center;color:#d70a53;font-weight:900;font-family:Arial,sans-serif;font-size:18px}.cpu-info{position:relative;display:inline-flex;align-items:center}.cpu-info-btn{width:13px;height:13px;border:1px solid #4385d3;border-radius:50%;background:#fff;color:#126ad1;font-size:8px;font-weight:900;padding:0;display:inline-grid;place-items:center}.cpu-info-tip{display:none;position:absolute;top:calc(100% + 6px);left:0;width:265px;padding:9px 10px;background:#fff;border:1px solid #c8def5;border-radius:8px;box-shadow:0 9px 25px #14386e35;z-index:90;color:#2c4d7b;font-size:10px;line-height:1.45;white-space:normal;font-weight:500}.cpu-info-tip b{display:block;color:#0c3976;margin-bottom:4px}.cpu-info-tip .tip-row{display:block;padding:1px 0}.cpu-info-tip em{display:block;font-style:normal;background:#fff4d7;color:#9c6200;border-radius:5px;padding:5px;margin-top:5px}.cpu-info:hover .cpu-info-tip,.cpu-info:focus-within .cpu-info-tip,.cpu-info.open .cpu-info-tip{display:block}
/* mainland carrier table */
.data-table{width:100%;border-collapse:separate;border-spacing:0;font-size:9.3px}.data-table th,.data-table td{padding:4px 3px;border-right:1px solid #dfebf8;border-bottom:1px solid #dfebf8;text-align:center;white-space:nowrap}.data-table th{background:#f1f8ff;color:#31547f;font-weight:850;border-top:1px solid #dfebf8}.data-table tr th:first-child,.data-table tr td:first-child{border-left:1px solid #dfebf8}.data-table thead th:first-child{border-top-left-radius:5px}.data-table thead th:last-child{border-top-right-radius:5px}.data-table tbody tr:last-child td:first-child{border-bottom-left-radius:5px}.data-table tbody tr:last-child td:last-child{border-bottom-right-radius:5px}.china-wrap{padding:0 5px 5px}.carrier{display:flex;align-items:center;gap:4px;font-size:9px;font-weight:850;white-space:nowrap;justify-content:flex-start}.carrier-logo{display:inline-grid;place-items:center;width:19px;height:19px;flex:0 0 auto}.carrier-logo svg{display:block;width:100%;height:100%}.route-name{display:inline-block;background:#e5f8ed;color:#087c45;padding:3px 4px;border-radius:4px;font-size:8.5px;font-weight:850;white-space:nowrap}.num{font-weight:900;color:#0869e7}.good-text{color:#07884a;font-weight:850}.warn-text{color:#d37c00;font-weight:850}.bad-text{color:#d91e40;font-weight:850}.cell{display:inline-block;padding:3px 5px;border-radius:4px;font-size:8.5px;font-weight:900;min-width:35px}.cell.good{background:#e3f8eb;color:#07864a}.cell.warn{background:#fff2d0;color:#c57900}.cell.bad{background:#ffe7eb;color:#d21a3d}.cell.pending{background:#eef3f9;color:#657d9e}.cell.error{background:#f1eaff;color:#6b37bd}
/* benchmark strip */
.benchmark{display:grid;grid-template-columns:150px minmax(0,1fr) minmax(0,1fr);gap:6px;align-items:stretch;padding:5px 7px}.bench-intro{display:flex;flex-direction:column;justify-content:center;padding:3px 7px;border-right:1px solid #e1edf9;min-width:0}.bench-title{font-size:11px;font-weight:900;display:flex;align-items:center;gap:5px}.bench-title svg{width:16px;height:16px;stroke:#0869df;fill:none;stroke-width:2}.bench-sub{font-size:8.5px;color:#6e86a6;margin-top:3px}.bench-group{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:4px;min-width:0}.bench-metric{padding:4px 6px;background:#f4f9ff;border:1px solid #e1edf9;border-radius:6px;min-width:0}.bench-metric label{font-size:8.5px;color:#6a82a3;display:block;white-space:nowrap}.bench-metric strong{font-size:11px;display:block;color:#164d93;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.bench-metric strong.pending{color:#c47a00}.bench-metric small{font-size:8px;color:#7b8eaa;font-weight:600}
/* International locations - compact cards */
.international .section-head{height:25px}.legend{display:flex;align-items:center;gap:9px;margin-left:auto;white-space:nowrap;color:#6b82a2;font-size:8.5px}.legend span{display:flex;align-items:center;gap:3px}.dot{width:6px;height:6px;border-radius:50%;display:inline-block}.dot.down{background:#0671ff}.dot.up{background:#8b2bfb}.dot.lat{background:#19aa61}.dot.loss{background:#f09313}.intl-grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:5px;padding:7px 8px 7px}.intl-item{border:1px solid #e0eefb;border-radius:6px;background:linear-gradient(180deg,#f8fcff,#eff7ff);padding:7px 5px 6px;min-width:0;overflow:hidden}.intl-top{display:flex;align-items:center;gap:3px;min-width:0}.flag{display:inline-flex;width:15px;height:10px;flex:0 0 auto;align-items:center;justify-content:center}.flag svg{width:100%;height:100%;border:1px solid #d1dfed;border-radius:1px;display:block}.apple-flag{width:15px;height:15px}.apple-flag svg{width:14px;height:14px;fill:#222}.intl-name{font-size:8.5px;font-weight:850;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1}.intl-state{font-size:7.5px;font-weight:900;white-space:nowrap;padding:2px 3px;border-radius:3px;background:#e1f8ea;color:#07874a}.intl-state.warn{background:#fff0ca;color:#bb7200}.intl-state.bad{background:#ffe5e9;color:#d51c3d}.intl-state.pending{background:#edf3fa;color:#657c9b}.intl-state.error{background:#f1eaff;color:#6b37bd}.intl-speeds{display:grid;grid-template-columns:1fr 1fr;gap:2px;margin-top:7px}.intl-speed{font-size:9px;font-weight:900;white-space:nowrap;color:#086df2;overflow:hidden;text-overflow:ellipsis}.intl-speed.up{color:#7926df}.intl-bottom{display:flex;align-items:center;justify-content:space-between;gap:2px;border-top:1px solid #deebf8;margin-top:3px;padding-top:3px;font-size:7.5px;white-space:nowrap}.intl-bottom .lat{color:#139954}.intl-bottom .loss{color:#d98200}.intl-bottom span{overflow:hidden;text-overflow:ellipsis}
/* Route quality: intentionally same geometry for IPv4 and IPv6 */
.route-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px}.route-card{padding-bottom:5px;min-width:0}.route-card .section-head{height:26px}.route-card .section-title{font-size:12px}.route-card .section-icon{background:linear-gradient(135deg,#20b66c,#07854b)}.route-card[data-tone="warn"] .section-icon{background:linear-gradient(135deg,#f7b326,#e08300)}.route-card[data-tone="bad"] .section-icon{background:linear-gradient(135deg,#fa4965,#d91b3f)}.route-card[data-tone="pending"] .section-icon{background:linear-gradient(135deg,#8fa5c0,#647a99)}.route-body{display:grid;grid-template-columns:minmax(0,.82fr) minmax(0,1.18fr);gap:5px;padding:4px 6px 0;align-items:stretch}.route-summary{border:1px solid #e2eef9;border-radius:7px;background:linear-gradient(135deg,#f5fbff,#fff);padding:5px 6px;display:flex;flex-direction:column;justify-content:center;min-width:0}.route-summary-top{display:flex;align-items:center;gap:7px;justify-content:center}.donut{width:37px;height:37px;flex:0 0 auto;border-radius:50%;position:relative;background:conic-gradient(var(--green) var(--pct,100%),#e6eef6 0)}.donut:after{content:"";position:absolute;inset:7px;border-radius:50%;background:#fff}.route-card[data-tone="warn"] .donut{background:conic-gradient(var(--amber) var(--pct,60%),#f5e9d2 0)}.route-card[data-tone="bad"] .donut{background:conic-gradient(var(--red) var(--pct,0%),#f3e1e5 0)}.route-card[data-tone="pending"] .donut{background:conic-gradient(#9bacc3 var(--pct,0%),#e9eef5 0)}.route-count{font-size:18px;font-weight:950;line-height:1;color:#102e69;white-space:nowrap}.route-card[data-tone="good"] .route-count{color:#0b8a4a}.route-card[data-tone="warn"] .route-count{color:#c77a00}.route-card[data-tone="bad"] .route-count{color:#d91e40}.route-card[data-tone="pending"] .route-count{color:#6c83a2}.route-count small{font-size:10px;color:#6f86a4}.route-main-label{font-size:8.5px;font-weight:850;margin-top:2px;color:#0b894b;white-space:nowrap}.route-card[data-tone="warn"] .route-main-label{color:#c77a00}.route-card[data-tone="bad"] .route-main-label{color:#d91e40}.route-card[data-tone="pending"] .route-main-label{color:#6c83a2}.route-progress{display:flex;align-items:center;gap:4px;font-size:8px;color:#5d7b9f;margin-top:5px}.route-progress-bar{height:4px;border-radius:8px;background:#e6eef6;flex:1;overflow:hidden}.route-progress-bar b{display:block;height:100%;width:var(--pct,0%);background:var(--green);border-radius:8px}.route-card[data-tone="warn"] .route-progress-bar b{background:var(--amber)}.route-card[data-tone="bad"] .route-progress-bar b{background:var(--red)}.route-card[data-tone="pending"] .route-progress-bar b{background:#9bacc3}.route-note{margin-top:4px;font-size:8.3px;line-height:1.25;padding:4px 5px;border-radius:5px;background:#edf8f1;color:#4e7b63;min-height:25px}.route-card[data-tone="warn"] .route-note{background:#fff5dd;color:#9a6a12}.route-card[data-tone="bad"] .route-note{background:#fff0f2;color:#b52641}.route-card[data-tone="pending"] .route-note{background:#f0f4f8;color:#6a7f9a}.packet-table{min-width:0}.packet-table table{font-size:8.6px;height:100%}.packet-table th,.packet-table td{padding:3px 2px}.packet-table th{white-space:normal}.packet-table td{height:18px}.packet-table .cell{font-size:7.8px;padding:2px 4px;min-width:30px} .packet-table table{width:100%;table-layout:fixed}.packet-table th:first-child,.packet-table td:first-child{width:26%}
/* Bottom panels */
.bottom-grid{display:grid;grid-template-columns:.98fr 1.38fr .96fr;gap:6px;align-items:stretch}.bottom-grid .section-head{height:26px}.risk-columns{display:grid;grid-template-columns:1fr 1fr;gap:4px;padding:4px 5px}.risk-panel{border:1px solid #e1f1e7;border-radius:6px;overflow:hidden;min-width:0}.risk-panel.t-bad{border-color:#ffe2e7}.risk-head{display:flex;align-items:center;justify-content:space-between;gap:3px;background:#eaf9f0;color:#088348;padding:4px 5px;font-size:9.5px;font-weight:900}.risk-panel.t-bad .risk-head{background:#fff0f2;color:#d21b3e}.risk-panel.t-warn .risk-head{background:#fff6e0;color:#b37300}.risk-panel.t-pending .risk-head{background:#f0f5fb;color:#647c9c}.risk-grade{font-size:8px;padding:2px 4px;border-radius:4px;background:#d8f5e4;color:#087c44;white-space:nowrap}.risk-grade.warn{background:#fff0cd;color:#ba7200}.risk-grade.bad{background:#ffe0e5;color:#c71d3c}.risk-grade.pending{background:#edf3fa;color:#6a7e9a}.risk-line{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px;padding:3px 5px;border-top:1px solid #e5eff8;font-size:8.5px;min-height:17px;align-items:center}.risk-line span:first-child{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.risk-line b{font-size:8.5px;font-weight:800;white-space:nowrap;color:#1676a8}.risk-line b.warn{color:#c77800}.risk-line b.bad{color:#d21e40}.risk-line b.pending{color:#758aa7}.risk-meta{display:grid;grid-template-columns:1fr;gap:0;padding:0 5px 4px}.risk-meta .risk-line{min-height:16px}
.unlock-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px;padding:4px 5px 3px}.unlock-group{border:1px solid #dfedf9;border-radius:6px;overflow:hidden;min-width:0}.unlock-group h3{font-size:8.5px;margin:0;padding:4px 5px;background:#f2f8ff;border-bottom:1px solid #dfedf9;display:flex;justify-content:space-between;align-items:center;color:#315680;white-space:nowrap}.unlock-count{font-size:7.5px;color:#7188a5}.unlock-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:3px;align-items:center;padding:3px 4px;border-bottom:1px solid #edf3fa;min-height:17px;min-width:0}.unlock-row:last-child{border-bottom:0}.service-name{display:flex;gap:4px;align-items:center;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:8.3px;font-weight:800}.service-icon{display:inline-grid;place-items:center;width:13px;height:13px;border-radius:3px;flex:0 0 auto;background:#3d70b9;color:#fff;font-size:8px;font-weight:900}.service-icon.netflix{background:#fff;color:#e50914;font-size:13px}.service-icon.youtube{background:#e62117}.service-icon.disney{background:#132b82}.service-icon.prime{background:#1494c9}.service-icon.spotify{background:#159954}.service-icon.hulu{background:#111}.service-icon.tiktok{background:#131313}.service-icon.reddit{background:#ff5700}.service-icon.x{background:#111}.service-icon.instagram{background:linear-gradient(135deg,#8054e8,#f23863,#ffb83f)}.service-icon.ai{background:#148d83}.unlock-result{display:flex;align-items:center;gap:3px;min-width:0}.unlock-state{font-size:7.6px;font-weight:900;border-radius:3px;padding:2px 3px;white-space:nowrap}.unlock-state.unlocked{background:#e0f7e9;color:#078246}.unlock-state.partial{background:#fff0cb;color:#b76c00}.unlock-state.blocked{background:#ffe3e8;color:#cc1d3e}.unlock-state.pending{background:#edf3fa;color:#677f9f}.unlock-state.error{background:#f1eaff;color:#6735b9}.unlock-state.unsupported{background:#eef1f5;color:#6b7789}.unlock-loc{font-size:7.6px;color:#6f86a5;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:43px}.unlock-foot{font-size:7.5px;color:#7388a6;padding:0 6px 4px}
.mail-core{display:grid;grid-template-columns:1fr 1.15fr;gap:4px;padding:4px 5px}.mail-port,.dnsbl{border:1px solid #e0edf9;border-radius:6px;background:#f8fbff;padding:5px;min-width:0}.mail-port label,.dnsbl label{display:block;font-size:8px;color:#6d83a1}.mail-port strong{display:block;font-size:9.5px;margin-top:3px;white-space:nowrap}.mail-port small{display:block;color:#8091a9;font-size:7.5px;margin-top:1px}.dnsbl-values{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:3px;margin-top:3px}.dnsbl-values span{font-size:7.5px;color:#7184a2;white-space:nowrap}.dnsbl-values b{font-size:9px;color:#244f86;margin-left:2px}.mail-provider-title{padding:1px 5px 3px;font-size:8.5px;font-weight:900;color:#34577f;display:flex;justify-content:space-between;gap:5px}.mail-provider-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:3px;padding:0 5px 4px}.mail-provider{border:1px solid #e2eef9;border-radius:4px;padding:3px 2px;text-align:center;min-width:0;background:#fff}.mail-provider .provider-name{font-size:7.5px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#37577e}.mail-provider .provider-state{display:block;font-size:7px;font-weight:900;white-space:nowrap;margin-top:2px}.provider-state.good{color:#0b8a4a}.provider-state.warn{color:#c77900}.provider-state.bad{color:#d11c3e}.provider-state.pending{color:#7186a2}.provider-state.error{color:#6b37bd}
.footer-note{font-size:8px;color:#6f85a3;display:flex;justify-content:space-between;gap:8px;padding:0 2px 2px}.footer-note b{color:#31547f}
/* zoom-aware desktop fit */
@media (min-width:1280px) and (max-height:850px){.topbar{height:55px;padding:5px 12px}.brand{flex-basis:230px;min-width:210px}.brand-cube{width:34px;height:34px}.brand-title{font-size:23px}.brand-sub{font-size:10px}.server-name{font-size:14px}.server-meta{font-size:8.7px;margin-top:2px}.head-btn{padding:5px 7px}.dashboard{padding:5px 8px 4px;gap:5px}.top-grid{gap:5px}.section-head{height:24px}.section-title{font-size:11.5px}.score-body{padding:4px 6px 5px}.score-hero{height:81px}.gauge{height:45px;width:103px}.gauge-number{font-size:22px}.score-bars{gap:4px}.spec{padding:5px 3px}.benchmark{padding:5px 5px;gap:4px}.bench-metric{padding:4px 5px}.international .section-head{height:22px}.intl-grid{padding:4px 5px 5px;gap:3px}.intl-item{padding:4px 3px}.intl-name{font-size:7.8px}.intl-speeds{margin-top:4px}.route-grid{gap:4px}.route-body{padding:3px 4px 0;gap:4px}.route-card .section-head{height:23px}.route-card .route-count{font-size:16px}.donut{width:33px;height:33px}.donut:after{inset:6px}.route-note{font-size:7.6px;padding:3px;margin-top:3px}.packet-table td{height:15px}.bottom-grid{gap:4px}.bottom-grid .section-head{height:23px}.risk-columns{padding:4px 4px;gap:3px}.risk-line{padding:3px 4px;min-height:16px;font-size:7.8px}.risk-line b{font-size:7.8px}.risk-head{padding:3px 4px;font-size:8.8px}.unlock-grid{padding:4px 4px 3px;gap:3px}.unlock-group h3{padding:4px 4px}.unlock-row{padding:3px 3px;min-height:16px}.service-name{font-size:7.7px}.service-icon{width:11px;height:11px}.unlock-state{font-size:7px}.mail-core{padding:4px 4px;gap:3px}.mail-port,.dnsbl{padding:5px 4px}.mail-provider-grid{gap:2px;padding:0 4px 4px}.mail-provider{padding:3px 1px}.footer-note{font-size:7.5px}}

@media (min-width:1100px) and (max-width:1279px){.top-grid{grid-template-columns:1fr 1fr}.china-card{grid-column:1/-1}.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr))}.benchmark{grid-template-columns:130px 1fr 1fr}.bottom-grid{grid-template-columns:1fr 1.3fr 1fr}}
@media (max-width:1099px){.topbar{height:auto;min-height:56px;flex-wrap:wrap}.brand{flex-basis:210px;min-width:0}.brand-title{font-size:22px}.vdivider{display:none}.server-head{flex:1;min-width:150px}.head-actions{margin-left:auto}.top-grid{grid-template-columns:1fr 1fr}.china-card{grid-column:1/-1}.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr))}.benchmark{grid-template-columns:120px 1fr 1fr}.bottom-grid{grid-template-columns:1fr 1.3fr}.mail-card{grid-column:1/-1}.mail-provider-grid{grid-template-columns:repeat(6,minmax(0,1fr))}.footer-note{flex-wrap:wrap}}
@media (max-width:760px){.dashboard{padding:6px;gap:6px}.topbar{padding:9px;gap:8px}.brand{flex:1 1 100%;min-width:0}.brand-title{font-size:23px}.server-head{flex:1 1 100%;min-width:0}.head-actions{position:absolute;right:8px;top:8px}.head-btn{font-size:0;padding:7px}.head-btn svg{width:16px;height:16px}.server-meta{font-size:9px}.top-grid{grid-template-columns:1fr}.china-card{grid-column:auto}.benchmark{grid-template-columns:1fr}.bench-intro{border-right:0;border-bottom:1px solid #e1edf9;padding:4px}.bench-group{grid-template-columns:repeat(2,minmax(0,1fr))}.intl-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.route-grid{grid-template-columns:1fr}.route-body{grid-template-columns:minmax(0,.82fr) minmax(0,1.18fr)}.bottom-grid{grid-template-columns:1fr}.mail-card{grid-column:auto}.mail-provider-grid{grid-template-columns:repeat(4,minmax(0,1fr))}.legend{display:none}.tooltip{left:-15px;width:min(230px,80vw)}}
@media (max-width:420px){.intl-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.risk-columns{grid-template-columns:1fr}.unlock-grid{grid-template-columns:1fr}.mail-core{grid-template-columns:1fr}.mail-provider-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.route-body{grid-template-columns:1fr}.route-summary{min-height:85px}}
@media print{body{background:#fff}.topbar{print-color-adjust:exact;-webkit-print-color-adjust:exact}.dashboard{padding:4px}.card{box-shadow:none;break-inside:avoid}.head-actions,.case-select{display:none!important}.top-grid,.bottom-grid,.route-grid{gap:4px}}

/* Revised readable dashboard: benchmark is integrated into server information. */
html,body{font-size:12px}
.topbar{height:62px;padding:8px 16px;gap:14px}
.brand{flex-basis:270px;min-width:230px;gap:10px}
.brand-cube{width:43px;height:43px}
.brand-title{font-size:28px}
.brand-sub{font-size:12px}
.server-name{font-size:17px}
.server-meta{font-size:10px;margin-top:4px;gap:9px}
.head-btn{padding:8px 10px;font-size:10.5px}
.dashboard{max-width:2200px;padding:8px 12px 10px;gap:8px}
.top-grid{grid-template-columns:1fr 1.12fr 1.25fr;gap:8px}
.section-head{height:30px;padding:0 10px;gap:8px}
.section-icon{width:23px;height:23px}
.section-icon svg{width:15px;height:15px}
.section-title{font-size:13.5px}
.help{width:16px;height:16px;font-size:10px}
.tooltip{width:260px;font-size:10.5px;padding:9px 11px;z-index:500}
.score-card{display:flex;flex-direction:column}
.score-card .section-head{flex:0 0 30px}
.score-body{flex:1;grid-template-columns:36% minmax(0,1fr);gap:7px;padding:7px 9px 9px;align-items:stretch}
.score-hero{height:100%;min-height:130px}
.gauge{width:135px;height:61px}
.gauge-number{font-size:28px}
.gauge-number small{font-size:13px}
.score-caption{font-size:11px;padding:4px 8px;margin-top:4px}
.score-bars{justify-content:space-evenly;gap:8px;padding:4px 4px 4px 6px}
.bar-row{grid-template-columns:15px 52px minmax(30px,1fr) 43px;gap:5px;font-size:10.5px}
.bar-track{height:8px}
.bar-value{font-size:10.5px}
.spec-grid{padding:5px 7px 5px}
.spec{padding:7px 6px;gap:6px;min-height:37px}
.spec-icon{width:23px;height:23px}
.spec-value{font-size:11.5px;gap:5px}
.spec-label{font-size:9.5px;margin-top:2px}
.spec-main-value{overflow:hidden;text-overflow:ellipsis;min-width:0}
.spec-copy{flex:1;min-width:0}
.cpu-info{position:relative;display:inline-flex;align-items:center;flex:0 0 auto;z-index:150}
.cpu-info-btn{width:16px;height:16px;font-size:9px;flex:0 0 auto}
.cpu-info-tip{display:none;position:absolute;top:calc(100% + 8px);left:-4px;width:300px;max-width:min(300px,calc(100vw - 28px));padding:10px 11px;background:#fff;border:1px solid #bdd8f5;border-radius:9px;box-shadow:0 12px 32px #102f6940;z-index:999;color:#2c4d7b;font-size:10px;line-height:1.45;white-space:normal;font-weight:500;pointer-events:auto}
.cpu-info-tip b{display:block;color:#0c3976;margin-bottom:4px;font-size:11px}
.cpu-tip-intro{display:block;color:#6c82a1;margin-bottom:6px}
.cpu-flag-grid{display:grid;grid-template-columns:1fr 1fr;gap:4px}
.cpu-flag-row{display:flex;align-items:center;justify-content:space-between;gap:5px;padding:4px 5px;border:1px solid #e1edf9;background:#f8fbff;border-radius:5px;min-width:0}
.cpu-flag-row>span{min-width:0}.cpu-flag-row b{display:block;font-size:9.5px;color:#294b79}.cpu-flag-row small{display:block;font-size:8px;color:#7c90aa}.cpu-flag-row em{font-style:normal;font-size:8px;font-weight:900;white-space:nowrap;padding:2px 4px;border-radius:4px}
.cpu-flag-row em.supported{background:#e0f7e9;color:#078246}.cpu-flag-row em.unsupported{background:#ffe3e8;color:#cc1d3e}.cpu-flag-row em.pending{background:#fff0cb;color:#b76c00}.cpu-flag-row em.failed{background:#f1eaff;color:#6735b9}
.cpu-tip-note{display:block;font-style:normal;background:#fff4d7;color:#956100;border-radius:5px;padding:6px;margin-top:6px;font-size:9px}
.cpu-info:hover .cpu-info-tip,.cpu-info:focus-within .cpu-info-tip,.cpu-info.open .cpu-info-tip{display:block}
.server-benchmark{border-top:1px solid #e2edf9;margin:1px 7px 5px;padding:3px 0 0}
.server-benchmark-head{display:flex;align-items:center;justify-content:space-between;gap:6px;margin:0 0 3px;font-size:10.5px;font-weight:900;color:#234b80}
.server-benchmark-head small{font-size:9px;font-weight:600;color:#7b8eaa}
.server-benchmark-groups{display:grid;grid-template-columns:1fr 1.2fr;gap:7px}
.server-benchmark-group{min-width:0;border:1px solid #e2edf9;background:#fbfdff;border-radius:6px;padding:4px}
.server-benchmark-label{font-size:9px;font-weight:850;color:#6680a2;margin:0 0 3px 1px}
.bench-group{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:4px;min-width:0}
.bench-metric{padding:3px 4px;background:#f2f8ff;border:1px solid #dfebf8;border-radius:5px;min-width:0}
.bench-metric label{font-size:8.5px;line-height:1.2;color:#6a82a3;display:block;white-space:normal;min-height:20px}
.bench-metric strong{font-size:11px;display:block;color:#164d93;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bench-metric strong.pending{color:#c47a00}
.bench-metric small{font-size:8px;color:#7b8eaa;font-weight:600}
.data-table{font-size:10px}
.data-table th,.data-table td{padding:5px 4px}
.carrier{font-size:9.7px;gap:5px}
.carrier-logo{width:21px;height:21px}
.route-name{font-size:9px;padding:4px 5px}
.international .section-head{height:29px}
.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr));gap:5px;padding:6px 8px 8px}
.intl-item{padding:6px 6px 5px}
.intl-top{gap:4px}
.flag{width:18px;height:12px}
.apple-flag{width:17px;height:17px}
.apple-flag svg{width:16px;height:16px}
.intl-name{font-size:9.4px}
.intl-state{font-size:8px;padding:2px 4px}
.intl-speeds{gap:4px;margin-top:6px}
.intl-speed{font-size:10.2px}
.intl-bottom{font-size:8.5px;margin-top:4px;padding-top:4px;gap:4px}
.route-grid{gap:8px}
.route-card{padding-bottom:6px}
.route-card .section-head{height:30px}
.route-card .section-title{font-size:13px}
.route-body{gap:7px;padding:6px 8px 0;grid-template-columns:minmax(0,.82fr) minmax(0,1.18fr)}
.route-summary{padding:7px}
.route-summary-top{gap:9px}
.donut{width:43px;height:43px}
.donut:after{inset:8px}
.route-count{font-size:20px}
.route-count small{font-size:11px}
.route-main-label{font-size:9.5px}
.route-progress{font-size:8.8px;margin-top:6px}
.route-note{font-size:9px;line-height:1.3;padding:5px 6px;min-height:30px;margin-top:5px}
.packet-table table{font-size:9.3px}
.packet-table th,.packet-table td{padding:4px 3px}
.packet-table td{height:20px}
.packet-table .cell{font-size:8.5px;padding:3px 4px;min-width:34px}
.bottom-grid{gap:8px}
.bottom-grid .section-head{height:30px}
.risk-columns{gap:5px;padding:6px 7px}
.risk-head{padding:5px 6px;font-size:10px}
.risk-grade{font-size:8.8px;padding:3px 5px}
.risk-line{padding:4px 6px;font-size:9.5px;min-height:19px;gap:5px}
.risk-line b{font-size:9.2px}
.risk-meta{padding:0 5px 5px}
.risk-meta .risk-line{min-height:18px}
.unlock-grid{gap:5px;padding:6px 7px 4px}
.unlock-group h3{font-size:9.5px;padding:5px 6px}
.unlock-count{font-size:8.5px}
.unlock-row{padding:4px 5px;min-height:19px;gap:4px}
.service-name{font-size:9px;gap:5px}
.service-icon{width:15px;height:15px;font-size:9px}
.unlock-state{font-size:8.3px;padding:3px 4px}
.unlock-loc{font-size:8.4px;max-width:50px}
.unlock-foot{font-size:8.3px;padding:0 7px 5px}
.mail-core{gap:5px;padding:6px 7px}
.mail-port,.dnsbl{padding:6px}
.mail-port label,.dnsbl label{font-size:8.8px}
.mail-port strong{font-size:10px}
.mail-port small{font-size:8px}
.dnsbl-values span{font-size:8px}
.dnsbl-values b{font-size:9.5px}
.mail-provider-title{padding:2px 7px 4px;font-size:9px}
.mail-provider-grid{gap:4px;padding:0 7px 6px}
.mail-provider{padding:4px 3px}
.mail-provider .provider-name{font-size:8.4px}
.mail-provider .provider-state{font-size:8px}
.footer-note{font-size:9px;padding:1px 3px 3px}
/* At 110% browser zoom, preserve readable type and trim only vertical whitespace. */
@media (min-width:1280px) and (max-height:850px){
 .topbar{height:58px;padding:6px 12px}.dashboard{padding:5px 9px 6px;gap:5px}.top-grid{gap:5px}.section-head{height:28px}.section-title{font-size:13px}.score-body{padding:5px 7px 6px}.score-hero{min-height:112px}.gauge{width:124px;height:55px}.score-bars{gap:6px}.spec{padding:5px 4px;min-height:33px}.server-benchmark{margin-bottom:5px;padding-top:4px}.server-benchmark-groups{gap:5px}.bench-metric{padding:4px}.bench-metric label{font-size:8px;min-height:18px}.bench-metric strong{font-size:10.5px}.intl-grid{padding:4px 6px 6px;gap:4px}.intl-item{padding:4px 4px 3px}.intl-name{font-size:8.8px}.intl-speed{font-size:9.6px}.intl-bottom{font-size:8px}.route-grid,.bottom-grid{gap:5px}.route-body{padding:4px 6px 0;gap:5px}.route-note{font-size:8.5px;min-height:26px;padding:4px 5px}.packet-table td{height:18px}.risk-columns{padding:4px 5px;gap:4px}.risk-line{font-size:8.8px;min-height:17px;padding:3px 5px}.risk-line b{font-size:8.5px}.risk-head{padding:4px 5px;font-size:9.5px}.unlock-grid{padding:4px 5px 3px;gap:4px}.unlock-row{padding:3px 4px;min-height:17px}.service-name{font-size:8.3px}.service-icon{width:13px;height:13px}.unlock-state{font-size:7.7px}.unlock-loc{font-size:7.7px;max-width:43px}.mail-core{padding:4px 5px;gap:3px}.mail-port,.dnsbl{padding:4px}.mail-provider-grid{gap:3px;padding:0 5px 4px}.mail-provider .provider-name{font-size:7.8px}.mail-provider .provider-state{font-size:7.5px}.footer-note{font-size:8px}
}
@media (min-width:1100px) and (max-width:1279px){.top-grid{grid-template-columns:1fr 1fr}.china-card{grid-column:1/-1}.server-benchmark-groups{grid-template-columns:1fr 1.15fr}.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr))}.bottom-grid{grid-template-columns:1fr 1.3fr 1fr}}
@media (max-width:1099px){.topbar{height:auto;min-height:58px;flex-wrap:wrap}.brand{flex-basis:210px;min-width:0}.brand-title{font-size:23px}.vdivider{display:none}.server-head{flex:1;min-width:150px}.head-actions{margin-left:auto}.top-grid{grid-template-columns:1fr 1fr}.china-card{grid-column:1/-1}.server-benchmark-groups{grid-template-columns:1fr 1fr}.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr))}.bottom-grid{grid-template-columns:1fr 1.3fr}.mail-card{grid-column:1/-1}.mail-provider-grid{grid-template-columns:repeat(6,minmax(0,1fr))}}
@media (max-width:760px){.dashboard{padding:6px;gap:6px}.topbar{padding:9px;gap:8px}.brand{flex:1 1 100%;min-width:0}.brand-title{font-size:23px}.server-head{flex:1 1 100%;min-width:0}.head-actions{position:absolute;right:8px;top:8px}.head-btn{font-size:0;padding:7px}.head-btn svg{width:16px;height:16px}.server-meta{font-size:9px}.top-grid{grid-template-columns:1fr}.china-card{grid-column:auto}.score-body{grid-template-columns:38% minmax(0,1fr)}.server-benchmark-groups{grid-template-columns:1fr}.intl-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.route-grid{grid-template-columns:1fr}.route-body{grid-template-columns:minmax(0,.82fr) minmax(0,1.18fr)}.bottom-grid{grid-template-columns:1fr}.mail-card{grid-column:auto}.mail-provider-grid{grid-template-columns:repeat(4,minmax(0,1fr))}.legend{display:none}.tooltip{left:-15px;width:min(230px,80vw)}.cpu-info-tip{left:-20px;width:min(290px,calc(100vw - 24px))}}
@media (max-width:420px){.intl-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.risk-columns{grid-template-columns:1fr}.unlock-grid{grid-template-columns:1fr}.mail-core{grid-template-columns:1fr}.mail-provider-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.route-body{grid-template-columns:1fr}.route-summary{min-height:85px}.score-body{grid-template-columns:1fr}.score-hero{min-height:100px}.score-bars{gap:6px}}
@media print{body{background:#fff}.topbar{print-color-adjust:exact;-webkit-print-color-adjust:exact}.dashboard{padding:4px;gap:4px}.card{box-shadow:none;break-inside:avoid}.head-actions,.case-select{display:none!important}.top-grid,.bottom-grid,.route-grid{gap:4px}}


/* Final refinements: larger metrics, CPU+disk scores inside specs, and filled score layout. */
.score-body{grid-template-columns:minmax(150px,36%) minmax(0,1fr);align-items:stretch}
.score-left-stack{display:flex;flex-direction:column;gap:6px;min-width:0;min-height:0}
.score-hero{flex:1;min-height:125px;height:auto;justify-content:center}
.gauge{width:146px;height:68px;max-width:100%}
.gauge-number{font-size:30px}
.score-extra{display:grid;grid-template-columns:1fr 1fr;gap:5px}
.score-extra>div{display:flex;align-items:center;justify-content:space-between;gap:5px;padding:5px 6px;border:1px solid #e0ecf8;border-radius:6px;background:#f7fbff;min-width:0}
.score-extra span{font-size:9px;color:#6b82a3;white-space:nowrap}
.score-extra b{font-size:9px;color:#315980;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.server-benchmark{border-top:1px solid #e2edf9;margin:1px 7px 5px;padding:3px 0 0}
.server-benchmark-head{display:flex;align-items:center;justify-content:space-between;gap:6px;margin:0 0 3px;font-size:10.5px;font-weight:900;color:#234b80}
.server-benchmark-head small{font-size:9px;font-weight:600;color:#7b8eaa}
.server-benchmark-metrics{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px}
.bench-metric{padding:5px 6px;background:#f2f8ff;border:1px solid #dfebf8;border-radius:5px;min-width:0}
.bench-metric label{font-size:8.8px;line-height:1.2;color:#6a82a3;display:block;white-space:normal;min-height:12px}
.bench-metric strong{font-size:11.2px;display:block;color:#164d93;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bench-metric strong.pending{color:#c47a00}
.bench-metric small{font-size:8px;color:#7b8eaa;font-weight:600}
@media (min-width:1280px) and (max-height:850px){
 .score-body{padding:5px 7px 6px}.score-hero{min-height:105px}.gauge{width:132px;height:60px}.gauge-number{font-size:28px}.score-extra>div{padding:4px 5px}.server-benchmark{margin-bottom:5px;padding-top:4px}.server-benchmark-head{margin-bottom:4px}.server-benchmark-metrics{gap:3px}.bench-metric{padding:4px 5px}.bench-metric label{font-size:8.2px;min-height:11px}.bench-metric strong{font-size:10.3px;margin-top:2px}
}
@media (max-width:1099px){.score-body{grid-template-columns:minmax(140px,36%) minmax(0,1fr)}.server-benchmark-metrics{grid-template-columns:repeat(3,minmax(0,1fr))}}
@media (max-width:760px){.score-body{grid-template-columns:1fr}.score-left-stack{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,.85fr);align-items:stretch}.score-hero{min-height:110px}.score-extra{grid-template-columns:1fr;align-content:center}.server-benchmark-metrics{grid-template-columns:repeat(2,minmax(0,1fr))}}


/* Compact by spacing rather than shrinking text; fit common 110% desktop viewport. */
.topbar{height:60px;padding:7px 14px}
.dashboard{padding:6px 10px 6px;gap:6px}
.score-extra{grid-template-columns:1fr;gap:4px}
.score-extra>div{padding:4px 6px}
.server-benchmark-head{margin-bottom:4px}
.server-benchmark-metrics{gap:4px}
@media (min-width:1280px) and (max-height:850px){
 .topbar{height:52px;padding:4px 10px}
 .dashboard{padding:4px 8px 4px;gap:5px}
 .top-grid{gap:4px}
 .section-head{height:27px}
 .score-card .section-head{height:27px}
 .route-card .section-head,.bottom-grid .section-head{height:27px}
 .score-body{padding:4px 6px 5px}
 .score-hero{min-height:100px}
 .gauge{width:125px;height:56px}
 .score-extra>div{padding:3px 5px}
 .server-benchmark{margin-bottom:4px;padding-top:3px}
 .bench-metric{padding:3px 4px}
 .bench-metric label{font-size:8.2px;min-height:10px}
 .bench-metric strong{font-size:10px;margin-top:2px}
 .intl-grid{padding:4px 5px 5px;gap:4px}
 .intl-item{padding:3px 4px}
 .intl-speeds{margin-top:4px}
 .intl-bottom{margin-top:3px;padding-top:3px}
 .route-grid,.bottom-grid{gap:4px}
 .route-body{padding:4px 5px 0;gap:4px}
 .route-note{font-size:8.3px;min-height:24px;padding:4px 4px;margin-top:3px}
 .packet-table th,.packet-table td{padding:3px 2px}
 .packet-table td{height:18px}
 .risk-columns{padding:4px 5px;gap:4px}
 .risk-line{padding:3px 4px;min-height:16px}
 .risk-head{padding:4px 4px}
 .risk-meta .risk-line{min-height:16px}
 .unlock-grid{padding:4px 5px 3px;gap:4px}
 .unlock-row{padding:3px 4px;min-height:16px}
 .unlock-group h3{padding:4px 4px}
 .mail-core{padding:4px 5px;gap:4px}
 .mail-port,.dnsbl{padding:4px}
 .mail-provider-title{padding:2px 5px 3px}
 .mail-provider-grid{padding:0 5px 4px;gap:3px}
 .mail-provider{padding:3px 2px}
 .footer-note{font-size:8px;padding:0 2px}
}


/* Carrier-specific IPv4/IPv6 route averages and compact protocol rows. */
.china-table{table-layout:auto;font-size:9px}.china-table th,.china-table td{padding:2px 3px}.china-table tbody tr.ipv6-row td{background:#fbfdff}.china-table tbody tr.carrier-divider td{border-top:2px solid #d9e9f9}.protocol-tag{display:inline-flex;align-items:center;justify-content:center;min-width:32px;padding:2px 4px;border-radius:4px;font-size:8px;font-weight:900}.protocol-tag.v4{background:#e8f2ff;color:#1767c4}.protocol-tag.v6{background:#f0eaff;color:#7142bd}.route-name.muted-route{background:#f0f4f8;color:#7589a3}.packet-table table{table-layout:fixed}.packet-table th:first-child{width:44px}.carrier-avg{vertical-align:middle;white-space:normal!important;line-height:1.15;min-width:0}.carrier-avg .avg-main{display:flex;justify-content:center;gap:3px;align-items:baseline;white-space:nowrap;font-weight:850}.carrier-avg .avg-main b{font-size:8.8px}.carrier-avg .avg-sub{font-size:7.8px;margin-top:2px;white-space:nowrap}.carrier-avg.good{background:#f1fbf5;color:#07864a}.carrier-avg.warn{background:#fff9eb;color:#b66c00}.carrier-avg.bad{background:#fff2f3;color:#c41638}.carrier-avg.pending{background:#f6f9fc;color:#6b82a3}.carrier-avg.error{background:#f4efff;color:#6b37bd}.carrier-col-head{display:flex;align-items:center;justify-content:center;gap:4px;white-space:nowrap}.carrier-col-head .carrier-logo{width:14px;height:14px}.carrier-col-head .carrier-logo svg{width:14px;height:14px}.packet-table .matrix-note{font-size:7.5px;color:#7187a5;padding:3px 2px 0;line-height:1.25;white-space:normal}


/* HostQoS 扩展:AI 厂家图标 / 长度约束 / 本地附加 */
.service-icon svg{width:11px;height:11px;display:block}
.service-icon.ai-openai{background:#0d0d0d}
.service-icon.ai-claude{background:#cc785c}
.service-icon.ai-gemini{background:#1a73e8}
.service-icon.ai-perplexity{background:#20808d}
.service-icon.ai-copilot{background:#0f6cbd}
.service-icon.ai-grok{background:#111}
.route-name{max-width:96px;overflow:hidden;text-overflow:ellipsis;vertical-align:bottom;display:inline-block}
.risk-line b{max-width:118px;overflow:hidden;text-overflow:ellipsis;display:inline-block;vertical-align:bottom}
.spec-value .spec-sub{font-size:8.5px;color:#6b82a3;font-weight:600}
.na{color:#8ba0bd;font-weight:500}
a.head-btn{color:#fff;text-decoration:none}


/* v2.3 高度再平衡:压缩上排三卡,扩展国际/回程,保持一屏 */
.score-body{grid-template-columns:minmax(140px,34%) minmax(0,1fr);padding:5px 7px 6px;gap:6px}
.score-hero{min-height:88px}
.gauge{width:112px;height:50px}
.gauge-number{font-size:25px}
.score-caption{font-size:10px;padding:3px 8px;margin-top:3px}
.score-bars{gap:5px;padding:2px 2px 2px 4px}
.bar-row{margin:0}
.score-extra>div{padding:3px 5px}
.spec{padding:4px 5px;min-height:30px;gap:5px}
.spec-icon{width:19px;height:19px}
.spec-value{font-size:10.5px}
.spec-label{font-size:8px;margin-top:1px}
.server-benchmark{margin:1px 5px 5px;padding-top:3px}
.server-benchmark-head{margin-bottom:3px;font-size:9.5px}
.bench-metric{padding:3px 4px}
.bench-metric label{font-size:8px;min-height:0}
.bench-metric strong{font-size:10px;margin-top:1px}
.china-table th,.china-table td{padding:2.5px 3px}
.international .section-head{height:27px}
.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr));gap:5px;padding:6px 8px 8px}
.intl-item{padding:8px 8px 6px}
.intl-speeds{gap:5px;margin-top:7px}
.intl-speed{font-size:11px}
.intl-bottom{font-size:8.8px;margin-top:6px;padding-top:5px;gap:6px}
.intl-state{font-size:8.4px;padding:2px 4px}
.route-grid{gap:6px}
.route-card .section-head{height:28px}
.route-body{grid-template-columns:minmax(0,.82fr) minmax(0,1.18fr);gap:6px;padding:5px 6px 0}
.route-summary{padding:6px}
.donut{width:40px;height:40px}
.route-count{font-size:18px}
.route-note{font-size:8.8px;line-height:1.35;padding:5px 6px;min-height:34px;margin-top:4px}
.packet-table table{font-size:9.6px}
.packet-table th,.packet-table td{padding:4.5px 3px}
.packet-table td{height:30px}
.packet-table .cell{font-size:8.6px}
/* v2.3 一屏三级高度:默认(高≥990) / 中间(≤980) / 紧凑(≤850) */
.topbar{height:52px}
.dashboard{padding:5px 10px 5px;gap:5px}
.china-table th,.china-table td{padding:2px 3px}
.route-note{min-height:30px}
.packet-table td{height:28px}
.risk-line{min-height:16px;padding:2px 4px}
.unlock-row{min-height:16px;padding:2px 3px}
.unlock-group h3{padding:3px 4px}
@media (min-width:1280px) and (max-height:980px){
 .topbar{height:50px;padding:5px 12px}
 .section-head{height:25px}.section-title{font-size:12px}
 .score-hero{min-height:78px}.gauge{width:108px;height:48px}.gauge-number{font-size:24px}
 .spec{padding:3px 4px;min-height:26px}
 .server-benchmark{margin:1px 4px 4px;padding-top:2px}
 .china-table th,.china-table td{padding:1.5px 3px}
 .international .section-head{height:25px}
 .intl-grid{gap:4px;padding:5px 6px 6px}
 .intl-item{padding:6px 6px 5px}
 .intl-speeds{margin-top:5px;gap:4px}
 .intl-bottom{margin-top:4px;padding-top:4px}
 .route-card .section-head{height:25px}
 .route-note{font-size:8.3px;min-height:24px;padding:4px 5px;margin-top:3px}
 .packet-table th,.packet-table td{padding:3px 3px}
 .packet-table td{height:24px}
 .risk-line{min-height:15px;font-size:8.5px;padding:2px 4px}
 .unlock-row{min-height:15px;padding:2px 3px}
 .footer-note{font-size:7.8px}
}
@media (min-width:1280px) and (max-height:850px){
 .topbar{height:47px;padding:4px 12px}
 .brand{flex-basis:225px;min-width:205px}.brand-cube{width:32px;height:32px}
 .brand-title{font-size:21px}.brand-sub{font-size:9.5px}
 .server-name{font-size:13px}.server-meta{font-size:8.4px;margin-top:1px}
 .head-btn{padding:4px 6px;font-size:9px}
 .dashboard{padding:4px 8px 4px;gap:4px}
 .section-head{height:22px}.section-title{font-size:10.5px}
 .section-icon{width:17px;height:17px}.section-icon svg{width:12px;height:12px}
 .score-body{padding:3px 6px 4px;gap:4px}
 .score-hero{min-height:66px}.gauge{width:96px;height:42px}.gauge-number{font-size:21px}
 .score-caption{font-size:9px;padding:2px 6px}
 .score-bars{gap:3px}
 .spec{padding:2px 3px;min-height:22px;gap:4px}
 .spec-icon{width:16px;height:16px}
 .spec-value{font-size:9.5px}.spec-label{font-size:7.5px}
 .server-benchmark{margin:1px 4px 4px;padding-top:2px}
 .server-benchmark-head{margin-bottom:2px;font-size:9px}
 .bench-metric{padding:2px 3px}
 .china-table th,.china-table td{padding:1.2px 2px;font-size:8.4px}
 .protocol-tag{font-size:7px;padding:1px 3px}
 .international .section-head{height:21px}
 .intl-grid{gap:3px;padding:4px 5px 5px}
 .intl-item{padding:4px 4px 3px}
 .intl-name{font-size:7.8px}
 .intl-speeds{margin-top:3px;gap:4px}.intl-speed{font-size:9.5px}
 .intl-bottom{font-size:7.6px;margin-top:3px;padding-top:3px;gap:4px}
 .route-card .section-head{height:21px}
 .route-body{padding:3px 5px 0;gap:4px}
 .route-summary{padding:4px 5px}
 .donut{width:30px;height:30px}.donut:after{inset:6px}
 .route-count{font-size:15px}
 .route-note{font-size:7.4px;min-height:16px;padding:2px 3px;margin-top:2px}
 .packet-table table{font-size:8.2px}
 .packet-table th,.packet-table td{padding:1.5px 2px}
 .packet-table td{height:14px}
 .packet-table .cell{font-size:7.2px}
 .matrix-note{font-size:6.8px;padding:2px 3px}
 .risk-line{min-height:13.5px;font-size:7.4px;padding:1.5px 3px}
 .risk-line b{font-size:7.4px}
 .risk-head{padding:2px 3px;font-size:8px}
 .risk-columns{padding:3px 3px;gap:2px}
 .unlock-grid{padding:3px 3px 2px;gap:2px}
 .unlock-group h3{padding:2px 3px;font-size:8.2px}
 .unlock-row{min-height:13.5px;padding:1.5px 2px}
 .service-name{font-size:7.2px}.service-icon{width:11px;height:11px}
 .unlock-state{font-size:6.8px}.unlock-loc{font-size:6.8px;max-width:40px}
 .mail-core{padding:3px 3px;gap:2px}
 .mail-port,.dnsbl{padding:3px 3px}
 .mail-provider-grid{gap:2px;padding:0 3px 3px}
 .mail-provider{padding:2px 1px}
 .footer-note{font-size:7px}
}

/* v2.3 一屏精调:单元格内字号/行高再压 */
@media (min-width:1280px) and (max-height:980px){
 .topbar{height:48px;padding:4px 12px}
 .section-head{height:24px}
 .china-table th,.china-table td{padding:1.2px 3px}
 .china-table .cell{padding:1px 3px;font-size:7.8px}
 .china-table tbody td{line-height:1.2}
 .intl-item{padding:5px 5px 4px}
 .route-note{min-height:22px}
 .packet-table td{height:20px}
 .packet-table .avg-main{font-size:9px}
 .packet-table .avg-sub{font-size:7px}
 .unlock-row{line-height:1.15;min-height:14px}
 .risk-line{line-height:1.15}
}
@media (min-width:1280px) and (max-height:850px){
 .topbar{height:45px;padding:3px 12px}
 .top-grid{gap:4px}
 .route-grid,.bottom-grid{gap:4px}
 .china-table th,.china-table td{padding:1px 2px;font-size:8.2px}
 .china-table .cell{padding:1px 3px;font-size:7.4px}
 .china-table tbody td{line-height:1.15}
 .intl-grid{padding:3px 4px 4px}
 .intl-item{padding:3px 3px 2px}
 .intl-speed{font-size:9px}
 .intl-item .intl-top{gap:2px}
 .packet-table td{height:13px}
 .packet-table .avg-main{font-size:8.5px}
 .packet-table .avg-main i{font-size:6.5px}
 .packet-table .avg-sub{font-size:6.5px}
 .unlock-row{line-height:1.1;min-height:13px;padding:1px 2px}
 .risk-line{line-height:1.1}
 .mail-provider .provider-name{font-size:7px}
 .mail-provider .provider-state{font-size:6.8px}
}

/* v2.3 一屏精调 2:表格行高/图标尺寸下限 */
@media (min-width:1280px) and (max-height:980px){
 .dashboard{gap:4px}
 .china-table td{height:19px}
 .packet-table td{height:19px}
 .unlock-row{min-height:13.5px}
}
@media (min-width:1280px) and (max-height:850px){
 .carrier{gap:2px}
 .carrier-logo{width:11px;height:11px}
 .carrier-logo svg{width:11px;height:11px}
 .china-table td{height:17px}
 .intl-item .flag{width:12px;height:12px}
 .intl-item .flag svg{width:12px;height:12px}
 .intl-speeds{margin-top:2px}
 .packet-table td{height:18px;padding:1px 2px}
 .packet-table .avg-main{font-size:8px;line-height:1.05}
 .packet-table .avg-sub{font-size:6.2px;line-height:1.05}
 .unlock-row{padding:1px 2px}
 .unlock-state{padding:1px 2px}
}

/* v2.3 一屏精调 3:表头行高(双类特异性)/两行 th/跑分与包表再压 */
@media (min-width:1280px) and (max-height:980px){
 .score-card .section-head,.spec-card .section-head,.china-card .section-head,
 .risk-card .section-head,.unlock-card .section-head,.mail-card .section-head{height:22px}
 .china-table th br{display:none}
 .risk-line{min-height:13px}
 .unlock-row{padding:1px 3px}
 .mail-provider{padding:2px 2px}
}
@media (min-width:1280px) and (max-height:850px){
 .score-card .section-head,.spec-card .section-head,.china-card .section-head,
 .risk-card .section-head,.unlock-card .section-head,.mail-card .section-head{height:20px}
 .china-table th br{display:none}
 .china-table th{padding:0 2px;line-height:1.1}
 .china-table td{padding:0 2px;line-height:1.05}
 .china-table .cell{padding:0 2px;line-height:1.1}
 .china-table .protocol-tag{padding:0 2px;line-height:1.1}
 .bench-metric{padding:1px 2px}
 .bench-metric strong{font-size:9px}
 .bench-metric small{font-size:6px}
 .server-benchmark{padding-top:1px;margin:0 4px 3px}
 .packet-table td{padding:0 2px}
 .packet-table .avg-main{font-size:7.5px;line-height:1}
 .packet-table .avg-sub{font-size:6px;line-height:1}
 .risk-columns{gap:1px;padding:2px 3px}
 .mail-provider{padding:1px 2px}
 .mail-provider-grid{gap:1px}
 .unlock-foot{font-size:7px;padding:2px 3px}
}

/* v2.3.1 国际测速:12 节点 6 列两行 + 速率单位标注 */
.intl-grid{grid-template-columns:repeat(6,minmax(0,1fr))}
.intl-speed small{font-size:7px;font-weight:600;color:#6b82a3;margin-left:1px}

/* v2.6:风险面板 IP 类型/使用类型徽章 + 黑名单数据库四色块 + 品牌 Logo 首页链接 */
.ntv,.utg{display:inline-block;padding:1px 7px;border-radius:4px;font-weight:800;font-size:8.5px;color:#fff;line-height:1.5}
.ntv-native,.utg-res{background:#159c59}
.ntv-bcast,.utg-idc{background:#dc2345}
.utg-biz{background:#e58a05}
.utg-mob{background:#0e9aa7}
.utg-edu,.utg-gov,.utg-bank{background:#2f6fd6}
.utg-cdn{background:#6b82a3}
.bl-nums{display:inline-flex;gap:3px;flex-wrap:wrap;justify-content:flex-end}
.bl-nums i{font-style:normal;font-size:8px;display:inline-flex;align-items:center;gap:2px;border-radius:4px;padding:1px 5px;color:#fff;white-space:nowrap}
.bl-nums i b{font-size:9px}
.bl-nums i.b1{background:#2f6fd6}
.bl-nums i.b2{background:#159c59}
.bl-nums i.b3{background:#e58a05}
.bl-nums i.b4{background:#dc2345}
a.brand{color:inherit;text-decoration:none;cursor:pointer}
a.brand:hover .brand-title{opacity:.85}
.dnsbl-values{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:3px;margin-top:3px}
.dnsbl-values .dv-v{color:#2f6fd6;font-weight:700}
.dnsbl-values .dv-c{color:#159c59;font-weight:700}
.dnsbl-values .dv-m{color:#e58a05;font-weight:700}
.dnsbl-values .dv-b{color:#dc2345;font-weight:700}
/* v2.7:CPU 特性徽章(嵌套虚拟化/AES-NI) + 超开指标 chips(气球回收/KSM 复用) */
.cpu-model{display:block;font-size:7.5px;line-height:1.2;font-weight:600;color:#5b7bb5;margin-top:0;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.feat-wrap{display:inline-flex;gap:2px;margin-left:4px;vertical-align:1px}
.feat{font-size:7.5px;font-weight:800;padding:1px 4px;border-radius:3px;line-height:1.4;white-space:nowrap}
.feat.ok{background:#e8f8ee;color:#0d7a44;border:1px solid #bfe8d0}
.feat.no{background:#fff0f2;color:#c71d3c;border:1px solid #ffd0d8}
.ovs-chips{display:flex;gap:3px;flex-wrap:wrap;min-height:14px;align-items:center}
.ovs{font-size:8px;font-weight:800;padding:1px 5px;border-radius:3px;background:#e8f8ee;color:#0d7a44;white-space:nowrap}
.ovs.hit{background:#dc2345;color:#fff}


/* v2.3.1 跑分条 4 列(7 指标两行,不再三行) */
.server-benchmark-metrics{grid-template-columns:repeat(4,minmax(0,1fr))}
.bench-metric strong{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bench-metric{padding:3px 4px}


/* v2.3.1 极紧凑档:728→720 收尾 */
@media (min-width:1280px) and (max-height:850px){
 .dashboard{gap:3px;padding:3px 8px 3px}
 .top-grid{gap:3px}
 .route-grid,.bottom-grid{gap:3px}
 .china-table th,.china-table td{padding:.8px 2px}
 .intl-grid{gap:2px;padding:3px 4px 4px}
 .unlock-row{padding:1px 2px;min-height:12.5px}
 .risk-line{padding:1px 3px;min-height:13px}
}


@media (min-width:1280px) and (max-height:850px){
 .footer-note{font-size:6.5px;padding:1px 2px}
 .topbar{height:44px}
 .china-table td{padding:.5px 2px}
 .packet-table .avg-main b{font-size:8px}
}


/* v2.3.2 仪表数字缩小一档 */
.gauge-number{font-size:19px}
.gauge-number small{font-size:10px}
@media (min-width:1280px) and (max-height:980px){
 .gauge-number{font-size:18px}
}
@media (min-width:1280px) and (max-height:850px){
 .gauge-number{font-size:16px}
 .gauge-number small{font-size:8.5px}
}


/* v2.3.3 三网运营商列居中 */
.china-table td:first-child,.china-table th:first-child{text-align:center}
.china-table .carrier{justify-content:center}


/* v2.3.4 评分缺失项占位与解锁区域 SVG 国旗 */
.bar-track.pending-track{background:transparent;border:1px dashed #d5e2ef}
.bar-fill.pending{width:100%!important;background:transparent;color:#8ba0bd;font-size:8px;text-align:center;line-height:7px;font-weight:700}
.unlock-flag{display:inline-flex;width:13px;height:9px;margin-right:3px;vertical-align:-1px;flex:0 0 auto}
.unlock-flag svg{width:100%;height:100%;border:1px solid #d1dfed;border-radius:1px;display:block}


/* v2.3.5 评分进度条修复:fill 需块级,百分比宽度才生效 */
.bar-fill{display:block}
.bar-track.pending-track{height:10px;display:flex;align-items:center;justify-content:center}
.bar-fill.pending{width:100%!important;line-height:1.1;font-size:7px;letter-spacing:1px}


/* v2.4.2 国际互联条:单行厂牌延迟,超出隐藏(主流在前) */
.intl-brand-strip{display:flex;gap:4px;padding:4px 8px 6px;overflow:hidden;white-space:nowrap;align-items:center}
.brand-chip{display:inline-flex;align-items:center;gap:3px;padding:2px 6px 2px 4px;border:1px solid #e0ebf7;border-radius:20px;background:#f7fbff;font-size:8.5px;font-weight:700;color:#2c4d7b;flex:0 0 auto}
.brand-chip svg{width:11px;height:11px;display:block}
.brand-chip i{font-style:normal}
.brand-chip b{font-weight:800;color:#0a6df2}
.brand-chip.warn b{color:#bb7200}
.brand-chip.bad b{color:#d51c3d}
.brand-chip.cdn{background:#f6f8fb;border-color:#e2e8f2}
@media (min-width:1280px) and (max-height:980px){.intl-brand-strip{padding:3px 6px 4px;gap:3px}.brand-chip{font-size:7.6px;padding:1px 5px 1px 3px}.brand-chip svg{width:9px;height:9px}}
@media (min-width:1280px) and (max-height:850px){.intl-brand-strip{padding:2px 5px 3px;gap:2px}.brand-chip{font-size:7px;padding:1px 4px 1px 3px}.brand-chip svg{width:8px;height:8px}}


/* v2.4.2 极紧凑:品牌条收纳 */
@media (min-width:1280px) and (max-height:850px){
 .intl-brand-strip{padding:1px 4px 2px;gap:2px}
 .brand-chip{font-size:6.4px;padding:1px 3px;border-width:.5px}
 .brand-chip b{font-size:6.4px}
 .intl-item{padding:2px 3px 2px}
 .intl-grid{padding:2px 4px 3px}
}


@media (min-width:1280px) and (max-height:850px){
 .topbar{height:43px}
 .china-table td{padding:.3px 2px}
 .packet-table .avg-main{font-size:7.5px}
}


/* v2.4.3 极紧凑:口径说明收纳 */
@media (min-width:1280px) and (max-height:850px){
 .route-note{font-size:6.6px;line-height:1.2;padding:2px 3px;min-height:0}
 .route-summary{padding:3px 4px}
 .route-progress{margin-top:2px}
 .intl-brand-strip{display:none}
 .intl-grid{padding:3px 5px 4px}
}


/* v2.4.4 解锁 v4/v6 徽章 */
.fam46{width:15px;height:9px;margin:0 2px;vertical-align:-1px;flex:0 0 auto}
.service-name{display:flex;align-items:center;gap:3px;min-width:0}


/* ===== v2.7.2 高度优化:顶三卡收紧 / 国际卡增高 / 单屏无滚动条(末位覆盖) ===== */
.topbar{height:50px}
.dashboard{gap:5px;padding:4px 10px 4px}
.section-head{height:24px}
.score-body{padding:2px 7px 3px;gap:4px}
.score-hero{height:74px;min-height:74px}
.gauge{height:45px}
.score-bars{gap:4px}
.spec{padding:2px 4px;min-height:26px}
.spec-icon{width:17px;height:17px}
.bench-metric{padding:2px 4px}
.server-benchmark{margin:1px 7px 4px;padding:2px 0 0}
.china-table th,.china-table td{padding:1.5px 3px}
.intl-grid{padding:8px 8px}
.intl-item{padding:8px 5px 7px}
.intl-speeds{margin-top:6px}
@media (min-width:1280px) and (max-height:980px){
 .topbar{height:48px}
 .section-head{height:22px}
 .score-hero{height:70px;min-height:70px}
 .gauge{height:42px}
 .china-table th,.china-table td{padding:1px 3px}
 .intl-grid{padding:4px 6px 5px}
 .intl-item{padding:4px 4px 3px}
 .intl-speeds{margin-top:4px}
 .risk-line{padding:2px 4px;min-height:15px}
 .route-note{font-size:7.4px;padding:2px;margin-top:2px}
}
@media (max-width:1099px){
 .intl-grid{padding:4px 6px 5px}
 .intl-item{padding:4px 4px 3px}
}

@media (min-width:1280px) and (max-height:850px){
 .topbar{height:44px;padding:3px 10px}
 .section-head{height:20px}
 .score-body{padding:1px 6px 2px}
 .score-hero{height:62px;min-height:62px}
 .gauge{height:38px}
 .spec{padding:1px 3px;min-height:22px}
 .spec-icon{width:15px;height:15px}
 .bench-metric{padding:1px 3px}
 .server-benchmark{margin:0 5px 3px;padding:1px 0 0}
 .china-table th,.china-table td{padding:.8px 2px}
 .intl-grid{padding:2px 5px 3px}
 .intl-item{padding:3px 3px 2px}
 .intl-speeds{margin-top:2px}
 .risk-line{padding:1px 3px;min-height:13px;font-size:7.6px}
 .route-note{font-size:7px;padding:1px;margin-top:1px}
 .donut{width:28px;height:28px}
 .packet-table td{height:13px}
 .unlock-row{min-height:11px;padding:1px 2px}
 .mail-provider{padding:1px 1px}
}

@media (min-width:1280px) and (max-height:850px){
 .section-head{height:19px}
 .score-hero{height:56px;min-height:56px}
 .gauge{height:35px}
 .score-caption{font-size:8.5px;padding:1px 6px;margin-top:1px}
 .route-summary{min-height:64px}
 .packet-table td{height:11px}
 .route-count{font-size:14px}
 .donut{width:25px;height:25px}
 .risk-line{min-height:12px}
 .bench-metric label{font-size:7.5px}
 .bench-metric strong{font-size:9px}
 .cpu-model{font-size:7px}
}

/* v2.8.1 移动端全面适配(末位覆盖,服务端同款) */
/* ===== 解锁状态图例圆点(全端生效;移动端状态文字也用同色圆点,见下) ===== */
.unlock-foot .lg-dot{display:inline-block;width:8px;height:8px;border-radius:50%;
margin:0 3px 0 2px;transform:translateY(.5px)}
.lg-dot.lg-g{background:#22a45d}
.lg-dot.lg-y{background:#f59e0b}
.lg-dot.lg-r{background:#dc2626}
.lg-dot.lg-v{background:#8b5cf6}
.lg-dot.lg-n{background:#c3cede}
/* ===== 移动端全面适配(末位覆盖) ===== */
@media (max-width:900px){
 html,body{font-size:12px}
 body{-webkit-text-size-adjust:100%}
 *{-webkit-tap-highlight-color:transparent}
 button,a,tr,.unlock-row{touch-action:manipulation}
 /* ---- 顶栏:品牌与"评测报告 #xx"同行(左右对齐),元信息次行,按钮第三行 ----
    .server-head 用 display:contents 拆成两个直接 flex 子项,分别定位到第 1/2 行 */
 .topbar{height:auto;min-height:0;flex-wrap:wrap;padding:8px 10px;gap:4px 10px;align-items:center}
 .brand{order:1;flex:1 1 auto;min-width:0;gap:8px}
 .brand-cube{width:32px;height:32px}
 .brand-title{font-size:19px}
 .brand-sub{font-size:10px;margin-top:1px}
 .vdivider{display:none}
 .server-head{display:contents}
 .server-name{order:2;flex:0 1 auto;min-width:0;max-width:58%;align-self:center;
 font-size:13px;font-weight:850;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-left:auto}
 .server-meta{order:3;flex:1 1 100%;min-width:0;font-size:10px;gap:6px;margin-top:2px}
 .server-meta i{margin:0 1px}
 .head-actions{order:4;position:static;flex:1 1 100%;flex-wrap:wrap;gap:6px;margin-left:-4px;margin-top:2px}
 .head-btn{font-size:11.5px;padding:8px 10px;border-radius:8px;min-height:36px}
 .head-btn svg{width:14px;height:14px}
 /* ---- 骨架:全部单列 ---- */
 .dashboard{padding:8px 8px 14px;gap:10px}
 .top-grid,.route-grid,.bottom-grid{grid-template-columns:1fr;gap:10px}
 .section-head{height:36px;padding:0 10px;gap:7px}
 .section-icon{width:22px;height:22px}
 .section-icon svg{width:14px;height:14px}
 .section-title{font-size:14px}
 .card{border-radius:11px}
 .help{width:19px;height:19px;font-size:11px}
 .pill{font-size:10px;padding:3px 8px}
 /* ? 帮助气泡:固定为底部浮层,避免出屏 */
 .tooltip{position:fixed;left:10px;right:10px;bottom:12px;top:auto;width:auto;z-index:600}
 /* ---- 评分卡 ---- */
 .score-body{grid-template-columns:1fr;gap:6px;padding:10px 10px 4px}
 .score-left-stack{grid-template-columns:1fr;gap:4px}
 .score-hero{height:auto;min-height:0}
 .gauge{width:150px;height:68px}
 .gauge svg{width:150px;height:68px}
 .gauge-number{font-size:26px}
 .score-caption{font-size:11.5px;padding:4px 14px;margin-top:6px}
 .score-extra{grid-template-columns:1fr;padding:4px 0 2px}
 .score-extra>div{padding:6px 10px;font-size:11px}
 .score-bars{gap:7px;padding:0 10px 10px}
 .bar-row{grid-template-columns:12px 58px minmax(0,1fr) 38px;gap:6px;font-size:11px}
 .bar-name{font-size:11px;white-space:nowrap}
 .bar-value{font-size:11px}
 /* ---- 服务器基本信息 ---- */
 .spec-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:2px 6px;padding:8px 8px 6px}
 .spec{padding:7px 4px;min-height:0}
 .spec-icon{width:20px;height:20px}
 .spec-main-value{font-size:12.5px}
 .spec-label{font-size:10px}
 .cpu-model{font-size:10px;max-width:100%;white-space:normal;overflow:hidden;text-overflow:ellipsis}
 .server-benchmark{margin:2px 8px 8px;padding-top:6px}
 .server-benchmark-head{font-size:11px;margin-bottom:5px}
 .server-benchmark-groups{grid-template-columns:1fr}
 .server-benchmark-metrics{grid-template-columns:repeat(2,minmax(0,1fr));gap:5px}
 .bench-metric{padding:6px 8px}
 .bench-metric label{font-size:10px;min-height:0}
 .bench-metric strong{font-size:13px;margin-top:2px}
 .bench-metric small{font-size:9.5px}
 .ovs-chips{flex-wrap:wrap}
 .ovs{font-size:9.5px;padding:2px 6px}
 /* ---- 三网表:8 列压进视口,不出现横向滚动条 ----
    自然宽 ~414px@10.5px,压字号+列距+单元格内边距后 ≤357px;超宽单元格省略号 */
 .china-wrap{padding:4px 4px 6px;overflow:visible}
 .china-table{min-width:0;width:100%;table-layout:fixed}
 .china-table th,.china-table td{padding:4px 1px;font-size:9.6px;white-space:nowrap;
  overflow:hidden;text-overflow:ellipsis;max-width:0}
 .china-table th{max-width:none}
 /* 列宽按内容实测需求分配:运营商/回程/重传/评价宽,纯数字列窄 */
 .china-table th:nth-child(1),.china-table td:nth-child(1){width:16%}
 .china-table th:nth-child(2),.china-table td:nth-child(2){width:10.5%}
 .china-table th:nth-child(3),.china-table td:nth-child(3){width:21.5%}
 .china-table th:nth-child(4),.china-table td:nth-child(4){width:9.5%}
 .china-table th:nth-child(5),.china-table td:nth-child(5){width:9.5%}
 .china-table th:nth-child(6),.china-table td:nth-child(6){width:9%}
 .china-table th:nth-child(7),.china-table td:nth-child(7){width:13.5%}
 .china-table th:nth-child(8),.china-table td:nth-child(8){width:11%}
 .china-table .num{font-size:9.6px}
 .china-table .cell{font-size:8.8px;padding:1px 3px;min-width:0}
 .china-table .carrier{gap:0}
 .china-table .carrier-logo{display:none}   /* 移动端隐藏运营商小图标,文字足够辨识,腾出列宽 */
 .protocol-tag{font-size:8.2px;padding:1px 2px;letter-spacing:0;min-width:0}
 .route-name{font-size:9.2px;padding:1.5px 4px}
 /* ---- 国际测速:2 列大卡;地区名/速度可换行,保证完整显示 ---- */
 .legend{display:none}
 .intl-grid{grid-template-columns:repeat(3,minmax(0,1fr));gap:6px;padding:6px 8px 8px}
 .intl-item{padding:7px 8px;min-width:0}
 .intl-top{gap:4px;flex-wrap:wrap}
 .intl-item .flag{width:16px;height:16px}
 .intl-item .flag svg{width:16px;height:16px}
 .intl-name{font-size:11.5px;white-space:normal;overflow:visible;min-width:0;flex:1}
 .intl-state{font-size:9.5px;padding:2px 6px}
 .intl-speeds{display:grid;grid-template-columns:1fr;gap:2px;margin-top:5px}   /* 上下行各占一行,完整显示 */
 .intl-speed{font-size:11px;white-space:nowrap}
 .intl-speed small{font-size:9px}
 .intl-bottom{font-size:10px;margin-top:5px;padding-top:4px;flex-wrap:wrap}
 .intl-brand-strip{flex-wrap:wrap;overflow:visible;gap:3px 5px}   /* chips 换行,不横滚 */
 .brand-chip{font-size:9px;padding:1.5px 6px;white-space:nowrap}
 /* ---- 回程卡:摘要与矩阵上下堆叠(选择器带 .route-card 前缀,
      以压过 ROUTE_COMPACT_CSS 的同优先级紧凑规则) ---- */
 .route-card .section-head{height:36px}
 .route-card .route-body{grid-template-columns:1fr;gap:6px;padding:6px 6px 0}
 .route-card .route-summary{padding:8px;min-height:0}
 .route-summary-top{gap:8px}
 .route-card .donut{width:40px;height:40px}
 .route-card .donut:after{inset:8px}
 .route-card .route-count{font-size:17px}
 .route-card .route-count small{font-size:10px}
 .route-card .route-main-label{font-size:10.5px;margin-top:2px}
 .route-card .route-progress{font-size:9.5px;margin-top:5px}
 .route-card .route-progress-bar{height:5px}
 .route-card .route-note{font-size:10px;line-height:1.5;padding:6px 8px;margin-top:6px;min-height:0}
 .route-card .packet-table{overflow:visible}
 .route-card .packet-table table{font-size:10px;min-width:0;width:100%}
 .route-card .packet-table th{padding:4px 2px}
 .route-card .packet-table td{height:auto;padding:4px 2px}
 .route-card .packet-table .cell{font-size:10px;padding:2px 6px}
 .route-card .carrier-col-head{gap:3px}
 .route-card .carrier-col-head .carrier-logo{width:13px;height:13px}
 .route-card .carrier-col-head .carrier-logo svg{width:13px;height:13px}
 .route-card .carrier-avg .avg-main b{font-size:11px}
 .route-card .carrier-avg .avg-main i{font-size:8.5px}
 .route-card .carrier-avg .avg-sub{font-size:9px}
 /* ---- IP 风险:IPv4 / IPv6 面板一排两列(不再上下两排),行内压缩 ---- */
 .risk-columns{grid-template-columns:1fr 1fr;gap:5px;padding:6px 6px 7px}
 .risk-panel{min-width:0}
 .risk-head{font-size:10px;padding:4px 6px;gap:4px}
 .risk-line{font-size:10px;padding:3px 1px;min-height:0;gap:4px}
 .risk-line span:first-child{flex:0 1 auto;min-width:0;font-size:9.5px;white-space:normal;line-height:1.25;overflow:visible}
 .risk-line b{font-size:10px;min-width:0;white-space:normal;line-height:1.3;text-align:right}
 .risk-grade{font-size:9px;padding:1px 6px}
 .risk-meta{grid-template-columns:1fr;gap:0}
 /* ---- 解锁:三组(流媒体/社交/AI)一排三列;状态为彩色圆点腾出空间 ----
    (含义保留在 title 悬浮;加 html 前缀以压过暗色主题的同状态规则) */
 .unlock-grid{grid-template-columns:repeat(3,minmax(0,1fr));gap:5px;padding:5px 6px 7px}
 .unlock-group{min-width:0}
 .unlock-group h3{font-size:10px;padding:4px 4px;gap:4px}
 .unlock-row{font-size:10.5px;padding:3px 1px;min-height:0;gap:4px;grid-template-columns:minmax(0,1fr) auto}
 .service-name{min-width:0;white-space:normal;line-height:1.3;overflow:hidden;overflow-wrap:anywhere}
 .service-name .fam46{display:none}   /* v4/v6 角标让位;IPv4/IPv6 详情在 title 悬浮 */
 .service-icon{width:11px;height:11px;flex:0 0 auto}
 .unlock-result{gap:4px;min-width:0;flex:none}
 .unlock-loc{white-space:nowrap;max-width:88px;overflow:hidden;text-overflow:ellipsis}   /* 地区为次要信息,窄屏(≤480)整体隐藏让位服务名 */
 html .unlock-state{display:inline-block;width:11px;height:11px;min-width:11px;
 padding:0;border-radius:50%;font-size:0;line-height:0;flex:none;
 box-shadow:inset 0 0 0 1px rgba(0,0,0,.06)}
 html .unlock-state.unlocked,html[data-theme] .unlock-state.unlocked{background:#22a45d}
 html .unlock-state.partial,html[data-theme] .unlock-state.partial{background:#f59e0b}
 html .unlock-state.blocked,html[data-theme] .unlock-state.blocked{background:#dc2626}
 html .unlock-state.pending,html[data-theme] .unlock-state.pending{background:#c3cede}
 html .unlock-state.error,html[data-theme] .unlock-state.error{background:#8b5cf6}
 html .unlock-state.unsupported,html[data-theme] .unlock-state.unsupported{background:#c3cede}
 .unlock-foot{font-size:9.5px}
 /* ---- 邮件 ---- */
 .mail-core{grid-template-columns:1fr;gap:6px;padding:8px}
 .mail-port,.dnsbl{padding:8px}
 .mail-provider-title{font-size:10.5px;padding:4px 8px 3px}
 .mail-provider-grid{grid-template-columns:repeat(3,minmax(0,1fr));gap:4px;padding:0 8px 8px}
 .mail-provider{padding:6px 4px}
 .provider-name{font-size:10px}
 .provider-state{font-size:9.5px}
 .dnsbl-values{font-size:10.5px}
 /* ---- 页脚 / 回顶 ---- */
 .footer-note{flex-direction:column;align-items:flex-start;gap:4px;font-size:10.5px;padding:2px 4px 4px}
 .btt{right:14px;bottom:calc(14px + env(safe-area-inset-bottom,0px))}
}
@media (max-width:480px){
 .spec-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
 .server-benchmark-metrics{grid-template-columns:repeat(2,minmax(0,1fr))}
 .mail-provider-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
 .intl-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
 .unlock-loc{display:none}
 .gauge{width:132px;height:60px}
 .gauge svg{width:132px;height:60px}
 .gauge-number{font-size:23px}
}
@media (max-width:360px){
 .intl-grid{grid-template-columns:1fr}   /* 极窄屏单列,速度值完整显示 */
 .unlock-loc{display:none}   /* 极窄屏隐藏地区标签,服务名完整显示(地区见悬浮) */
 .china-table th,.china-table td{font-size:8.8px;padding:3px 1px}
 .china-table .num{font-size:8.8px}
 .china-table .cell{font-size:8.2px}
 .protocol-tag{font-size:7.4px;padding:0 1px;min-width:0}
 .china-table .cell{padding:0 2px;min-width:0}
 .route-name{font-size:8.4px;padding:1px 2px}
 .china-table .cell{padding:0 2px}
}
HQCSSEOF
)

HQ_ICON_SCORE='<svg viewBox="0 0 24 24"><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.5 5.5l2.2 2.2M16.3 16.3l2.2 2.2M18.5 5.5l-2.2 2.2M7.7 16.3l-2.2 2.2"/><circle cx="12" cy="12" r="5"/></svg>'
HQ_ICON_SPEC='<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><path d="M7 7h.01M11 7h.01M7 17h.01M11 17h.01"/></svg>'
HQ_ICON_CHINA='<svg viewBox="0 0 24 24"><path d="M3 20h18M5 17V9h3v8M11 17V4h3v13M17 17v-6h3v6"/></svg>'
HQ_ICON_INTL='<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0-20"/></svg>'
HQ_ICON_RISK='<svg viewBox="0 0 24 24"><path d="M12 2 21 6v6c0 5-4 8-9 10-5-2-9-5-9-10V6z"/><path d="m8 12 3 3 5-6"/></svg>'
HQ_ICON_PLAY='<svg viewBox="0 0 24 24"><path d="m8 5 12 7-12 7z" fill="currentColor" stroke="none"/></svg>'
HQ_ICON_MAIL='<svg viewBox="0 0 24 24"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="m3 6 9 7 9-7"/></svg>'
HQ_ICON_CPU='<svg viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 1v4M15 1v4M9 19v4M15 19v4M1 9h4M1 15h4M19 9h4M19 15h4"/></svg>'
HQ_ICON_RAM='<svg viewBox="0 0 24 24"><rect x="2" y="5" width="20" height="14" rx="2"/><path d="M6 9v6M10 9v6M14 9v6M18 9v6"/></svg>'
HQ_ICON_DISK='<svg viewBox="0 0 24 24"><rect x="2" y="4" width="20" height="16" rx="3"/><circle cx="7" cy="15" r="1"/><path d="M5 8h14"/></svg>'
HQ_ICON_VIRT='<svg viewBox="0 0 24 24"><path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/><path d="M3 17.5l9 5 9-5"/></svg>'
HQ_ICON_ARCH='<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/><rect x="10" y="10" width="4" height="4"/><path d="M9 1.5v4.5M15 1.5v4.5M9 18v4.5M15 18v4.5M1.5 9h4.5M1.5 15h4.5M18 9h4.5M18 15h4.5"/></svg>'
HQ_ICON_OS='<svg viewBox="0 0 24 24"><path d="M17.8 5.2c-2.2-2-6.2-2-8.5.2-1.7 1.7-1.9 4.2-.5 5.8 1.1 1.3 3.3 1.5 4.3.1.6-.8.3-1.8-.6-2.1-.7-.3-1.5.1-1.6.8" fill="none" stroke="#d70a53" stroke-width="1.7" stroke-linecap="round"/><path d="M18.5 7.5c2.3 2.4 1.7 6.2-.8 8.5-2.8 2.6-7.4 2.7-10.2.2-2.7-2.3-2.8-6.4-.3-9.1" fill="none" stroke="#d70a53" stroke-width="1.7" stroke-linecap="round"/></svg>'

HQ_LOGO_TELECOM='<svg xmlns="http://www.w3.org/2000/svg" viewBox="-40.3 -40.3 289.3 280.3"><path fill="#0f5bb5" d="M141.992 8.139s-4.978-5.512-11.557-5.512c0 0-14.401 0-24.18 31.114 0 0-8.356 27.203-8.356 67.562 0 0 0 38.048 7.823 64.895 0 0 7.823 27.202 19.201 27.202 0 0 8.001 0 14.757-14.935 0 0 6.757-14.935 9.602-39.292l21.335-5.334s-5.512 45.337-22.58 74.673c0 0-17.602 29.514-39.825 29.514 0 0-26.669 0-45.516-40.004 0 0-18.846-40.003-18.846-96.719 0 0 0-56.716 18.846-97.075 0 0 18.847-40.181 45.516-40.181 0 0 26.669 0 45.692 40.892l-11.912 3.2"/><path fill="#0f5bb5" d="M217.021 62.721s-36.804 30.403-95.476 45.16c0 0-58.85 14.579-105.609 4.978 0 0-46.76-9.957-53.693-38.581 0 0-5.867-23.824 19.913-50.138 0 0 25.424-26.136 71.117-43.56l3.022 11.734S29.626 3.693 14.869 18.094c0 0-15.112 15.112-11.734 28.091 0 0 4.444 16.535 35.736 21.513 0 0 31.114 4.8 71.473-5.156 0 0 40.004-9.957 65.606-28.98 0 0 25.246-19.202 20.979-35.914 0 0-3.556-14.401-29.158-20.625l-3.911-15.29s33.247 1.245 55.294 12.268c0 0 22.579 11.023 27.202 29.692.001.001 7.29 28.448-29.335 59.028"/></svg>'
HQ_LOGO_UNICOM='<svg xmlns="http://www.w3.org/2000/svg" viewBox="48.3 11.5 96.1 140.0"><path fill="#E60012" fill-rule="evenodd" d="M105.764 81.449l1.33-1.478 3.4-3.4 4.877-4.877 5.469-5.765 5.766-5.913 5.025-5.173 3.695-3.991 1.922-1.774.443-.443.443-.443.295-.444.443-.591.297-.591.443-.591 1.033-1.921.74-1.626.443-1.626.295-.887v-.887l.295-.887v-2.956l-.146-.887-.148-1.182-.148-1.035-.295-1.035-.443-1.182-.443-1.035-.592-1.035-1.33-2.217-.738-1.33-.887-1.183-2.07-2.217-1.33-1.183-1.035-.886-1.182-1.035-2.217-1.478-2.365-1.182-1.035-.444-1.035-.443-1.182-.295-2.07-.443h-4.877l-.887.295-.887.148-.738.147-.887.296-.74.295-.738.295-.74.296-.59.296-.592.295-.592.443-.443.295-.592.296-.295.443-.443.296-.443.147-2.957 3.104-1.773 1.774-5.617 5.765-.443.443v-.148l-.147.148-.296-.443-5.765-5.765-1.626-1.774-3.104-3.104-.296-.147-.444-.294-.443-.443-.443-.296-.591-.295-.444-.443-.739-.295-.591-.296-.591-.296-.887-.295-.739-.295-.887-.296-.74-.15-.887-.148-.887-.295H71.03l-2.071.443-1.183.295-.887.443-1.183.444-2.217 1.182-2.365 1.478-1.035 1.035-1.182.886-1.331 1.183-1.921 2.217-.887 1.183-.887 1.33-.739 1.035-.591 1.183-.591 1.035-.443 1.035-.295 1.182-.444 1.035-.147 1.035-.148 1.182-.148.887v2.956l.148.887.443 1.774.443 1.626.739 1.626 1.035 1.921.443.591.295.591.443.591.443.444.444.443.295.443 1.922 1.774 3.695 3.991 5.174 5.173 5.617 5.913 5.617 5.765 4.877 4.877 3.4 3.4 1.183 1.478-1.181 1.331-3.4 3.4-4.877 4.877-5.617 5.913-5.617 5.765-5.174 5.173-3.695 3.991-1.922 1.773-.295.443-.444.443-.443.443-.443.592-.295.591-.443.592-1.035 2.069-.739 1.478-.443 1.626-.443 1.774-.148.887v2.956l.148.887.148 1.183.147 1.034.444 1.035.295 1.183.443 1.034.591 1.035.591 1.183.739 1.182.887 1.183.887 1.183 1.921 2.217 1.331 1.183 1.182 1.035 1.035.887 2.365 1.478 2.217 1.184 1.183.443.887.443 1.183.295 2.069.443 1.034.148h2.069l.887-.148h.887l.887-.295.887-.148.739-.147.887-.296.739-.295.887-.296.591-.296.591-.296.739-.296.444-.443.591-.295.443-.296.443-.443.443-.296.296-.147 3.104-3.104 1.626-1.773 5.765-5.765.296-.443.147.147v-.147l.443.443 5.617 5.765 1.773 1.773 2.957 3.104.443.147.443.296.295.443.592.296.443.295.592.443.592.296.59.296.74.296.738.296.74.295.887.296.738.147.887.148.887.295h1.035l.887.148h1.922l1.033-.148 2.07-.443 1.182-.295 1.035-.443 1.035-.443 2.365-1.184 2.217-1.478 1.182-.887 1.035-1.035 1.33-1.183 2.07-2.217.887-1.183.738-1.183 1.33-2.364.592-1.035.443-1.034.443-1.183.295-1.035.148-1.034.148-1.183.146-.887v-2.956l-.295-.887v-.888l-.295-.887-.443-1.626-.74-1.478-1.033-2.069-.443-.592-.297-.591-.443-.592-.295-.443-.443-.443-.443-.443-1.922-1.773-3.695-3.991-5.025-5.173-5.766-5.765-5.469-5.913-4.877-4.877-3.4-3.4-1.329-1.331zM67.038 38.732h-.148l-.296-.591-.295-.148-.444-.887v-.591l-.147-.295-.148-.296v-.295l-.148-.296v-1.478l.148-.443v-.295l.591-1.774.148-.147.739-1.035.296-.295.147-.295.739-.443.147-.148.739-.443.296-.147.295-.296 1.331-.443h.147l.443-.147h1.479l.295.147h.295l.296.148h.296l.739.295.295.148.296.148.295.295.443.295.148.148.739.739 1.183 1.331 1.478 1.625 1.922 1.626 1.478 1.774 2.513 2.513.443.443-7.391 7.538 10.199 10.347 7.39-7.686 7.244 7.686 10.199-10.347-7.244-7.538.297-.443 2.512-2.513 1.627-1.774 1.773-1.626 1.479-1.625 1.182-1.331.887-.739v-.148l.443-.295.443-.295.148-.148.443-.148.592-.295h.295l.295-.148h.297l.295-.147h1.625l.297.147h.146l1.479.443.148.296.295.147.74.443.295.148.592.443.295.295.148.295.738 1.035.148.147.592 1.774v.295l.146.443v1.478l-.146.296v.295l-.148.296V36.663l-.148.443-.443.887-.295.148-.148.591h-.295l-1.627 1.773-3.547 3.548-4.73 4.877-5.32 5.469-5.174 5.321-4.434 4.73-3.252 3.252-1.183 1.183-1.33-1.183-3.104-3.252-4.582-4.73-5.172-5.32-5.321-5.469-4.73-4.877-3.547-3.548-1.626-1.774zm58.237 94.451l-.592.443-.295.296-.74.443h-.295l-.148.296-1.479.443h-.146l-.297.148h-1.625l-.295-.148h-.297l-.295-.147h-.295l-.592-.296-.443-.148-.148-.147-.443-.296-.443-.147v-.296l-.887-.738-1.182-1.33-1.479-1.626-1.773-1.626-1.627-1.773-2.512-2.365-.297-.443 7.244-7.687-10.199-10.347-7.244 7.686-7.39-7.686-10.199 10.347 7.391 7.687-.443.443-2.513 2.365-1.478 1.773-1.922 1.626-1.478 1.626-1.183 1.33-.739.738-.148.296-.443.147-.295.296-.296.147-.295.148-.739.296h-.296l-.296.147h-.295l-.295.148H71.62l-.443-.148h-.147l-1.331-.443-.295-.296h-.296l-.739-.443-.147-.296-.739-.443-.147-.295-.296-.296-.739-1.034-.148-.148-.591-1.773v-.296l-.148-.296v-1.478l.148-.443v-.296l.148-.295.147-.296v-.591l.444-.887.295-.147.296-.443.147-.148 1.626-1.773 3.547-3.548 4.73-4.877 10.495-10.791 4.582-4.581 3.104-3.4 1.33-1.183 1.183 1.183 3.252 3.4 4.434 4.581 10.494 10.791 4.73 4.877 3.547 3.548 1.627 1.773.295.148.148.443.295.147.443.887.148.443V126.533l.148.295v.296l.146.443v1.478l-.146.296v.296l-.592 1.773-.148.148-.738 1.034-.148.296-.296.295z"/></svg>'
HQ_LOGO_MOBILE='<svg xmlns="http://www.w3.org/2000/svg" viewBox="7.5 71.5 49.7 49.7"><path fill="#0086D4" fill-rule="evenodd" d="M8.504 96.378c0-13.156 10.677-23.833 23.833-23.833S56.17 83.223 56.17 96.378c0 13.157-10.677 23.833-23.833 23.833S8.504 109.535 8.504 96.378zm10.487-4.242l2.383 1.954 9.867-8.389a5.634 5.634 0 0 1 3.289-1.049c1.288 0 2.432.429 3.385 1.145l12.489 10.2v2.335l-11.059-9.008c-.81-.572-1.811-.954-2.907-.954a4.563 4.563 0 0 0-2.956 1.049l-.143.095-.048.047c-1.096.906-6.148 5.148-8.723 7.294h.048c.524.857 1.859.953 3.051.285.047-.047.095-.047.095-.047 2.765-2.336 5.292-4.529 5.577-4.767a4.183 4.183 0 0 1 2.812-1.049c.953 0 1.859.333 2.574.905l11.679 9.534-.286.047.286.287s-10.535 8.961-13.156 11.201c-1.335 1.383-3.194 2.193-5.244 2.193a7.416 7.416 0 0 1-5.005-1.906L13.89 102.861v-3.338l13.061 10.678a5.348 5.348 0 0 0 3.098 1.002c1.287 0 2.431-.43 3.337-1.191.524-.43 8.437-7.15 11.964-10.154l-2.335-1.906-9.962 8.389a5.629 5.629 0 0 1-3.289 1.049 5.57 5.57 0 0 1-3.385-1.143L13.89 96.092v-2.335l11.059 8.962c.81.619 1.811.953 2.908.953 1.144 0 2.145-.383 3.003-1.002l.095-.096.048-.047c1.096-.906 6.149-5.148 8.723-7.341h-.048l-.048-.048-.62-.524c-.62-.238-1.573-.19-2.383.286-.048.047-.095.047-.095.047a774.618 774.618 0 0 1-5.577 4.767c-.763.668-1.716 1.096-2.812 1.096-.953 0-1.859-.381-2.574-.953l-7.913-6.53-.047.047-2.336-1.907-.62-.667-.763-.62.096-.047-.096-.095 13.156-11.25c1.335-1.334 3.194-2.193 5.243-2.193 1.955 0 3.67.715 5.005 1.907l13.108 10.725v3.289l-13.061-10.63a5.344 5.344 0 0 0-3.098-1.001 5.332 5.332 0 0 0-3.337 1.144c-.523.43-8.388 7.104-11.915 10.107z"/></svg>'

intl_flag() { # 名字 → 国旗码
    case "$1" in
        *Apple*|*apple*) printf 'apple' ;;
        *日本*) printf 'jp' ;;
        *新加坡*) printf 'sg' ;;
        *香港*) printf 'hk' ;;
        *印度*) printf 'in' ;;
        *美国西海岸*|*美西*) printf 'us' ;;
        *美国东海岸*) printf 'us' ;;
        *德国*) printf 'de' ;;
        *英国*) printf 'gb' ;;
        *巴西*) printf 'br' ;;
        *澳大利亚*|*悉尼*) printf 'au' ;;
        *加拿大*) printf 'ca' ;;
        *法国*) printf 'fr' ;;
        *荷兰*) printf 'nl' ;;
        *) printf '' ;;
    esac
}
hq_flag_svg() {
    case "$1" in
        apple) printf '%s' '<svg viewBox="0 0 24 24"><path d="M16.8 12.7c0-2.1 1.7-3.1 1.8-3.2-1-1.5-2.5-1.7-3.1-1.7-1.3-.2-2.6.8-3.3.8-.7 0-1.7-.8-2.8-.8-1.5 0-3 .9-3.8 2.3-1.6 2.7-.4 6.6 1.1 8.7.8 1.1 1.6 2.2 2.8 2.1 1.1-.1 1.6-.7 2.9-.7s1.7.7 2.9.7c1.2 0 2-.9 2.8-2.1.9-1.2 1.2-2.4 1.2-2.5-.1 0-2.7-1-2.7-3.6zM14.7 6c.6-.7 1-1.6.9-2.6-.9.1-1.9.7-2.5 1.4-.6.6-1.1 1.5-.9 2.5 1 .1 1.9-.5 2.5-1.3z" fill="#222"/></svg>' ;;
        jp)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#fff"/><circle cx="15" cy="10" r="5.8" fill="#bc002d"/></svg>' ;;
        sg)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="10" fill="#ed2939"/><rect y="10" width="30" height="10" fill="#fff"/><circle cx="7" cy="5" r="3.2" fill="#fff"/><circle cx="8" cy="4.2" r="2.6" fill="#ed2939"/><g fill="#fff"><circle cx="12" cy="2.1" r=".55"/><circle cx="13.7" cy="4.2" r=".55"/><circle cx="12.9" cy="6.2" r=".55"/><circle cx="10.7" cy="6.2" r=".55"/><circle cx="10" cy="4.2" r=".55"/></g></svg>' ;;
        hk)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#de2910"/><g fill="#fff"><ellipse cx="15" cy="5.6" rx="2.1" ry="4.1"/><ellipse cx="15" cy="5.6" rx="2.1" ry="4.1" transform="rotate(72 15 10)"/><ellipse cx="15" cy="5.6" rx="2.1" ry="4.1" transform="rotate(144 15 10)"/><ellipse cx="15" cy="5.6" rx="2.1" ry="4.1" transform="rotate(216 15 10)"/><ellipse cx="15" cy="5.6" rx="2.1" ry="4.1" transform="rotate(288 15 10)"/></g><circle cx="15" cy="10" r="1.6" fill="#de2910"/></svg>' ;;
        in)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="6.67" fill="#ff9933"/><rect y="6.67" width="30" height="6.66" fill="#fff"/><rect y="13.33" width="30" height="6.67" fill="#138808"/><circle cx="15" cy="10" r="2.6" fill="none" stroke="#000080" stroke-width=".8"/><path d="M15 7.4v5.2M12.4 10h5.2M13.2 8.2l3.6 3.6M16.8 8.2l-3.6 3.6" stroke="#000080" stroke-width=".45"/></svg>' ;;
        us)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#b22234"/><path fill="#fff" d="M0 1.5h30v1.5H0zM0 4.5h30V6H0zM0 7.5h30V9H0zM0 10.5h30V12H0zM0 13.5h30V15H0zM0 16.5h30V18H0z"/><rect width="13" height="10.8" fill="#3c3b6e"/><g fill="#fff"><circle cx="2" cy="2" r=".45"/><circle cx="5" cy="2" r=".45"/><circle cx="8" cy="2" r=".45"/><circle cx="11" cy="2" r=".45"/><circle cx="3.5" cy="4.2" r=".45"/><circle cx="6.5" cy="4.2" r=".45"/><circle cx="9.5" cy="4.2" r=".45"/><circle cx="2" cy="6.4" r=".45"/><circle cx="5" cy="6.4" r=".45"/><circle cx="8" cy="6.4" r=".45"/><circle cx="11" cy="6.4" r=".45"/></g></svg>' ;;
        de)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="6.67" fill="#111"/><rect y="6.67" width="30" height="6.66" fill="#dd0000"/><rect y="13.33" width="30" height="6.67" fill="#ffce00"/></svg>' ;;
        gb)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#012169"/><path d="M0 0 4 0 30 16.5V20h-4L0 3.5zM30 0h-4L0 16.5V20h4L30 3.5z" fill="#fff"/><path d="M0 0 1.5 0 30 18.5V20h-1.5L0 1.5zM30 0h-1.5L0 18.5V20h1.5L30 1.5z" fill="#c8102e"/><path d="M12 0h6v20h-6zM0 7h30v6H0z" fill="#fff"/><path d="M13.3 0h3.4v20h-3.4zM0 8.3h30v3.4H0z" fill="#c8102e"/></svg>' ;;
        br)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#009b3a"/><path d="M15 2 27 10 15 18 3 10Z" fill="#ffdf00"/><circle cx="15" cy="10" r="5.2" fill="#002776"/><path d="M10.3 8.7Q15 7.1 19.7 9.2" fill="none" stroke="#fff" stroke-width=".8"/></svg>' ;;
        au)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#012169"/><path d="M0 0 12 7.4M12 0 0 7.4" stroke="#fff" stroke-width="2.2"/><path d="M0 0 12 7.4M12 0 0 7.4" stroke="#c8102e" stroke-width=".8"/><path d="M6 0v7.4M0 3.7h12" stroke="#fff" stroke-width="2.5"/><path d="M6 0v7.4M0 3.7h12" stroke="#c8102e" stroke-width=".9"/><g fill="#fff"><circle cx="20" cy="5" r="1"/><circle cx="25" cy="10" r=".8"/><circle cx="18" cy="14" r=".8"/><circle cx="24" cy="16" r=".8"/></g></svg>' ;;
        ca)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="7" height="20" fill="#d80621"/><rect x="7" width="16" height="20" fill="#fff"/><rect x="23" width="7" height="20" fill="#d80621"/><path d="m15 3 1.3 4 2.2-1-1 3 2 1-3.1.4.4 4.4-1.8-.8-1.8.8.4-4.4-3.1-.4 2-1-1-3 2.2 1z" fill="#d80621"/></svg>' ;;
        fr)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="10" height="20" fill="#002395"/><rect x="10" width="10" height="20" fill="#fff"/><rect x="20" width="10" height="20" fill="#ed2939"/></svg>' ;;
        nl)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="6.67" fill="#ae1c28"/><rect y="6.67" width="30" height="6.66" fill="#fff"/><rect y="13.33" width="30" height="6.67" fill="#21468b"/></svg>' ;;
        tw)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#fe0000"/><rect x="4" y="3" width="12" height="9" fill="#000095"/><path d="M10 4.6l.9 1.9 2 .2-1.5 1.4.4 2-1.8-1-1.8 1 .4-2-1.5-1.4 2-.2z" fill="#fff"/><circle cx="17.5" cy="5" r="1" fill="#fff"/><circle cx="19.5" cy="8" r="1" fill="#fff"/><circle cx="18" cy="11.5" r="1" fill="#fff"/><circle cx="15" cy="10" r="1" fill="#fff"/><circle cx="15" cy="6.5" r="1" fill="#fff"/></svg>' ;;
        kr)    printf '%s' '<svg viewBox="0 0 30 20"><rect width="30" height="20" fill="#fff"/><circle cx="15" cy="10" r="4" fill="#003478"/><path d="M11 10a4 4 0 0 1 8 0 2 2 0 0 0-4-1 2 2 0 0 0-4 1z" fill="#cd2e3a" transform="translate(0 .0)"/><path d="M11 10a4 4 0 0 0 8 0 2 2 0 0 1-4 1 2 2 0 0 1-4-1z" fill="#cd2e3a" opacity="0" /><g stroke="#111" stroke-width=".8"><path d="M6.5 6.5 9 4.3M23.5 13.5 21 15.7M21 4.3l2.5 2.2M9 15.7l-2.5-2.2" /><path d="M4.8 8.6 8 7.7M25.2 11.4 22 12.3M22 7.7l3.2.9M8 12.3l-3.2-.9"/></g></svg>' ;;
        *)     printf '' ;;
    esac
}
# hq_fam46 <v4状态> <v6状态> -> "4|6" 双色方块 SVG
hq_fam46() {
    local v4=$1 v6=$2 c4 c6 t6
    c4="#1eac64"; case "$v4" in no) c4="#d9534f" ;; fail|'') c4="#9aa9bc" ;; orig) c4="#e8a13a" ;; esac
    c6="#1eac64"; t6="6"
    case "$v6" in
        yes) ;;
        no)  c6="#9aa9bc" ;;
        fail) c6="#d9534f" ;;
        na|'') c6="#ccd6e2"; t6="-" ;;
        *)   c6="#ccd6e2"; t6="-" ;;
    esac
    printf '<svg class="fam46" viewBox="0 0 17 10"><rect x="0" y="0" width="7.6" height="10" rx="1.8" fill="%s"/><text x="3.8" y="7.6" font-size="7" font-weight="800" fill="#fff" text-anchor="middle" font-family="Arial">4</text><rect x="9.4" y="0" width="7.6" height="10" rx="1.8" fill="%s"/><text x="13.2" y="7.6" font-size="7" font-weight="800" fill="#fff" text-anchor="middle" font-family="Arial">%s</text></svg>' "$c4" "$c6" "$t6"
}

# hq_unlock_state <v4状态> <v6状态(空/na=不适用)> <dual|v4|v6> -> "class|文案"
# 双栈聚合:v4+v6 均解锁=全部解锁(绿);其一解锁=部分解锁(黄);均未解锁=未解锁(红);
# 双 fail=失败;单栈退化为该族状态(v6 缺失/服务无 AAAA 不把 v4-only 拉成"部分")
hq_unlock_state() {
    local s4=$1 s6=$2 mode=$3
    [ "$s6" = na ] && s6=""    # 服务无 AAAA:v6 不适用,按实测族呈现
    case "$mode" in
        v6)
            # IPv6-only:v6 探测为裁决方;个别服务无探测结果时退回实测状态
            case "${s6:-$s4}" in
                yes) printf 'unlocked|已解锁' ;; no) printf 'blocked|未解锁' ;;
                fail) printf 'error|失败' ;;    *)  printf 'pending|待检测' ;;
            esac
            return ;;
        dual)
            if [ -z "$s6" ]; then
                # 该服务 v6 探测缺失:按 v4 单族呈现,不造"部分解锁"
                case "$s4" in
                    yes) printf 'unlocked|已解锁' ;; orig) printf 'partial|仅自制' ;;
                    no)  printf 'blocked|未解锁' ;; fail) printf 'error|失败' ;;
                    *)   printf 'pending|待检测' ;;
                esac
                return
            fi
            if [ "$s4" = "yes" ] && [ "$s6" = "yes" ]; then printf 'unlocked|全部解锁'; return; fi
            case "$s4" in yes|orig) printf 'partial|部分解锁'; return ;; esac
            [ "$s6" = "yes" ] && { printf 'partial|部分解锁'; return; }
            if [ "$s4" = "fail" ] && [ "$s6" = "fail" ]; then printf 'error|失败'; return; fi
            printf 'blocked|未解锁'
            return ;;
        *) ;;
    esac
    case "$s4" in
        yes) printf 'unlocked|已解锁' ;; orig) printf 'partial|仅自制' ;;
        no)  printf 'blocked|未解锁' ;; fail) printf 'error|失败' ;;
        *)   printf 'pending|待检测' ;;
    esac
}

hq_region_badge() { # <区域码|文案> -> SVG 国旗+代码(两位码)或原文案
    local r=$1 i c cp out=""
    [ ${#r} -eq 2 ] || { printf '%s' "$r"; return; }
    r=$(printf '%s' "$r" | tr 'a-z' 'A-Z')
    for ((i=0; i<2; i++)); do
        c=${r:i:1}
        case "$c" in [A-Z]) ;; *) printf '%s' "$r"; return ;; esac
        cp=$(( 0x1F1E6 + $(printf '%d' "'$c") - 65 ))
        local hx
        hx=$(printf '%x' "$cp")
        out+=$(printf "\U$hx")
    done
    printf '%s'
}
hq_region_html() { # <区域码|文案> -> "<span class=unlock-flag>svg</span>CODE" 或原文案
    local r=$1 f
    case "$1" in
        [Aa][Zz]|[Bb][Aa]|[Cc][Aa]|[Dd][Ee]|[Ff][Rr]|[Gg][Bb]|[Hh][Kk]|[Ii][Nn]|[Jj][Pp]|[Kk][Rr]|[Nn][Ll]|[Ss][Gg]|[Tt][Ww]|[Uu][Ss]|[Bb][Rr]|[Aa][Uu])
            f=$(hq_flag_svg "$(printf '%s' "$1" | tr 'A-Z' 'a-z')")
            [ -n "$f" ] && { printf '<span class="unlock-flag">%s</span>%s' "$f" "$(printf '%s' "$1" | tr 'a-z' 'A-Z')"; return; }
            ;;
    esac
    printf '%s' "$r"
}

hq_ai_svg() {
    case "$1" in
        openai)    printf '%s' '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round"><path d="M12 3.5c2 0 3.6 1.2 4.3 2.9M16.3 6.4c1.9.4 3.4 2 3.7 3.9M20 10.3c1.1 1.7 1 4-.3 5.6M19.7 15.9c-.6 1.8-2.3 3.1-4.2 3.2M15.5 19.1c-1.1 1.7-3.3 2.4-5.2 1.7M10.3 20.8c-1.9-.5-3.4-2.1-3.7-4M6.6 16.8c-1.8-.6-3.1-2.3-3.2-4.2M3.4 12.6c-.4-1.9.4-4 2-5.2M5.4 7.4c.4-1.9 2-3.4 3.9-3.7M9.3 3.7c1-1 2.4-1.4 3.7-1.1"/><circle cx="12" cy="12" r="1.2" fill="#fff" stroke="none"/></svg>' ;;
        claude)    printf '%s' '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round"><path d="M12 3v18M4.2 7.5l15.6 9M19.8 7.5l-15.6 9M12 3 8.8 6.2M12 3l3.2 3.2M12 21l-3.2-3.2M12 21l3.2-3.2M4.2 7.5 4.6 12M4.2 7.5 8.6 8.5M19.8 7.5l-4.4 1M19.8 7.5l-.4 4.5M4.2 16.5l4.4-1M4.2 16.5l.4-4.5M19.8 16.5l-.4-4.5M19.8 16.5l-4.4-1"/></svg>' ;;
        gemini)    printf '%s' '<svg viewBox="0 0 24 24" fill="#fff"><path d="M12 2.5c.6 4.4 2.6 7.4 9 9.5-6.4 2.1-8.4 5.1-9 9.5-.6-4.4-2.6-7.4-9-9.5 6.4-2.1 8.4-5.1 9-9.5z"/></svg>' ;;
        perplexity) printf '%s' '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18M4 6h16M6.5 6v6.5c0 2 1.6 3.5 3.5 3.5M17.5 6v6.5c0 2-1.6 3.5-3.5 3.5M6.5 9.5H4M17.5 9.5H20M9 12H6.5M15 12h2.5"/></svg>' ;;
        copilot)   printf '%s' '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round"><path d="M8 16.5c-2.5 0-4.5-2-4.5-4.5S5.5 7.5 8 7.5c1 0 1.9.3 2.6.9M16 7.5c2.5 0 4.5 2 4.5 4.5s-2 4.5-4.5 4.5c-1 0-1.9-.3-2.6-.9M10.6 8.4c.9-.6 1.9-.9 2.8-.9"/></svg>' ;;
        grok)      printf '%s' '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.2"/><path d="M6 18 18 6"/></svg>' ;;
    esac
}
hq_logo() { # <电信|联通|移动>
    case "$1" in
        电信) printf '%s' "$HQ_LOGO_TELECOM" ;;
        联通) printf '%s' "$HQ_LOGO_UNICOM" ;;
        移动) printf '%s' "$HQ_LOGO_MOBILE" ;;
    esac
}

# 占位符注入:<file> <占位行> <内容文件>;占位行独占一行,头尾拼接替换
hq_inject() {
    local f=$1 ph=$2 cf=$3 t="$1.hqtmp"
    {
        sed -n "1,/^${ph}$/p" "$f" | sed '$d'
        cat "$cf"
        sed -n "/^${ph}$/,\$p" "$f" | sed '1d'
    } >"$t" && mv "$t" "$f"
}

# ---- 分数卡 ----
hq_score_card() {
    local score=${G[grade_total]:-} st_cls=pending st_txt=待检测 dims=0 pend_n=0 out="" k label v vcls vcol
    st_txt=$(grade_cn "${G[grade_label]:-}")
    # 等级 → 仪表配色(A绿/B蓝/C黄/D红/待检灰),弧线/数字/评价胶囊三处同源;
    # pill 沿用 good/warn/bad 语义类,B 级归 good
    local gcol="9aa9bc" gdark="6a7f9a"
    case "${G[grade_label]:-}" in
        A+|A)  st_cls=good; gcol="1eac64"; gdark="0b8a4a" ;;
        B+|B)  st_cls=good; gcol="1767c4"; gdark="14549b" ;;
        C)     st_cls=warn; gcol="f59e0b"; gdark="df7100" ;;
        D)     st_cls=bad;  gcol="e23e51"; gdark="d21a3b" ;;
    esac
    for k in cpu mem disk net ip; do
        case $k in cpu) label="CPU 性能" ;; mem) label="内存性能" ;; disk) label="磁盘 I/O" ;; net) label="网络性能" ;; ip) label="IP 质量" ;; esac
        v=${G[grade_${k}]:-}
        if is_num "$v"; then
            dims=$((dims+1))
            vcls=$(awk -v v="$v" 'BEGIN{print (v>=80)?"good":(v>=60)?"warn":"bad"}')
            vcol=$(awk -v v="$v" 'BEGIN{print (v>=80)?"1eac64":(v>=60)?"ffaf18":"e23e51"}')
        else
            v="—"; vcls=pending; vcol="9db1c6"; pend_n=$((pend_n+1))
        fi
        if is_num "$v"; then
            out+="<div class=\"bar-row\"><i style=\"width:9px;height:9px;border-radius:50%;background:#${vcol};display:inline-block\"></i><span class=\"bar-name\">${label}</span><span class=\"bar-track\"><b class=\"bar-fill ${vcls}\" style=\"width:${v}%\"></b></span><b class=\"bar-value ${vcls}\">${v}</b></div>"
        else
            out+="<div class=\"bar-row\"><i style=\"width:9px;height:9px;border-radius:50%;background:#${vcol};display:inline-block\"></i><span class=\"bar-name\">${label}</span><span class=\"bar-track pending-track\"><b class=\"bar-fill pending\">未计分 · 待补测</b></span><b class=\"bar-value pending\">—</b></div>"
        fi
    done
    local gnum="—"
    is_num "$score" && gnum=$score
    {
        printf '<section class="card score-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">主机综合评测</h2>' "$HQ_ICON_SCORE"
        printf '<button class="help" aria-label="说明">?<span class="tooltip">%s</span></button><span class="pill %s" style="margin-left:auto">%s</span></div>' "$TIP_SCORE" "$st_cls" "$st_txt"
        printf '<div class="score-body"><div class="score-left-stack"><div class="score-hero"><div class="gauge">'
        printf '<svg viewBox="0 0 200 120"><path d="M18 106 A82 82 0 0 1 182 106" fill="none" stroke="#e4edf5" stroke-width="16" stroke-linecap="round"/><path d="M18 106 A82 82 0 0 1 182 106" fill="none" stroke="#%s" stroke-width="16" stroke-linecap="round" pathLength="100" stroke-dasharray="%s 100"/></svg>' "$gcol" "${score:-0}"
        printf '<div class="gauge-number" style="color:#%s">%s <small>/100</small></div></div><div class="score-caption" style="background:#%s22;color:#%s">综合评价：%s</div></div>' "$gdark" "$gnum" "$gcol" "$gdark" "$st_txt"
        printf '<div class="score-extra"><div><span>已计分维度</span><b>%s 项</b></div></div></div><div class="score-bars">%s</div></div></section>' "$dims" "$out"
    }
}

# ---- 服务器信息卡 ----
# 国家码 → "[US]美国"(nodequality 展示口径;未收录回退 [CC])
cc_name() { # <CC>
    local cc n=""
    cc=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    [ -z "$cc" ] && return 0
    case "$cc" in
        US) n=美国 ;; CN) n=中国 ;; HK) n=香港 ;; MO) n=澳门 ;; TW) n=台湾 ;; JP) n=日本 ;; KR) n=韩国 ;;
        SG) n=新加坡 ;; MY) n=马来西亚 ;; TH) n=泰国 ;; VN) n=越南 ;; PH) n=菲律宾 ;; ID) n=印尼 ;;
        IN) n=印度 ;; AE) n=阿联酋 ;; IL) n=以色列 ;; TR) n=土耳其 ;; SA) n=沙特 ;;
        GB) n=英国 ;; DE) n=德国 ;; FR) n=法国 ;; NL) n=荷兰 ;; LU) n=卢森堡 ;; BE) n=比利时 ;;
        IE) n=爱尔兰 ;; CH) n=瑞士 ;; AT) n=奥地利 ;; IT) n=意大利 ;; ES) n=西班牙 ;; PT) n=葡萄牙 ;;
        SE) n=瑞典 ;; NO) n=挪威 ;; DK) n=丹麦 ;; FI) n=芬兰 ;; PL) n=波兰 ;; CZ) n=捷克 ;;
        RO) n=罗马尼亚 ;; BG) n=保加利亚 ;; UA) n=乌克兰 ;; RU) n=俄罗斯 ;; LT) n=立陶宛 ;;
        LV) n=拉脱维亚 ;; EE) n=爱沙尼亚 ;; CA) n=加拿大 ;; AU) n=澳大利亚 ;; NZ) n=新西兰 ;;
        BR) n=巴西 ;; AR) n=阿根廷 ;; CL) n=智利 ;; MX) n=墨西哥 ;; ZA) n=南非 ;; SC) n=塞舌尔 ;;
        *) n="" ;;
    esac
    if [ -n "$n" ]; then printf '[%s]%s' "$cc" "$n"; else printf '[%s]' "$cc"; fi
}

hq_spec_card() {
    local gb dsk bw_html flow_txt os_txt
    gb=$(fmt_mem_gb "${G[mem_total_mb]:-}")
    [ -n "$gb" ] || gb='<span class="na">待检测</span>'
    dsk=$(awk -v m="${G[disk_total_mb]:-0}" 'BEGIN{printf "%.0f GB", m/1024}')
    [ -n "${G[disk_type]:-}" ] && dsk="${dsk} <span class=\"spec-sub\">$(esc "${G[disk_type]}")</span>"
    # 虚拟化格:平台 + 嵌套虚拟化/AES-NI 特性徽章(v2.8 徽章移至本格)
    hq_cpu_feat() {
        local out=""
        case "${G[cpu_virt]:-}" in
            VT-x|AMD-V) out+="<span class=\"feat ok\" title=\"嵌套虚拟化 ${G[cpu_virt]} 可用\">${G[cpu_virt]} ✓</span>" ;;
            *)          out+="<span class=\"feat no\" title=\"guest 未暴露 vmx/svm 指令(宿主未开放嵌套虚拟化)\">VT ✗</span>" ;;
        esac
        if [ "${G[aes]:-}" = 是 ]; then
            out+="<span class=\"feat ok\" title=\"AES-NI 硬件加密指令\">AES ✓</span>"
        else
            out+="<span class=\"feat no\" title=\"无 AES-NI 指令\">AES ✗</span>"
        fi
        printf '%s' "$out"
    }
    [ -n "${G[virt]:-}" ] && bw_html="$(esc "${G[virt]}") <span class=\"feat-wrap\">$(hq_cpu_feat)</span>" || bw_html='<span class="na">待检测</span>'
    [ -n "${G[arch]:-}" ] && flow_txt=$(esc "${G[arch]}") || flow_txt='<span class="na">待检测</span>'
    os_txt=$(esc "${G[os_short]:-${G[os]:-—}}")
    local cells=""
    hq_spec_one() { cells+="<div class=\"spec\"><span class=\"spec-icon\">$1</span><div class=\"spec-copy\"><div class=\"spec-value\"><span class=\"spec-main-value\">$2</span></div>${4:+$4}<div class=\"spec-label\">$3</div></div></div>"; }
    # CPU 型号摘要(去厂商噪音,独占一行小字展示于核心数下方,悬浮显示完整型号)
    cpu_model_short() {
        printf '%s' "${G[cpu_model]:-}" | sed 's/(R)//g; s/(TM)//g; s/(tm)//g; s/^Intel //; s/^AMD //; s/Xeon CPU /Xeon /g; s/  */ /g; s/^ *//; s/ *$//'
    }
    local _cms _cmh=""
    _cms=$(cpu_model_short)
    [ -n "$_cms" ] && _cmh="<div class=\"cpu-model\" title=\"$(esc "${G[cpu_model]:-}")\">$(esc "$_cms")</div>"
    hq_spec_one "$HQ_ICON_CPU" "${G[cpu_cores]:-—} vCPU" "处理器" "$_cmh"
    hq_spec_one "$HQ_ICON_RAM" "$gb" "内存"
    hq_spec_one "$HQ_ICON_DISK" "$dsk" "硬盘"
    hq_spec_one "$HQ_ICON_VIRT" "$bw_html" "虚拟化"
    hq_spec_one "$HQ_ICON_ARCH" "$flow_txt" "系统架构"
    hq_spec_one "$HQ_ICON_OS" "$os_txt" "操作系统"

    local fr _bs _rd _wr _ri _wi r4ri='' r4wi='' r1r='' r1w=''
    for fr in ${FIO_ROWS[@]+"${FIO_ROWS[@]}"}; do
        IFS='|' read -r _bs _rd _wr _ri _wi <<< "$fr"
        case "$_bs" in 4k) r4ri=$_ri; r4wi=$_wi ;; 1m) r1r=$_rd; r1w=$_wr ;; esac
    done
    local bench="" bl
    hq_bm() {
        local val=$2 pend=""
        [ -z "$val" ] && pend=" class=pending" && val="待检测"
        bench+="<div class=\"bench-metric\"><label>$1</label><strong${pend}>$(esc "$val")</strong><small>$3</small></div>"
    }
    hq_bm "CPU 单核" "${G[cpu_score_single]:-}" "sha256/s"
    hq_bm "CPU 多核" "${G[cpu_score_multi]:-}" "sha256/s"
    hq_bm "内存写入" "$(is_num "${G[mem_w_mb]:-}" && printf '%.0f MB/s' "${G[mem_w_mb]}")" "tmpfs 1G"
    hq_bm "FIO 顺序读" "$(is_num "$r1r" && printf '%s MB/s' "$r1r")" "1M 块"
    hq_bm "FIO 顺序写" "$(is_num "$r1w" && printf '%s MB/s' "$r1w")" "1M 块"
    hq_bm "FIO 4K 随机读" "$(is_num "$r4ri" && printf '%s IOPS' "$r4ri")" "iodepth=64"
    hq_bm "FIO 4K 随机写" "$(is_num "$r4wi" && printf '%s IOPS' "$r4wi")" "iodepth=64"
    # 第 8 格:超开指标(气球回收 / KSM 复用;检出=红,未检出=绿,参考 nodequality)
    local ovs=""
    if [ -n "${G[oversell_balloon]:-}${G[oversell_ksm]:-}" ]; then
        ovs="<div class=\"ovs-chips\">"
        ovs+="<span class=\"ovs$( [ "${G[oversell_balloon]:-0}" = 1 ] && printf ' hit' )\" title=\"virtio_balloon 驱动$( [ "${G[oversell_balloon]:-0}" = 1 ] && printf ' 已加载,宿主机可气球回收内存' || printf ' 未加载' )\">$( [ "${G[oversell_balloon]:-0}" = 1 ] && printf '✔' || printf '✘' ) 气球回收</span>"
        ovs+="<span class=\"ovs$( [ "${G[oversell_ksm]:-0}" = 1 ] && printf ' hit' )\" title=\"KSM 内存页合并$( [ "${G[oversell_ksm]:-0}" = 1 ] && printf ' 已开启(同宿主机超售特征)' || printf ' 未开启' )\">$( [ "${G[oversell_ksm]:-0}" = 1 ] && printf '✔' || printf '✘' ) KSM 复用</span>"
        ovs+="</div>"
    else
        ovs='<div class="ovs-chips"><span class="na">待检测</span></div>'
    fi
    bench+="<div class=\"bench-metric\"><label>超开指标</label>${ovs}<small>气球回收 · KSM 复用</small></div>"
    {
        printf '<section class="card spec-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">服务器基本信息</h2>' "$HQ_ICON_SPEC"
        printf '<button class="help">?<span class="tooltip">%s</span></button></div><div class="spec-grid">%s</div>' "$TIP_SYS" "$cells"
        printf '<div class="server-benchmark"><div class="server-benchmark-head"><span>CPU / 内存 / 磁盘跑分</span><small>sha256 · dd · FIO</small></div><div class="server-benchmark-metrics">%s</div></div></section>' "$bench"
    }
}

# ---- 三网卡(v4 实测 + v6 延迟行, 运营商 logo) ----
hq_china_card() {
    local out="" isp line down up rtt loss re vd vcls rcls v6a v6l v6t found v6d6 v6u6 v6src
    local -A V6MAP=()
    local -A V6SPD=()
    local -A V6LN=()
    for v6row in ${V6LINE_ROWS[@]+"${V6LINE_ROWS[@]}"}; do
        IFS='|' read -r isp v6ln <<< "$v6row"
        V6LN[$isp]=${v6ln:-}
    done
    local v6row
    for v6row in ${CHINA6_ROWS[@]+"${CHINA6_ROWS[@]}"}; do
        IFS='|' read -r isp v6a v6l <<< "$v6row"
        V6MAP[$isp]="$v6a|$v6l"
    done
    for v6row in ${V6TOS_ROWS[@]+"${V6TOS_ROWS[@]}"}; do
            IFS='|' read -r isp v6d6 v6u6 v6src <<< "$v6row"
            V6SPD[$isp]="${v6d6:-}|${v6u6:-}|${v6src:-}"
    done
    local c
    for c in 电信 联通 移动; do
        found=0
        local row_
        for row_ in ${CNMTX_ROWS[@]+"${CNMTX_ROWS[@]}"}; do
            IFS='|' read -r isp line down up rtt loss re vd <<< "$row_"
            [ "$isp" = "中国$c" ] || continue
            found=1
            case "$vd" in 优秀|良好) vcls=good ;; 一般) vcls=warn ;; 异常|受限) vcls=bad ;; *) vcls=pending ;; esac
            if is_num "$re"; then rcls=$(awk -v v="$re" 'BEGIN{print (v<1)?"good":(v<5)?"warn":"bad"}'); else rcls=pending; fi
            out+="<tr><td rowspan=\"2\"><span class=\"carrier\"><span class=\"carrier-logo\">$(hq_logo "$c")</span>中国$c</span></td>"
            out+="<td><span class=\"protocol-tag v4\">IPv4</span></td><td><span class=\"route-name\">$(esc "${line:-待检测}")</span></td>"
            out+="<td class=\"num\">$(is_num "$down" && printf '%s' "$down" || printf -- '—')</td>"
            out+="<td class=\"num\">$(is_num "$up" && printf '%s' "$up" || printf -- '—')</td>"
            out+="<td class=\"num\">$(is_num "$rtt" && printf '%s' "$rtt" || printf -- '—')</td>"
            out+="<td><span class=\"cell ${rcls}\">$(is_num "$re" && printf '%s' "$re" || printf -- '—')%%</span></td>"
            out+="<td><span class=\"cell ${vcls}\">${vd}</span></td></tr>"
            break
        done
        if [ "$found" = 0 ]; then
            out+="<tr><td rowspan=\"2\"><span class=\"carrier\"><span class=\"carrier-logo\">$(hq_logo "$c")</span>中国$c</span></td>"
            out+="<td><span class=\"protocol-tag v4\">IPv4</span></td><td><span class=\"route-name muted-route\">待检测</span></td><td>—</td><td>—</td><td>—</td><td><span class=\"cell pending\">—</span></td><td><span class=\"cell pending\">待检测</span></td></tr>"
        fi
        v6t=${V6MAP[$c]:-}
        if [ -n "$v6t" ]; then
            IFS='|' read -r v6a v6l <<< "$v6t"
            local lcls=pending
            is_num "$v6l" && lcls=$(awk -v v="$v6l" 'BEGIN{print (v==0)?"good":(v<20)?"warn":"bad"}')
            IFS='|' read -r v6d6 v6u6 v6src <<< "${V6SPD[$c]:-||}"
            local v6ln_html='<span class="route-name muted-route">待检测</span>'
            [ -n "${V6LN[$c]:-}" ] && v6ln_html="<span class=\"route-name\">$(esc "${V6LN[$c]}")</span>"
            local v6vd=待检测 v6vc=pending v6lt=""
            if is_num "$v6a"; then
                if is_num "$v6l" && [ "$(awk -v v="$v6l" 'BEGIN{print (v>=20)?1:0}')" = 1 ]; then v6vd=异常; v6vc=bad; else v6vd=良好; v6vc=good; fi
            elif is_num "$v6l" && [ "$v6l" -ge 100 ] 2>/dev/null; then
                v6vd=无应答; v6vc=bad
                v6lt=" title=\"探测包全部无应答:目标不答 ICMPv6、被过滤或路由不通,非程序错误\""
            elif is_num "$v6l"; then
                v6vd=异常; v6vc=bad
            fi
            # v6 测速:tos6=TOS family6 节点实测;空=未检测(运营商 v6 定向测速节点暂缺,如实标注)
            local v6chip="" t6spd="未检测:运营商暂无公共 IPv6 定向测速节点,TOS 节点表提供 v6 入口后自动实测;本行延迟/丢包仍为运营商 v6 实测"
            case "$v6src" in
                tos6)   t6spd="运营商 TOS v6 定向入口单线程实测(分运营商)"
                        v6chip='<span style="font-size:8px;color:#7142bd;margin-left:2px" title="运营商 TOS v6 定向入口实测">TOS</span>' ;;
            esac
            out+="<tr class=\"ipv6-row\"><td><span class=\"protocol-tag v6\">IPv6</span></td><td>${v6ln_html}</td><td class=\"num\" title=\"${t6spd}\">$(is_num "$v6d6" && printf '%s' "$v6d6" || printf -- '—')${v6chip}</td><td class=\"num\" title=\"${t6spd}\">$(is_num "$v6u6" && printf '%s' "$v6u6" || printf -- '—')${v6chip}</td>"
            out+="<td class=\"num\">$(is_num "$v6a" && printf '%s' "$v6a" || printf -- '—')</td>"
            out+="<td><span class=\"cell ${lcls}\"${v6lt}>$(is_num "$v6l" && printf '%s' "$v6l" || printf -- '—')%%</span></td>"
            out+="<td><span class=\"cell ${v6vc}\">${v6vd}</span></td></tr>"
        else
            out+="<tr class=\"ipv6-row\"><td><span class=\"protocol-tag v6\">IPv6</span></td><td><span class=\"route-name muted-route\">待检测</span></td><td>—</td><td>—</td><td>—</td><td><span class=\"cell pending\">—</span></td><td><span class=\"cell pending\">待检测</span></td></tr>"
        fi
    done
    printf '<section class="card china-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">中国大陆三网线路与测速</h2><button class="help">?<span class="tooltip">%s</span></button></div><div class="china-wrap"><table class="data-table china-table"><thead><tr><th>运营商</th><th>协议</th><th>回程线路</th><th title="v4 为运营商定向单线程实测;IPv6 测速待运营商 v6 定向测速节点可用后实测(当前 — 为未检测),延迟/丢包为运营商 v6 实测">下载<br>Mbps</th><th>上传<br>Mbps</th><th>延迟<br>ms</th><th>重传/丢包<br>%%</th><th>评价</th></tr></thead><tbody>%s</tbody></table></div></section>' \
        "$HQ_ICON_CHINA" "$TIP_CN" "$out"
}

# 国际互联品牌 SVG 图标(简化矢量,12px 级可辨识)
hq_brand_icon() { # <名称>
    case "$1" in
        *Google*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M12 4a8 8 0 1 0 7.4 11h-2.3A5.7 5.7 0 1 1 12 6.3c1.6 0 3 .6 4 1.6l1.6-1.6A8 8 0 0 0 12 4z" fill="#4285F4"/><path d="M19.6 9.5H12v2.4h5.6c-.4 1.6-1.7 2.6-3.1 3l1.5 2c2.6-1 4.5-3.5 4.5-6.4 0-.4 0-.7-.1-1z" fill="#FBBC05"/><path d="M8.2 6.9l1.9 1.4a5.7 5.7 0 0 1 3.5-1.3V4a8 8 0 0 0-5.4 2.9z" fill="#EA4335"/><path d="M6.3 12c0-.9.2-1.7.5-2.5L4.9 8.1A8 8 0 0 0 4 12c0 1.4.4 2.8 1.1 3.9l1.8-1.4c-.4-.7-.6-1.6-.6-2.5z" fill="#34A853"/></svg>' ;;
        *YouTube*) printf '%s' '<svg viewBox="0 0 24 24"><rect x="1.5" y="5.5" width="21" height="13" rx="4" fill="#FF0000"/><path d="M10 9l6 3-6 3z" fill="#fff"/></svg>' ;;
        *GitHub*) printf '%s' '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#181717"/><path d="M9 19c-3 1-3-1.5-4-2 2 .3 3-.6 3-2-2-1-3-3-2-5 .5-1 1.5-1.8 2-2 0-1 .5-2 1.5-2.3C10.5 5 12 5 12 5s1.5 0 2.5.7C15.5 6 16 7 16 8c.5.2 1.5 1 2 2 1 2 0 4-2 5 0 1.4 1 2.3 3 2-1 .5-1 3-4 2" fill="none" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>' ;;
        *Cloudflare*|*cloudflare*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M7 15a3.5 3.5 0 0 1 .6-7 4.6 4.6 0 0 1 8.6-1 3.8 3.8 0 0 1 .4 7.6z" fill="#F6821F"/><circle cx="17" cy="16.5" r="4" fill="#FBAD41"/></svg>' ;;
        *Telegram*) printf '%s' '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#2AABEE"/><path d="m6.5 11.6 9.8-3.8c.5-.2 1 .1.8.9l-1.7 7.8c-.1.6-.5.7-1 .5l-2.7-2-1.3 1.3c-.2.2-.3.3-.6.3l.2-2.9 5.3-4.8c.2-.2 0-.3-.3-.1l-6.5 4.1-2.8-.9c-.6-.2-.6-.6.8-1.2z" fill="#fff"/></svg>' ;;
        *Wikipedia*) printf '%s' '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#000"/><text x="12" y="16.5" font-size="11" font-weight="800" fill="#fff" text-anchor="middle" font-family="Georgia,serif">W</text></svg>' ;;
        *Netflix*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M6 2h4l1 9 1-9h4v20l-3 .5V10l-1.5 11L11 9.5V22l-3-.5z" fill="#E50914"/></svg>' ;;
        *Discord*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M8.5 5C6 5 4 6 4 6s-1 3-1 6c0 3 2 7 2 7l2.5.5c.5-1 .8-2 .8-2s2 .8 4.2.8 4.2-.8 4.2-.8.3 1 .8 2L21 19s2-4 2-7c0-3-1-6-1-6s-2-1-4.5-1c0 0-1.5 0-2.7.8h-2.6C10 5 8.5 5 8.5 5z" fill="#5865F2"/><circle cx="9" cy="12.5" r="1.6" fill="#fff"/><circle cx="15" cy="12.5" r="1.6" fill="#fff"/></svg>' ;;
        *ChatGPT*|*OpenAI*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M12 3l3 2 3.5-.5L20 8l2 3-1.5 3.5.5 3.5-3 2-2 3-3.5-1-3.5 1-2-3-3-2 .5-3.5L4 11l2-3 1.5-3.5L11 5z" fill="none" stroke="#10A37F" stroke-width="1.6"/><circle cx="12" cy="12" r="3.2" fill="#10A37F"/></svg>' ;;
        *X*|*x.com*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M4 4l16 16M20 4L4 20" stroke="#000" stroke-width="2.6" stroke-linecap="round"/></svg>' ;;
        *CDNjs*|*jsDelivr*|*UNPKG*|*GoogleLib*|*CDN*) printf '%s' '<svg viewBox="0 0 24 24"><path d="M7 17a4 4 0 0 1 .5-8 5.4 5.4 0 0 1 10.2-1.2A4.2 4.2 0 0 1 17.5 17z" fill="#8a97a8"/><path d="M12 19l3-4h-2.2l.7-2.6-3.3 4.4h2.1z" fill="#f4a62a"/></svg>' ;;
        *) printf '%s' '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8" fill="none" stroke="#6b82a3" stroke-width="2"/><circle cx="12" cy="12" r="2.4" fill="#6b82a3"/></svg>' ;;
    esac
}

# ---- 国际多区域卡 ----
hq_intl_card() {
    local out="" r name st dl r1 r2 re scls flagk flag fcls nr up_txt
    local up_txt2
    for r in ${INTLSPD_ROWS[@]+"${INTLSPD_ROWS[@]}"}; do
        IFS='|' read -r name st dl up r1 r2 re <<< "$r"
        case "$st" in 优|良好) scls="" ;; 一般|部分) scls=warn ;; *) scls=pending ;; esac
        flagk=$(intl_flag "$name")
        flag=$(hq_flag_svg "$flagk")
        fcls="flag"
        [ "$flagk" = apple ] && fcls="flag apple-flag"
        [ -z "$flag" ] && flag="<span></span>"
        local dl_txt lat_txt re_txt
        dl_txt="—"; is_num "$dl" && dl_txt="$dl"
        if [ -n "${r1:-}" ] || [ -n "${r2:-}" ]; then lat_txt="◎ ${r1:-—}/${r2:-—} ms"; else lat_txt="◎ — ms"; fi
        re_txt="—"; is_num "$re" && re_txt="⇄ ${re}%"
        out+="<div class=\"intl-item\"><div class=\"intl-top\"><span class=\"${fcls}\">${flag}</span><span class=\"intl-name\">$(esc \"$name\")</span><span class=\"intl-state ${scls}\">${st}</span></div>"
        up_txt2="待检测"; is_num "$up" && [ "$(awk -v v="$up" 'BEGIN{print (v>0)?1:0}')" = 1 ] && up_txt2="$up"
        out+="<div class=\"intl-speeds\"><span class=\"intl-speed\">↓ ${dl_txt} <small>Mbps</small></span><span class=\"intl-speed up\" title=\"Ookla 城市服务器 upload.php 单连接实测;无可用端点时如实标待检测\">↑ ${up_txt2} <small>Mbps</small></span></div>"
        out+="<div class=\"intl-bottom\"><span class=\"lat\">${lat_txt}</span><span class=\"loss\">${re_txt}</span></div></div>"
    done
    # 国际互联条(主流厂牌延迟 + CDN 资源,单行,主流在前)
    local brand_out="" bname bdisp bms blvl bcls bshort
    for b in ${INTL_ROWS[@]+"${INTL_ROWS[@]}"}; do
        IFS='|' read -r bname bdisp bms blvl <<< "$b"
        bcls=good; [ "$blvl" = warn ] && bcls=warn; [ "$blvl" = bad ] && bcls=bad
        brand_out+="<span class=\"brand-chip ${bcls}\">$(hq_brand_icon "$bname")<i>${bname}</i><b>${bdisp:-—}</b></span>"
    done
    for b in ${CDN_ROWS[@]+"${CDN_ROWS[@]}"}; do
        IFS='|' read -r bname bdisp bms blvl <<< "$b"
        bcls=good; [ "$blvl" = warn ] && bcls=warn; [ "$blvl" = bad ] && bcls=bad
        case "$bname" in CDNjs|jsDelivr|UNPKG|GoogleLib) bshort="CDN·$bname" ;; *) bshort="CDN·$bname" ;; esac
        brand_out+="<span class=\"brand-chip cdn ${bcls}\">$(hq_brand_icon "$bname")<i>${bshort}</i><b>${bdisp:-—}</b></span>"
    done
    [ -n "$brand_out" ] && brand_out="<div class=\"intl-brand-strip\">${brand_out}</div>"
    printf '<section class="card international"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">国际多区域测速</h2><button class="help">?<span class="tooltip">%s</span></button><div class="legend"><span><i class="dot down"></i>下载 Mbps</span><span><i class="dot up"></i>上传</span><span><i class="dot lat"></i>握手延迟 ms</span><span><i class="dot loss"></i>重传 %%</span></div></div><div class="intl-grid">%s</div>%s</section>' \
        "$HQ_ICON_INTL" "$TIP_INTL" "$out" "$brand_out"
}

# ---- 回程质量卡(环形图 + 逐运营商×包长) ----
hq_route_card() { # <4|6>
    local fam=$1 ok tot pct tone lbl badge note
    ok=${G[prov${fam}_ok]:-}; tot=${G[prov${fam}_total]:-}
    local _isTcp=0 _szTip="ICMP 包径探测:64/512/1200/1400B,v4 置 DF 禁分片;IPv6 无 DF 位(超 MTU 显示超MTU)"
    if [ "${G[mtu_proto]:-icmp}" = tcp ]; then
        _isTcp=1
        _szTip="TCP 载荷探测:对三网省网节点 80 端口发送 64/512/1200/1400B HTTP 请求,每档 3 次;丢包=失败率,延迟含节点响应,略高于纯 ping 属正常"
    fi
    local calib="口径:左图为 ${tot:-93} 个省份测点(每格 4 个 ICMP 包)零丢包概览;右表为$([ "$_isTcp" = 1 ] && printf 'TCP 载荷实测(64/512/1200/1400B,延迟略高于 ping 属正常)' || printf 'ICMP 包径探测(64/512/1200/1400B)'),TCP·443 行为握手失败率(即 TCP 层丢包率)。"
    if ! is_num "$tot" || [ "$tot" -lt 1 ] 2>/dev/null; then
        pct=""; tone=pending; lbl="未检测"
        note="未检测:主机无该协议地址或本次未纳入测点,不代表检测失败。"
    else
        pct=$(awk -v o="${ok:-0}" -v t="$tot" 'BEGIN{p=o*100/t; if(p>100)p=100; printf "%.1f", p}')
        if [ "${ok:-0}" -eq 0 ] 2>/dev/null; then
            tone=bad; lbl="省份测点全部异常"
            note="${calib}省份测点:0/${tot} 零丢包(异常率 100%);可能存在路由、策略或封锁问题,建议结合应用层连通性复测。"
        elif [ "$(awk -v p="$pct" 'BEGIN{print (p>=95)?1:0}')" = 1 ]; then
            tone=good; lbl="省份零丢包 ${pct}%"
            note="${calib}省份测点:${ok}/${tot} 零丢包(零丢包率 ${pct}%);右表为载荷与 TCP 握手实测。"
        else
            local bad_n=$(( tot - ok ))
            local badp
            badp=$(awk -v o="${ok:-0}" -v t="$tot" 'BEGIN{printf "%.1f", (t-o)*100/t}')
            if [ "$(awk -v p="$pct" 'BEGIN{print (p>=50)?1:0}')" = 1 ]; then tone=warn; lbl="部分省份丢包 · 零丢包 ${pct}%"; else tone=bad; lbl="多数省份丢包 · 零丢包 ${pct}%"; fi
            note="${calib}省份测点:${ok}/${tot} 零丢包,${bad_n} 个测点丢包(丢包率 ${badp}%);右表为单入口目标,与省份网格结果可能不同。"
        fi
    fi
    local prow="" sz ci carrier cell_r cell_l cell_ov ccls prefix nm szl ls rt r__ ov6
    local -a carr=(电信 联通 移动)
    local thead="<tr><th title=\"${_szTip}\">$([ "$_isTcp" = 1 ] && printf '载荷' || printf '包长')</th><th><span class=\"carrier-col-head\"><span class=\"carrier-logo\">$(hq_logo 电信)</span>电信</span></th><th><span class=\"carrier-col-head\"><span class=\"carrier-logo\">$(hq_logo 联通)</span>联通</span></th><th><span class=\"carrier-col-head\"><span class=\"carrier-logo\">$(hq_logo 移动)</span>移动</span></th></tr>"
    local -a _szs=(64 512 1200 1400)
    for sz in "${_szs[@]}"; do
        prow+="<tr><td><b>${sz} B</b></td>"
        for ci in 0 1 2; do
            carrier=${carr[$ci]}
            [ "$fam" = 6 ] && prefix="v6" || prefix=""
            cell_r=""; cell_l=""; cell_ov=""
            for r__ in ${MTU_ROWS[@]+"${MTU_ROWS[@]}"}; do
                IFS='|' read -r nm szl ls rt ov6 <<< "$r__"
                [ "$nm" = "${prefix}${carrier}" ] || continue
                [ "$szl" = "${sz}B" ] || continue
                cell_r=$rt; cell_l=$ls; cell_ov=${ov6:-}
            done
            is_num "$cell_l" && [ "$(awk -v v="$cell_l" 'BEGIN{print (v>100)?1:0}')" = 1 ] && cell_l=100
            if is_num "$cell_l"; then
                ccls=$(awk -v v="$cell_l" 'BEGIN{print (v==0)?"good":(v<30)?"warn":"bad"}')
                local _lt6=""
                [ "$cell_l" -ge 100 ] 2>/dev/null && ! is_num "$cell_r" && _lt6=" title=\"$([ "$_isTcp" = 1 ] && printf '该档位 3 次 TCP 探测全部失败:路径丢弃该尺寸数据包或节点不可达' || printf '探测包全部无应答:目标不答 ICMP/ICMPv6、被过滤或超过路径 MTU')\""
                [ -z "$_lt6" ] && _lt6=" title=\"${_szTip}\""
                prow+="<td class=\"carrier-avg ${ccls}\"${_lt6}><span class=\"avg-main\"><b>$(is_num "$cell_r" && printf '%.1f' "$cell_r" || printf -- '—')</b><i>ms</i></span><span class=\"avg-sub\">丢包 $(printf '%s' "$cell_l")%</span></span></td>"
            elif [ "$cell_ov" = "1" ] || [ "$cell_ov" = "over" ]; then
                prow+='<td class="carrier-avg pending" title="载荷+包头超过链路 MTU,探测包未能发出(IPv6 无 DF 位)"><span class="avg-main"><b>超MTU</b></span></td>'
            else
                prow+='<td class="carrier-avg pending"><span class="avg-main"><b>待测</b></span></td>'
            fi
        done
        prow+="</tr>"
    done

    # TCP 握手行:握手失败率即 TCP 层丢包率
    # v4:运营商 TOS 入口分运营商;v6:TOS 公网入口无 AAAA,用运营商自有地址段门户 v6 入口(240e/2408/2409)
    local tcprow="" tcls tnm t4a t4f t6a t6f t6ip
    tcprow="<tr><td><b>TCP·443</b></td>"
    local tcpTip="TCP 443 多次握手的失败率(TCP 层丢包率)与握手均值"
    if [ "$fam" = 4 ]; then
        for ci in 0 1 2; do
            carrier=${carr[$ci]}
            t4a=""; t4f=""
            for r__ in ${TCP_ROWS[@]+"${TCP_ROWS[@]}"}; do
                IFS='|' read -r tnm _tip _av _fl _ <<< "$r__"
                [ "$tnm" = "${carrier}·TOS" ] && { t4a=$_av; t4f=$_fl; }
            done
            if is_num "$t4f"; then
                tcls=$(awk -v v="$t4f" 'BEGIN{print (v==0)?"good":(v<30)?"warn":"bad"}')
                tcprow+="<td class=\"carrier-avg ${tcls}\" title=\"${tcpTip},目标为运营商 TOS 入口\"><span class=\"avg-main\"><b>$(is_num "$t4a" && printf '%.1f' "$t4a" || printf -- '—')</b><i>ms</i></span><span class=\"avg-sub\">丢包 ${t4f}%</span></td>"
            else
                tcprow+="<td class=\"carrier-avg pending\" title=\"TCP 握手探测未取得结果(探测被跳过或目标不可达)\"><span class=\"avg-main\"><b>待测</b></span></td>"
            fi
        done
    else
        for ci in 0 1 2; do
            carrier=${carr[$ci]}
            t6a=""; t6f=""; t6ip=""
            for r__ in ${TCP6_ROWS[@]+"${TCP6_ROWS[@]}"}; do
                IFS='|' read -r tnm t6ip t6a t6f _ <<< "$r__"
                [ "$tnm" = "${carrier}·门户v6" ] && break || { t6a=""; t6f=""; }
            done
            if is_num "$t6f"; then
                tcls=$(awk -v v="$t6f" 'BEGIN{print (v==0)?"good":(v<30)?"warn":"bad"}')
                tcprow+="<td class=\"carrier-avg ${tcls}\" title=\"${tcpTip},目标为运营商自有地址段门户 v6 入口(${t6ip:-门户});TOS 公网入口暂无 AAAA\"><span class=\"avg-main\"><b>$(is_num "$t6a" && printf '%.1f' "$t6a" || printf -- '—')</b><i>ms</i></span><span class=\"avg-sub\">丢包 ${t6f}%</span></td>"
            else
                tcprow+="<td class=\"carrier-avg pending\" title=\"无 IPv6、未启用 v6 探测或门户 v6 入口不可达,未取得 TCP 握手数据\"><span class=\"avg-main\"><b>待测</b></span></td>"
            fi
        done
    fi
    tcprow+="</tr>"

    {
        printf '<section class="card route-card" data-tone="%s"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">IPv%s 回程质量</h2>' "$tone" "$HQ_ICON_CHINA" "$fam"
        printf '<button class="help">?<span class="tooltip">%s</span></button></div>' "$TIP_ROUTE"
        printf '<div class="route-body"><div class="route-summary"><div class="route-summary-top"><span class="donut" style="--pct:%s%%"></span><span class="route-count">%s<small>/%s</small></span></div>' "${pct:-0}" "${ok:-—}" "${tot:-—}"
        printf '<div class="route-main-label">%s</div><div class="route-progress"><span>%s/%s 测点</span><span class="route-progress-bar"><b style="width:%s%%"></b></span><span>%s</span></div><div class="route-note">%s</div></div>' \
            "$lbl" "${ok:-0}" "${tot:-—}" "${pct:-0}" "${pct:-—}" "$(esc "$note")"
        printf '<div class="packet-table"><table class="data-table"><thead>%s</thead><tbody>%s%s</tbody></table></div></div></section>' "$thead" "$prow" "$tcprow"
    }
}

# ---- IP 风险卡 ----
# v2.6:IP 类型(原生/广播)与使用类型(机房/商业/家宽…)彩色徽章;
#      ipapi.is 分数行移除(评级仍综合两源);DNSBL 行升级为全量黑名单数据库四色块
hq_risk_panel() { # <4|6>
    local fam=$1 head s1 s2 u org asn comp geo dh dt
    local nat nat_reg nat_geo ucat ukey bvalid bclean bmarked bblack
    if [ "$fam" = 4 ]; then
        head="IPv4 风险与归属"
        s1=${G[fraud_score]:-}; s2=${G[fraud2_score]:-}
        u=${G[ip_usage]:-}; org=${G[company_name]:-${G[as_org]:-}}; asn=${G[as_full]:-}
        comp=${G[company_type]:-}; geo="${G[loc_country]:-} ${G[loc_city]:-}"
        nat=${G[ip_native]:-}; nat_reg=${G[native_reg]:-}; nat_geo=${G[native_geo]:-}
        ucat=${G[ip_usage_cat]:-}; ukey=${G[ip_usage_key]:-}
        bvalid=${G[dnsbl_valid]:-}; bclean=${G[dnsbl_clean]:-}; bmarked=${G[dnsbl_marked]:-}; bblack=${G[dnsbl_black]:-}
    else
        head="IPv6 风险与归属"
        s1=${G[ipq6_score]:-}; s2=${G[ipq6_score2]:-}
        u=${G[ipq6_usage]:-}; org=${G[company6]:-${G[as6_org]:-}}; asn=${G[asn6]:-}
        comp=""; geo=${G[geo6]:-}
        nat=${G[ip_native6]:-}; nat_reg=${G[native6_reg]:-}; nat_geo=${G[native6_geo]:-}
        ucat=${G[ipq6_usage_cat]:-}; ukey=${G[ipq6_usage_key]:-}
        bvalid=${G[dnsbl6_valid]:-}; bclean=${G[dnsbl6_clean]:-}; bmarked=${G[dnsbl6_marked]:-}; bblack=${G[dnsbl6_black]:-}
    fi
    local grade=待检测 gcls=pending avg
    if is_num "$s1" || is_num "$s2"; then
        avg=$(awk -v a="${s1:--1}" -v b="${s2:--1}" 'BEGIN{if(a<0&&b<0)print -1; else if(a<0)print b; else if(b<0)print a; else print (a+b)/2}')
        grade=$(awk -v v="$avg" 'BEGIN{print (v<25)?"低风险":(v<60)?"中风险":"高风险"}')
        gcls=$(awk -v v="$avg" 'BEGIN{print (v<25)?"good":(v<60)?"warn":"bad"}')
    fi
    local src1 vcls1
    if is_num "$s1"; then vcls1=$(awk -v v="$s1" 'BEGIN{print (v>=60)?"bad":(v>=25)?"warn":"good"}'); src1="<b class=\"${vcls1}\">${s1} / 100</b>"; else src1='<b class="pending">待检测</b>'; fi
    local proxy_v tor_v
    if [ "$fam" = 4 ]; then
        if [ "${G[proxy]:-}" = true ]; then proxy_v='<b class="bad">是</b>'; elif [ -n "${G[proxy]:-}" ]; then proxy_v='<b class="good">否</b>'; else proxy_v='<b class="pending">待检测</b>'; fi
        if [ "${G[abuser]:-}" = true ] || [ "${G[tor]:-}" = true ]; then tor_v='<b class="bad">是</b>'; elif [ -n "${G[abuser]:-}" ] || [ -n "${G[tor]:-}" ]; then tor_v='<b class="good">否</b>'; else tor_v='<b class="pending">待检测</b>'; fi
    else
        proxy_v='<b class="pending">待检测</b>'; tor_v='<b class="pending">待检测</b>'
    fi
    # IP 类型徽章:原生=绿底 / 广播=红底(title 显示注册国 vs 部署国)
    local nat_v
    case "$nat" in
        1) nat_v="<span class=\"ntv ntv-native\" title=\"注册国 ${nat_geo} 与部署国一致\">原生</span>" ;;
        0) nat_v="<span class=\"ntv ntv-bcast\" title=\"注册国 ${nat_reg} / 部署国 ${nat_geo}\">广播</span>" ;;
        *) nat_v='<b class="pending">待检测</b>' ;;
    esac
    # 使用类型徽章:机房=红 / 商业=黄 / 家宽=绿 / 手机=青 / 其他=蓝或灰
    local use_v
    if [ -n "$ucat" ]; then
        use_v="<span class=\"utg utg-${ukey:-cdn}\" title=\"${u:-归一化类别}\">${ucat}</span>"
    elif [ -n "$u" ]; then
        use_v="<b>$(esc "$(printf '%s' "$u" | cut -c1-16)")</b>"
    else
        use_v='<span class="na">待检测</span>'
    fi
    {
        printf '<div class="risk-panel%s"><div class="risk-head"><span>%s</span><span class="risk-grade %s">%s</span></div>' "$([ "$fam" = 6 ] && printf ' v6')$( [ -n "$gcls" ] && printf ' t-%s' "$gcls" || printf ' t-pending')" "$head" "$gcls" "$grade"
        printf '<div class="risk-line"><span>Scamalytics</span>%s</div>' "$src1"
        printf '<div class="risk-line"><span>Proxy / VPN</span>%s</div><div class="risk-line"><span>Tor / Abuser</span>%s</div>' "$proxy_v" "$tor_v"
        printf '<div class="risk-line"><span>IP 类型</span>%s</div><div class="risk-line"><span>使用类型</span>%s</div>' "$nat_v" "$use_v"
        printf '<div class="risk-line"><span>归属组织</span><b title="%s">%s</b></div>' "$(esc "$org")" "$( [ -n "$org" ] && printf '%s' "$(esc "$(printf '%s' "$org" | cut -c1-22)")" || printf '<span class="na">待检测</span>')"
        printf '<div class="risk-line"><span>ASN</span><b title="%s">%s</b></div>' "$(esc "$asn")" "$( [ -n "$asn" ] && printf '%s' "$(esc "$(printf '%s' "$asn" | cut -c1-22)")" || printf '<span class="na">待检测</span>')"
        # 注册地(Cymru 注册国)/ 使用地(实际部署国),nodequality 口径;黑名单数据库见邮件卡
        printf '<div class="risk-meta"><div class="risk-line"><span>注册地</span>%s</div><div class="risk-line"><span>使用地</span>%s</div></div></div>' \
            "$( [ -n "$nat_reg" ] && printf '<b title="IP 段注册国">%s</b>' "$(cc_name "$nat_reg")" || printf '<b class="pending">待检测</b>' )" \
            "$( [ -n "$nat_geo" ] && printf '<b title="%s">%s</b>' "$(esc "${geo:-$nat_geo}")" "$(cc_name "$nat_geo")" || printf '<b class="pending">待检测</b>' )"
    }
}
hq_risk_card() {
    printf '<section class="card risk-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">IP 风险与归属</h2><button class="help">?<span class="tooltip">%s</span></button></div><div class="risk-columns">' "$HQ_ICON_RISK" "$TIP_RISK"
    hq_risk_panel 4
    hq_risk_panel 6
    printf '</div></section>'
}

# ---- 解锁卡 ----
hq_service_icon() {
    case "$1" in
        Netflix) printf '<span class="service-icon netflix">N</span>' ;;
        *YouTube*) printf '<span class="service-icon youtube">▶</span>' ;;
        *Disney*) printf '<span class="service-icon disney">D+</span>' ;;
        *Prime*) printf '<span class="service-icon prime">P</span>' ;;
        *Spotify*) printf '<span class="service-icon spotify">♪</span>' ;;
        *Hulu*) printf '<span class="service-icon hulu">h</span>' ;;
        TikTok) printf '<span class="service-icon tiktok">♪</span>' ;;
        Reddit) printf '<span class="service-icon reddit">r/</span>' ;;
        *Twitter*|*X*) printf '<span class="service-icon x">𝕏</span>' ;;
        Instagram) printf '<span class="service-icon instagram">◎</span>' ;;
        *OpenAI*) printf '<span class="service-icon ai-openai">%s</span>' "$(hq_ai_svg openai)" ;;
        Claude) printf '<span class="service-icon ai-claude">%s</span>' "$(hq_ai_svg claude)" ;;
        *Gemini*) printf '<span class="service-icon ai-gemini">%s</span>' "$(hq_ai_svg gemini)" ;;
        Perplexity) printf '<span class="service-icon ai-perplexity">%s</span>' "$(hq_ai_svg perplexity)" ;;
        *Copilot*) printf '<span class="service-icon ai-copilot">%s</span>' "$(hq_ai_svg copilot)" ;;
        Grok) printf '<span class="service-icon ai-grok">%s</span>' "$(hq_ai_svg grok)" ;;
        *) printf '<span class="service-icon">•</span>' ;;
    esac
}
hq_unlock_card() {
    local -a md=() sq=() ai=()
    local r svc st rg grp
    local st6x
    for r in ${MEDIA_ROWS[@]+"${MEDIA_ROWS[@]}"}; do
        IFS='|' read -r svc st rg grp st6x <<< "$r"
        case "$grp" in md) md+=("$svc|$st|${rg:-}|$st6x") ;; sq) sq+=("$svc|$st|${rg:-}|$st6x") ;; ai) ai+=("$svc|$st|${rg:-}|$st6x") ;; *) md+=("$svc|$st|${rg:-}|$st6x") ;; esac
    done
    local groups="" g gtitle arr row stt stc yes_n=0 tot_n=0
    local -a garr
    # 聚合模式:dual=双栈(v4+v6 参与裁决) / v6=仅 IPv6 / v4=仅 IPv4(或 v6 探测关闭)
    local mode=v4
    if [ -n "${G[ip6]:-}" ] && [[ $OPT_IPV == *6* ]]; then
        if [ -n "${G[ip4]:-}" ] && [[ $OPT_IPV == *4* ]]; then mode=dual; else mode=v6; fi
    fi
    for g in md sq ai; do
        case $g in
            md) gtitle="流媒体"; garr=("${md[@]+"${md[@]}"}") ;;
            sq) gtitle="社交";   garr=("${sq[@]+"${sq[@]}"}") ;;
            ai) gtitle="AI 服务"; garr=("${ai[@]+"${ai[@]}"}") ;;
        esac
        local gout="<div class=\"unlock-group\"><h3>${gtitle}<span class=\"unlock-count\"></span></h3>"
        for row in ${garr[@]+"${garr[@]}"}; do
            IFS='|' read -r svc st rg st6x <<< "$row"
            tot_n=$((tot_n+1))
            IFS='|' read -r stc stt <<< "$(hq_unlock_state "$st" "${st6x:-}" "$mode")"
            [ "$stc" = unlocked ] && yes_n=$((yes_n+1))
            local t4 t6
            case "$st" in
                yes) t4="已解锁" ;; orig) t4="仅自制" ;; no) t4="未解锁" ;; fail) t4="失败" ;; *) t4="待检测" ;;
            esac
            case "$st6x" in
                yes) t6="支持" ;; no) t6="未解锁/不通" ;; fail) t6="失败" ;; na) t6="服务无IPv6" ;; *) t6="未测" ;;
            esac
            [ -n "$rg" ] && rg=$(hq_region_html "$rg")
            gout+="<div class=\"unlock-row\"><span class=\"service-name\" title=\"IPv4:${t4} · IPv6:${t6}\">$(hq_service_icon "$svc")$(esc "$svc")$(hq_fam46 "$st" "${st6x:-}")</span><span class=\"unlock-result\"><span class=\"unlock-loc\">${rg}</span><span class=\"unlock-state ${stc}\" title=\"${stt}\">${stt}</span></span></div>"
        done
        gout+="</div>"
        groups+="$gout"
    done
    local pillc=pending
    [ "$tot_n" -gt 0 ] && [ "$yes_n" -eq "$tot_n" ] && pillc=good
    [ "$yes_n" -gt 0 ] && [ "$yes_n" -lt "$tot_n" ] && pillc=warn
    printf '<section class="card unlock-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">流媒体 / 社交 / AI 区域解锁</h2><button class="help">?<span class="tooltip">%s</span></button><span class="pill %s" style="margin-left:auto">%s/%s</span></div><div class="unlock-grid">%s</div><div class="unlock-foot">状态:<i class=\"lg-dot lg-g\"></i>已解锁(全部解锁) / <i class=\"lg-dot lg-y\"></i>部分解锁(单栈可用或仅自制) / <i class=\"lg-dot lg-r\"></i>未解锁 / <i class=\"lg-dot lg-v\"></i>失败 / <i class=\"lg-dot lg-n\"></i>待检测;双栈服务器按 IPv4+IPv6 聚合,单栈按实际栈呈现;区域以当前出口 IP 实测为准。</div></section>' \
        "$HQ_ICON_PLAY" "$TIP_MEDIA" "$pillc" "$yes_n" "$tot_n" "$groups"
}

# ---- 邮件卡 ----
hq_mail_card() {
    local MAILPROV_N=0
    [ -n "${MAILPROV_ROWS+x}" ] && MAILPROV_N=${#MAILPROV_ROWS[@]}
    local p25=na in25=na mr _p _port ob ib _st
    for mr in ${MAIL_ROWS[@]+"${MAIL_ROWS[@]}"}; do
        IFS='|' read -r _p _port ob ib _st <<< "$mr"
        [ "${_port:-}" = 25 ] && { p25=$ob; in25=$ib; break; }
    done
    local p25txt p25cls p25col ind
    case "$p25" in
        ok) p25txt="出站 ✓ 可连接"; p25cls=good; p25col="#0b8a4a" ;;
        blocked) p25txt="出站 ✗ 阻断"; p25cls=bad; p25col="#d11c3e" ;;
        *) p25txt="出站 待检测"; p25cls=pending; p25col="#c47a00" ;;
    esac
    case "$in25" in
        ok) ind="入站 ✓ 通" ;;
        refused) ind="入站 无监听" ;;
        blocked) ind="入站 ✗ 阻断" ;;
        *) ind="入站 待检测" ;;
    esac
    local dt=${G[dnsbl_valid]:-} dc=${G[dnsbl_clean]:-} dm=${G[dnsbl_marked]:-0} db=${G[dnsbl_black]:-0} dnsb
    if is_num "$dt" && [ "$dt" -gt 0 ] 2>/dev/null; then
        dnsb="<div class=\"dnsbl\"><label>IP 地址黑名单数据库</label><div class=\"dnsbl-values\"><span class=\"dv-v\">有效<b>${dt}</b></span><span class=\"dv-c\">正常<b>${dc}</b></span><span class=\"dv-m\">已标记<b>${dm}</b></span><span class=\"dv-b\">黑名单<b>${db}</b></span></div></div>"
    else
        dnsb='<div class="dnsbl"><label>IP 地址黑名单数据库</label><div class="dnsbl-values"><span>有效<b>—</b></span><span>正常<b>—</b></span><span>已标记<b>—</b></span><span>黑名单<b>—</b></span></div></div>'
    fi
    local out="" pv pd pst pcls ptxt
    for pv in ${MAILPROV_ROWS[@]+"${MAILPROV_ROWS[@]}"}; do
        IFS='|' read -r pd pst <<< "$pv"
        case "$pst" in ok) pcls=good; ptxt="开放" ;; blocked) pcls=bad; ptxt="阻断" ;; *) pcls=pending; ptxt="待测" ;; esac
        out+="<div class=\"mail-provider\"><span class=\"provider-name\">$(esc "$pd")</span><span class=\"provider-state ${pcls}\">${ptxt}</span></div>"
    done
    [ -z "$out" ] && out='<div class="mail-provider"><span class="provider-name">待检测</span><span class="provider-state pending">—</span></div>'
    printf '<section class="card mail-card"><div class="section-head"><span class="section-icon">%s</span><h2 class="section-title">邮件 / 邮局连通性</h2><button class="help">?<span class="tooltip">%s</span></button></div><div class="mail-core"><div class="mail-port"><label>TCP/25</label><strong style="color:%s">%s</strong><small>%s</small></div>%s</div><div class="mail-provider-title"><span>邮局服务商 25 出站</span><span>%s 家</span></div><div class="mail-provider-grid">%s</div></section>' \
        "$HQ_ICON_MAIL" "$TIP_MAIL" "$p25col" "$p25txt" "$ind" "$dnsb" "${MAILPROV_N:-0}" "$out"
}

# ---------------- 主报告生成 ----------------
gen_report_html() {
    local host=${G[hostname]:-unknown}
    local safe_host ts dur durs
    safe_host=$(printf '%s' "$host" | tr -c '[:alnum:]-' '-' | sed 's/-*$//' | cut -c1-30)
    [ -z "$safe_host" ] && safe_host=host
    ts=$(date '+%Y%m%d_%H%M%S')
    if [ "$OPT_REPORT" = 1 ]; then
        REPORT_FILE="$OPT_OUTDIR/report_${safe_host}_${ts}.html"
    else
        # 默认不落盘:HTML 写入临时目录,退出随 $HQ_TMP 清除
        REPORT_FILE="$HQ_TMP/report.html"
    fi
    dur=$(( $(date +%s) - HQ_START_TS ))
    durs=$(awk -v s=$dur 'BEGIN{printf "%dm%02ds", int(s/60), s%60}')
    local isfull=0
    [ "$HQ_MODE" = full ] && isfull=1

    # ? 提示(8 段完整文案)
    local TIP_SCORE TIP_SYS TIP_CN TIP_INTL TIP_ROUTE TIP_RISK TIP_MEDIA TIP_MAIL
    TIP_SCORE=$(esc '综合评分 = 各维度加权(缺失项按剩余权重归一,总分向下取整)
• CPU 25%:单核 sha256 吞吐,150 分→30、1000+ 满分
• 内存 10%:单线程 tmpfs 写入,4GB/s 满分
• 磁盘 20%:4K 分量优先 FIO 随机读写 IOPS(直写,10 万 IOPS 满分)
• 网络 35%:最优测速上下行,1Gbps 满分
• IP 质量 10%:100 − 欺诈评分
超开扣分:检出气球回收,内存分 ×0.8;检出 KSM 复用,再 ×0.5
评分受环境与负载影响,仅供横向参考,非官方评级。')
    TIP_SYS=$(esc '上排 6 格 · 系统信息
• 处理器:核心数 + 型号摘要(悬浮查看完整型号)
• 虚拟化:平台 + 两枚徽章
  VT-x/AMD-V ✓(绿)= 支持嵌套虚拟化;红 ✗ = 宿主未开放
  AES ✓(绿)= 支持 AES-NI 硬件加密;红 ✗ = 不支持
下排 8 格 · 跑分(固定 8 格,缺数据显示待检测)
• CPU 单核 / 多核:sha256 吞吐(分/秒)
• 内存写入:tmpfs 单线程实测
• FIO 顺序读 / 写:1M 块吞吐
• FIO 4K 随机读 / 写:IOPS(iodepth=64,直写)
• 超开指标:✔ 气球回收 = 宿主可回收内存;✔ KSM 复用 = 页合并
  红色 ✔ = 检出超售特征;绿色 ✘ = 未检出
带宽 / 流量:标称(--plan-*)与实测分开展示。')
    TIP_CN=$(esc '按电信 / 联通 / 移动分别展示三个方向:
• 回程线路:回程方向骨干判定(如 9929、CMIN2、普通线路)
• 下载 / 上传:该运营商定向目标单线程实测
• 延迟 / 重传:该方向真实链路质量
IPv6 行:延迟/丢包为运营商 v6 实测;上下行在运营商
v6 定向测速节点可用前如实标未检测(—),不冒充数值
未返回的数据如实标"待检测",绝不从另一协议推算
单线程结果不代表总带宽。')
    TIP_INTL=$(esc '12 个固定区域,单线程逐区实测(每区域约 15 秒)
东京 · 新加坡 · 香港 · 伦敦 · 美西 · 美东
法兰克福 · 圣保罗 · 悉尼 · 多伦多 · 巴黎 · 阿姆斯特丹
• 下载:该区域测速文件直连 5 秒(香港为中国移动香港服务器)
• 上传:该城市 Ookla 服务器单连接
• 延迟:两次 TCP 握手实测(已剔除 DNS,可与 ping 对照)
• 重传:下载过程 ss -ti 采样
状态"部分"= 仅握手可达或上行可用
下方彩条:国际厂牌握手延迟 + CDN 静态资源真实拉取。')
    TIP_ROUTE=$(esc '左图 · 省份测点环形图
31 省 × 三网 = 93 测点,每格 4 个 ICMP 包,统计零丢包占比
100% 丢包自动复核一次;解析四级回退(阿里→腾讯→系统→DoH)
右表 · 载荷探测(默认 TCP)
对三网省网节点 80 端口发 64/512/1200/1400B HTTP 请求,每档 3 次
丢包=失败率;延迟含节点响应,略高于纯 ping 属正常
节点网格不可达时回退 ICMP DF(v6 超 MTU 显示"超MTU")
TCP·443 行:运营商入口 443 多次握手,失败率即 TCP 层丢包率
左图(ICMP)与右表(TCP)口径不同,单次测试不能定性')
    TIP_RISK=$(esc '• 欺诈分:Scamalytics(评级另综合 ipapi.is,多源不简单平均)
• IP 类型:注册国与部署国一致 → 原生(绿);不一致 → 广播(红)
  与底部"注册地 / 使用地"同一数据源
• 使用类型:机房(红)· 商业(黄)· 家宽(绿)· 手机(青)· 教育等(蓝)
  来源依次回退:ip2location → ipapi.is → ipinfo.io → ip-api
• 注册地:IP 段注册国(Team Cymru)
• 使用地:实际部署国
IP 地址黑名单数据库(全量约 420 域,四色块)在邮件卡展示。')
    TIP_MEDIA=$(esc '逐项显示:状态 · 识别地区 · 解锁类型(4|6 徽标分族)
• 已解锁:当前出口 IP 可访问完整内容
• 仅自制:仅平台自制内容可用
• 未解锁 / 失败:不可用或探测失败
双栈聚合:v4+v6 均解锁 = 全部解锁(绿)
其一解锁 = 部分解锁(黄);均未解锁 = 未解锁(红)
单栈服务器按实际协议族呈现,缺失的协议族不视为未解锁
结果受服务规则、账号地区、Cookie 影响
"待检测"不代表已解锁。')
    TIP_MAIL=$(esc '• TCP/25:出站能否连接邮局收件端口
• 邮局服务商:各服务商 25 端口出站连通性
• IP 地址黑名单数据库:对全量 DNSBL 域列表(约 420 家)DNS 查询
  有效 = 有明确应答的域数
  正常 = 未收录(NXDOMAIN / 无记录)
  已标记 = 返回 127.0.0.2 以外的 127.x 状态码
  黑名单 = 返回 127.0.0.2(确定收录)
端口连通 ≠ 邮件可投递:还受 PTR / SPF / DKIM / DMARC 影响。')
    export TIP_SCORE TIP_SYS TIP_CN TIP_INTL TIP_ROUTE TIP_RISK TIP_MEDIA TIP_MAIL

    # 骨架(引号 heredoc,占位行独占一行)
    cat >"$REPORT_FILE" <<'HTMLSKEL'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#0a56b0">
<title>Host QoS Report</title>
<style>
__HQCSS__
</style>
</head>
<body>
<header class="topbar">
  <a class="brand" href="__HOME_URL__" title="返回首页"><svg class="brand-cube" viewBox="0 0 48 48" aria-hidden="true"><path d="M24 2 44 13 24 24 4 13Z" fill="#e7f4ff"/><path d="M4 13 24 24v22L4 35Z" fill="#8fc8ff"/><path d="M44 13 24 24v22l20-11Z" fill="#c4e4ff"/></svg><div><div class="brand-title">Host QoS</div><div class="brand-sub">VPS 主机质量评测报告</div></div></a>
  <div class="vdivider"></div>
  <div class="server-head"><div class="server-name">__HOSTNAME__</div><div class="server-meta"><span>测试时间：<b>__TESTTIME__</b></span><i>|</i><span>测试位置：__TESTLOC__</span><i>|</i><span>评测平台：Host QoS v__HQVER__</span></div></div>
  <div class="head-actions"><a class="head-btn" id="fullreport" href="__ONLINE_URL__"><svg viewBox="0 0 24 24"><path d="M14 3h7v7M21 3 11 13M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>完整报告</a><button class="head-btn" onclick="window.print()" type="button"><svg viewBox="0 0 24 24"><path d="M6 9V3h12v6M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2M6 14h12v7H6z"/></svg>打印</button></div>
</header>
<main class="dashboard">
  <div class="top-grid">
__SCORE__
__SPEC__
__CHINA__
  </div>
__INTL__
  <div class="route-grid">
__ROUTE4__
__ROUTE6__
  </div>
  <div class="bottom-grid">
__RISK__
__UNLOCK__
__MAIL__
  </div>
  <div class="footer-note"><span>ⓘ <b>数据说明：</b>__FOOTNOTE__</span><span>Host QoS · VPS Quality Dashboard</span></div>
</main>
<script>
(function(){
 document.querySelectorAll('.help').forEach(function(h){h.addEventListener('click',function(e){document.querySelectorAll('.help.open').forEach(function(x){if(x!==h)x.classList.remove('open')});h.classList.toggle('open');e.stopPropagation()})});
 document.addEventListener('click',function(e){if(!e.target.closest('.help'))document.querySelectorAll('.help.open').forEach(function(x){x.classList.remove('open')})});
 var a=document.getElementById('fullreport');
 if(a&&(a.getAttribute('href')===''||a.getAttribute('href')==='#')){a.addEventListener('click',function(ev){ev.preventDefault();var t=document.getElementById('hqshare');if(t)try{navigator.clipboard.writeText(t.textContent)}catch(e){}});a.innerHTML='⧉ 复制摘要'}
})();
</script>
</body>
</html>
HTMLSKEL

    # 占位注入(bash 内存替换:兼容行内与整行占位,内容含任意字符皆安全)
    local _html
    _html=$(cat "$REPORT_FILE")
    local _esc_host _fn
    _esc_host="$(esc "$host")${OPT_TAG:+ <span style=\"opacity:.75;font-size:.7em\">$(esc "$OPT_TAG")</span>}"
    _fn="本报告由 HostQoS 在本机实测生成"
    [ $isfull = 0 ] && _fn="$_fn · 精简模式(完整明细未包含)"
    _fn="$_fn;未取得数据如实显示待检测。"
    _html=${_html//__HQCSS__/$HQ_PROTO_CSS}
    _html=${_html//__HOME_URL__/${OPT_SERVER%/}/}
    _html=${_html//__HOSTNAME__/${_esc_host}}
    _html=${_html//__TESTTIME__/$(esc "$HQ_START_TIME")}
    _html=${_html//__TESTLOC__/$(esc "${G[loc_country]:-?} ${G[loc_city]:-}")}
    _html=${_html//__HQVER__/$HQ_VERSION}
    _html=${_html//__FOOTNOTE__/${_fn}}
    _html=${_html//__SCORE__/$(hq_score_card)}
    _html=${_html//__SPEC__/$(hq_spec_card)}
    _html=${_html//__CHINA__/$(hq_china_card)}
    _html=${_html//__INTL__/$(hq_intl_card)}
    _html=${_html//__ROUTE4__/$(hq_route_card 4)}
    _html=${_html//__ROUTE6__/$(hq_route_card 6)}
    _html=${_html//__RISK__/$(hq_risk_card)}
    _html=${_html//__UNLOCK__/$(hq_unlock_card)}
    _html=${_html//__MAIL__/$(hq_mail_card)}
    printf '%s\n' "$_html" >"$REPORT_FILE"

    # 分享摘要(隐藏节点)
    printf '<pre id="hqshare" style="display:none">%s</pre>\n' "$(esc "$(share_summary)")" >>"$REPORT_FILE"

    # HQMETA 索引元数据(单行注释;禁止 --)
    local meta
    meta=$(printf '{"t":%s,"time":"%s","mode":"%s","tag":"%s","host":"%s","prov":"%s","loc":"%s","ip4":"%s","cpu1":"%s","cpuN":"%s","d4k":"%s","d1m":"%s","down":"%s","up":"%s","fraud":"%s","media":"%s","route":"%s","score":"%s","grade":"%s","jit":"%s","tcp":"%s","file":"%s"}' \
        "$HQ_START_TS" "$(jesc "${HQ_START_TIME}")" "$HQ_MODE" "$(jesc "$OPT_TAG")" "$(jesc "$host")" \
        "$(jesc "${G[prov_name]:-}")" "$(jesc "${G[loc_country]:-} ${G[loc_city]:-}")" "$(jesc "${G[ip4]:-}")" \
        "${G[cpu_score_single]:-}" "${G[cpu_score_multi]:-}" "${G[disk_4k_w]:-}" "${G[disk_1m_w]:-}" \
        "${G[best_down]:-}" "${G[best_up]:-}" "${G[fraud_score]:-}" "${G[media_yes_n]:-0}/${G[media_total_n]:-0}" \
        "$(jesc "${G[route_summary]:-}")" \
        "${G[grade_total]:-}" "${G[grade_label]:-}" "${G[ping_cn_jitter]:-}" "${G[tcp_cn_avg]:-}" \
        "$(printf '%s' "${REPORT_FILE##*/}" | sed 's/--/-/g')")
    meta=$(printf '%s' "$meta" | sed 's/--/-/g')
    printf '<!--HQMETA %s-->\n' "$meta" >>"$REPORT_FILE"
    if [ "$OPT_REPORT" = 1 ]; then
        printf '%s\n' "${C_GREEN}✔${C_OFF} HTML 报告已生成: $REPORT_FILE"
    else
        note "未启用 --report:本地不保留 HTML 报告(需要留档时加 --report)"
    fi
}

# 带宽百分比(相对 1000Mbps 满格)
speed_pct() {
    local v=$1
    is_num "$v" || { printf '0'; return; }
    awk -v v="$v" 'BEGIN{p=v/10; if(p>100)p=100; printf "%d", p}'
}

# ---------------- 历史索引 ----------------
gen_index_html() {
    [ "$OPT_REPORT" = 1 ] || return 0   # 默认不落盘,无历史索引
    local idx="$OPT_OUTDIR/index.html"
    local -a metas=()
    local f meta
    for f in "$OPT_OUTDIR"/report_*.html; do
        [ -e "$f" ] || continue
        meta=$(grep -m1 -o '<!--HQMETA {.*}-->' "$f" 2>/dev/null | sed 's/<!--HQMETA //; s/-->//')
        [ -n "$meta" ] && metas+=("$meta")
    done
    local sorted
    sorted=$(printf '%s\n' "${metas[@]:-}" | grep .)
    sorted=$(printf '%s\n' "$sorted" | while IFS= read -r meta; do
        printf '%s %s\n' "$(jfield "$meta" t)" "$meta"
    done | sort -rn | sed 's/^[0-9]* //')

    local nruns=0
    [ -n "$sorted" ] && nruns=$(grep -c . <<< "$sorted")

    local rows="" ts mode tag host prov loc cpu1 down up fraud media file route score grade
    while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        ts=$(jfield "$meta" time); mode=$(jfield "$meta" mode); tag=$(jfield "$meta" tag)
        host=$(jfield "$meta" host); prov=$(jfield "$meta" prov); loc=$(jfield "$meta" loc)
        cpu1=$(jfield "$meta" cpu1); down=$(jfield "$meta" down); up=$(jfield "$meta" up)
        fraud=$(jfield "$meta" fraud); media=$(jfield "$meta" media); file=$(jfield "$meta" file)
        route=$(jfield "$meta" route); score=$(jfield "$meta" score); grade=$(jfield "$meta" grade)
        local mode_txt="精简"; [ "$mode" = full ] && mode_txt="完整"; [ "$mode" = tiny ] && mode_txt="极小"
        local gcls="dim"
        case "$grade" in A+|A) gcls="rt" ;; B+|B) gcls="cc" ;; C|D) gcls="ww" ;; esac
        rows="${rows}<tr data-k=\"$(esc "$(printf '%s %s %s %s %s' "$host" "$tag" "$prov" "$loc" "$route")")\" onclick=\"location.href='$(printf '%s' "$file" | sed "s/'/%27/g")'\">"
        rows="${rows}<td>$(esc "$ts")</td><td>$(esc "$host") ${tag:+<span class=\"dim\">$(esc "$tag")</span>}</td>"
        rows="${rows}<td>$(esc "$prov")</td><td>$(esc "$loc")</td>"
        rows="${rows}<td class=\"rt\">$(esc "$(printf '%s' "$route" | tr '/' ' ')")</td>"
        rows="${rows}<td>$(esc "$cpu1")</td><td>$(esc "$(fmt_mbps "$down")")</td><td>$(esc "$(fmt_mbps "$up")")</td>"
        rows="${rows}<td>$(esc "$fraud")</td><td>$(esc "$media")</td><td class=\"$gcls\">${score:+$score <span class=\"dim\">$grade</span>}</td><td>$(esc "$mode_txt")</td></tr>"
    done <<< "$sorted"

    cat >"$idx" <<HTMLIDX
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>HostQoS · 历史报告</title>
<style>
:root{--bg:#eef2f8;--card:#fff;--line:#e4eaf3;--ink:#1f2937;--sub:#4b5563;--mut:#9ca3af;
--blue:#2f6fd6;--purple:#8b5cf6;--teal:#14b8a6;--orange:#f59e0b;--green:#22a45d;--yellow:#d19a00;--red:#dc2626;--g1:#0f3f96;--g2:#2f7de1}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei","Noto Sans SC",Inter,Arial,sans-serif;
font-size:13px;line-height:1.6;background-image:radial-gradient(rgba(47,111,214,.05) 1px,transparent 1px);background-size:22px 22px}
.wrap{max-width:1240px;margin:0 auto;padding:14px 16px 40px}
.banner{position:relative;display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:16px 20px;border-radius:14px;color:#fff;
background:linear-gradient(100deg,var(--g1),var(--g2) 78%,#5db3f5);box-shadow:0 6px 18px rgba(21,101,192,.22)}
.banner::after{content:"";position:absolute;right:14px;top:12px;bottom:12px;width:130px;border-radius:10px;
background-image:radial-gradient(rgba(255,255,255,.28) 1.3px,transparent 1.3px);background-size:12px 12px;pointer-events:none}
.blogo{width:46px;height:46px;border-radius:12px;background:#fff;color:var(--g1);display:flex;align-items:center;justify-content:center;flex:none}
.bt1{font-size:17px;font-weight:700}.bt2{font-size:11.5px;opacity:.88;margin-top:1px}
.bhost{flex:1;min-width:220px}
.bh2{font-size:11.5px;opacity:.85;margin-top:2px}
.bh2 b{font-weight:600}
.search{flex:none;position:relative;z-index:1}
.search input{font:inherit;font-size:12.5px;border:none;border-radius:9px;padding:8px 14px;width:250px;max-width:40vw;outline:none;color:var(--ink);background:rgba(255,255,255,.94)}
.search input:focus{box-shadow:0 0 0 3px rgba(255,255,255,.4)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:0 1px 3px rgba(16,24,40,.05);margin-top:14px;overflow:hidden}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:11px;font-weight:600;color:#8a94a6;padding:7px 10px;border-bottom:1px solid #f0f4f9;white-space:nowrap}
td{padding:6px 10px;border-bottom:1px solid #f0f4f9;max-width:230px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}
tr:hover td{background:#f2f7ff;cursor:pointer}
tr:last-child td{border-bottom:none}
.rt{color:var(--green);font-size:11.5px;font-weight:600}
.cc{color:var(--blue);font-size:11.5px;font-weight:600}
.ww{color:var(--yellow);font-size:11.5px;font-weight:600}
.dim{color:var(--mut);font-size:11px}
td.b{font-weight:700}
</style></head>
<body><div class="wrap">
<div class="banner">
  <div class="blogo"><svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M12 2.5 21 7v10l-9 4.5L3 17V7z"/><path d="M3 7l9 4.5L21 7M12 11.5V21.5" opacity=".75"/></svg></div>
  <div><div class="bt1">Host QoS</div><div class="bt2">VPS 主机质量评测报告 · 历史记录</div></div>
  <div class="bhost"><div class="bh2">共 <b>${nruns}</b> 次测试 · 点击行打开报告 · 重新运行脚本会自动更新本页</div></div>
  <div class="search"><input id="q" placeholder="检索: 商家 / 主机 / 线路 / 标签 …" oninput="filt()"></div>
</div>
<div class="card" style="overflow-x:auto">
<table id="tbl"><tr><th>时间</th><th>主机</th><th>商家</th><th>位置</th><th>线路</th><th>CPU单核</th><th>下行</th><th>上行</th><th>欺诈分</th><th>解锁</th><th>评分</th><th>模式</th></tr>
${rows}
</table></div>
<script>
function filt(){var q=document.getElementById('q').value.toLowerCase();
document.querySelectorAll('#tbl tr').forEach(function(r){if(r.querySelector('th'))return;
var k=(r.dataset.k||'').toLowerCase();r.style.display=(!q||k.indexOf(q)>=0)?'':'none'})}
</script>
</div></body></html>
HTMLIDX
}

# ---------------- JSON 全量输出(始终生成,供 --json 与上传共用) ----------------
gen_json() {
    local jf="$HQ_TMP/result.json"
    {
        printf '{"version":"%s","time":"%s","mode":"%s","duration_sec":%s,\n' \
            "$HQ_VERSION" "$(jesc "$HQ_START_TIME")" "$HQ_MODE" "$(( $(date +%s) - HQ_START_TS ))"
        local k first=1
        printf '"system":{'
        first=1
        for k in os os_short arch kernel hostname uptime load cpu_model cpu_cores cpu_threads cpu_mhz aes avx2 l3_cache cpu_virt mem_total_mb mem_avail_mb swap_total_mb mem_w_mb mem_r_mb oversell oversell_balloon oversell_ksm disk_total_mb disk_avail_mb disk_type virt tcp_cc qdisc bbr rmem_max wmem_max dmi_vendor dmi_product plan_bw plan_traffic; do
            [ -n "${G[$k]:-}" ] || continue
            [ $first = 1 ] || printf ', '
            printf '"%s":"%s"' "$k" "$(jesc "${G[$k]}")"; first=0
        done
        printf '},\n"provider":{'
        first=1
        for k in prov_name prov_source prov_conf prov_dmi prov_meta prov_upstream as_full asn_num asn_neighbours asn_prefixes isp org ptr loc_country loc_region loc_city loc_cc lat lon ip4 ip6 cymru_cc ip_reg_rir ip_reg_date ip_range_start proxy_flag hosting_flag mobile_flag; do
            [ -n "${G[$k]:-}" ] || continue
            [ $first = 1 ] || printf ', '
            printf '"%s":"%s"' "$k" "$(jesc "${G[$k]}")"; first=0
        done
        printf '},\n"bench":{'
        first=1
        for k in cpu_score_single cpu_score_multi cpu_ratio mem_w_mb mem_r_mb disk_4k_w disk_1m_w disk_1m_r best_down best_up best_src ping_cn_avg ping_cn_jitter tcp_cn_avg nat_type nat_mapped; do
            [ -n "${G[$k]:-}" ] || continue
            [ $first = 1 ] || printf ', '
            is_num "${G[$k]}" && printf '"%s":%s' "$k" "${G[$k]}" || printf '"%s":"%s"' "$k" "$(jesc "${G[$k]}")"
            first=0
        done
        printf '},\n'
        # 综合参考评分(原型四分项 + IP)
        printf '"grade":{'
        first=1
        for k in grade_total grade_cpu grade_mem grade_disk grade_net grade_ip; do
            [ -n "${G[$k]:-}" ] || continue
            [ $first = 1 ] || printf ', '
            printf '"%s":%s' "${k#grade_}" "${G[$k]}"; first=0
        done
        [ $first = 1 ] || printf ', '
        printf '"label":"%s"},\n' "$(jesc "${G[grade_label]:-}")"
        printf '"ip_quality":{"fraud_score":"%s","fraud_risk":"%s","fraud2_score":"%s","ip_usage":"%s","ip_usage_cat":"%s","native":"%s","native_reg":"%s","native_geo":"%s","dnsbl_hits":"%s","dnsbl_total":"%s","dnsbl_clean":"%s","dnsbl_marked":"%s","port25":"%s","dns_hijack":"%s","dns_note":"%s","as_org":"%s","company_type":"%s"},\n' \
            "${G[fraud_score]:-}" "${G[fraud_risk]:-}" "${G[fraud2_score]:-}" "$(jesc "${G[ip_usage]:-}")" \
            "$(jesc "${G[ip_usage_cat]:-}")" "${G[ip_native]:-}" "${G[native_reg]:-}" "${G[native_geo]:-}" \
            "${G[dnsbl_hits]:-}" "${G[dnsbl_total]:-}" "${G[dnsbl_clean]:-}" "${G[dnsbl_marked]:-}" \
            "${G[port25]:-}" "${G[dns_hijack]:-}" "$(jesc "${G[dns_note]:-}")" \
            "$(jesc "${G[as_org]:-}")" "$(jesc "${G[company_type]:-}")"
        printf '"ip_quality_v6":{"score":"%s","score2":"%s","usage":"%s","usage_cat":"%s","native":"%s","native_reg":"%s","native_geo":"%s","asn":"%s","as_org":"%s","company":"%s","geo":"%s","dnsbl_hits":"%s","dnsbl_total":"%s","dnsbl_clean":"%s","dnsbl_marked":"%s"},\n' \
            "${G[ipq6_score]:-}" "${G[ipq6_score2]:-}" "$(jesc "${G[ipq6_usage]:-}")" "$(jesc "${G[ipq6_usage_cat]:-}")" \
            "${G[ip_native6]:-}" "${G[native6_reg]:-}" "${G[native6_geo]:-}" "$(jesc "${G[asn6]:-}")" \
            "$(jesc "${G[as6_org]:-}")" "$(jesc "${G[company6]:-}")" "$(jesc "${G[geo6]:-}")" \
            "${G[dnsbl6_hits]:-}" "${G[dnsbl6_total]:-}" "${G[dnsbl6_clean]:-}" "${G[dnsbl6_marked]:-}"
        printf '"ipq_company":"%s",\n' "$(jesc "${G[company_name]:-}")"
        printf '"mtu_summary":"%s",\n' "$(jesc "${G[mtu_summary]:-}")"
        printf '"mtu_proto":"%s",\n' "${G[mtu_proto]:-}"
        printf '"intl_summary":{"ok":"%s","total":"%s","cdn_mbps":"%s"},\n' \
            "${G[intl_ok_n]:-}" "${G[intl_total]:-}" "${G[intl_cdn]:-}"
        printf '"tos_retrans":{"电信":"%s","联通":"%s","移动":"%s"},\n' \
            "${G[tos_retrans_电信]:-}" "${G[tos_retrans_联通]:-}" "${G[tos_retrans_移动]:-}"
        printf '"prov_summary":{"v4_ok":"%s","v4_total":"%s","v6_ok":"%s","v6_total":"%s"},\n' \
            "${G[prov4_ok]:-}" "${G[prov4_total]:-}" "${G[prov6_ok]:-}" "${G[prov6_total]:-}"
        printf '"china_v6":['
        local -a _c6r=()
        local -A _V6LJ=()
        local _r6 _i6 _a6 _l6 _d6 _u6 _s6 _l6j
        for _r6 in ${V6LINE_ROWS[@]+"${V6LINE_ROWS[@]}"}; do
            IFS='|' read -r _i6 _l6j <<< "$_r6"
            _V6LJ[$_i6]=${_l6j:-}
        done
        for _r6 in ${CHINA6_ROWS[@]+"${CHINA6_ROWS[@]}"}; do
            IFS='|' read -r _i6 _a6 _l6 <<< "$_r6"
            _d6=""; _u6=""
            for _s6 in ${V6TOS_ROWS[@]+"${V6TOS_ROWS[@]}"}; do
                case "$_s6" in "$_i6|"*) IFS='|' read -r _ _d6 _u6 <<< "$_s6" ;; esac
            done
            _c6r+=("$_i6|${_a6:-}|${_l6:-}|${_d6:-}|${_u6:-}|${_V6LJ[$_i6]:-}")
        done
        join_rows 6 ${_c6r[@]+"${_c6r[@]}"}
        printf '],\n'
        _mp=''
        if [ -n "${MAILPROV_ROWS+x}" ]; then
            for _r in ${MAILPROV_ROWS[@]+"${MAILPROV_ROWS[@]}"}; do _mp="${_mp:+$_mp,}$_r"; done
        fi
        printf '"mail_providers":"%s",\n' "$(jesc "$_mp")"
        printf '"mail_summary":"%s",\n' "$(jesc "${G[mail_summary]:-}")"
        printf '"route_summary":"%s",\n"tier1":"%s",\n' "$(jesc "${G[route_summary]:-}")" "$(jesc "${G[tier1]:-}")"
        local _rf=""
        [ "$OPT_REPORT" = 1 ] && _rf="${REPORT_FILE##*/}"
        printf '"tag":"%s",\n"report_file":"%s",\n' "$(jesc "$OPT_TAG")" "$(jesc "$_rf")"
        printf '"speed":['; join_rows 4 ${SPEED_ROWS[@]+"${SPEED_ROWS[@]}"}
        printf '],\n"ping":['; join_rows 6 ${PING_ROWS[@]+"${PING_ROWS[@]}"}
        printf '],\n"ping_tcp":['; join_rows 5 ${TCP_ROWS[@]+"${TCP_ROWS[@]}"}
        printf '],\n"ping_tcp6":['; join_rows 5 ${TCP6_ROWS[@]+"${TCP6_ROWS[@]}"}
        printf '],\n"media":['; join_rows 5 ${MEDIA_ROWS[@]+"${MEDIA_ROWS[@]}"}
        printf '],\n"fio":['; join_rows 5 ${FIO_ROWS[@]+"${FIO_ROWS[@]}"}
        printf '],\n"route":['; join_rows 4 ${ROUTE_TARGETS[@]+"${ROUTE_TARGETS[@]}"}
        printf '],\n"tcpmtu":['; join_rows 4 ${MTU_ROWS[@]+"${MTU_ROWS[@]}"}
        printf '],\n"intl":['; join_rows 4 ${INTL_ROWS[@]+"${INTL_ROWS[@]}"}
        printf '],\n"cdn":['; join_rows 4 ${CDN_ROWS[@]+"${CDN_ROWS[@]}"}
        printf '],\n"provinces":['; join_rows 4 ${PROV_ROWS[@]+"${PROV_ROWS[@]}"}
        printf '],\n"cn_matrix":['; join_rows 8 ${CNMTX_ROWS[@]+"${CNMTX_ROWS[@]}"}
        local -a _is7=() _a1 _a2 _a3 _a4 _a5 _a6 _a7
        for _r in ${INTLSPD_ROWS[@]+"${INTLSPD_ROWS[@]}"}; do
            IFS='|' read -r _a1 _a2 _a3 _a4 _a5 _a6 _a7 <<< "$_r"
            _is7+=("$_a1|$_a2|$_a3|${_a4:-}|${_a5:-}|${_a6:-}|${_a7:-}")
        done
        printf '],\n"intl_speed":['; join_rows 7 ${_is7[@]+"${_is7[@]}"}
        printf '],\n"pktsize":['
        local -a _pk6=() _c1 _c2 _c3 _c4 _c5 _fam _car
        for _r in ${MTU_ROWS[@]+"${MTU_ROWS[@]}"}; do
            IFS='|' read -r _c1 _c2 _c3 _c4 _c5 <<< "$_r"
            case "$_c1" in
                电信|联通|移动) _fam=v4; _car=$_c1 ;;
                v6电信|v6联通|v6移动) _fam=v6; _car=${_c1#v6} ;;
                *) continue ;;
            esac
            local _vd
            if [ "${_c5:-}" = "1" ] || [ "${_c5:-}" = "over" ]; then _vd="超链路MTU"
            elif is_num "$_c3"; then _vd=$(awk -v l="$_c3" 'BEGIN{if(l>=99.5)print"异常";else if(l>=30)print"受限";else if(l>=5)print"轻微丢包";else print"正常"}')
            else _vd="待检测"; fi
            _pk6+=("$_fam|$_car|${_c2%B}|${_c4:-}|${_c3:-}|$_vd")
        done
        join_rows 6 ${_pk6[@]+"${_pk6[@]}"}
        printf '],\n"mail":['; join_rows 5 ${MAIL_ROWS[@]+"${MAIL_ROWS[@]}"}
        printf ']}\n'
    } >"$jf"
    if [ "$OPT_JSON" = 1 ]; then
        if [ "$OPT_REPORT" = 1 ]; then
            cp "$jf" "${REPORT_FILE%.html}.json"
            printf '%s\n' "${C_GREEN}✔${C_OFF} JSON 报告已生成: ${REPORT_FILE%.html}.json"
        else
            cat "$jf"   # 未启用 --report:JSON 打印到 stdout,不落盘
        fi
    fi
}

# ---------------- 上传结果到服务端 ----------------
upload_result() {
    if [ "$OPT_UPLOAD" != 1 ]; then
        if [ "$OPT_REPORT" = 1 ]; then
            note "已按 --no-upload 完全离线,仅本地保存报告"
        else
            note "已按 --no-upload 完全离线:未上传也未落盘,结果仅显示在上方终端摘要"
        fi
        return 0
    fi
    local jf="$HQ_TMP/result.json"
    [ -s "$jf" ] || { warn "缺少 JSON 结果,跳过在线报告"; return 1; }
    local url="${OPT_SERVER%/}/api/v1/runs"
    # 内网/本机地址绕过代理
    local host_part=${OPT_SERVER#http://}; host_part=${host_part#https://}
    host_part=${host_part%%/*}; host_part=${host_part%%:*}
    local -a np=()
    case "$host_part" in
        localhost|127.*|::1|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) np=(--noproxy '*') ;;
    esac
    local -a hdr=(-H "Content-Type: application/json" -A "$HQ_UA")
    [ -n "$OPT_TOKEN" ] && hdr+=(-H "Authorization: Bearer $OPT_TOKEN")
    local resp rc
    resp=$(curl -fsS --connect-timeout 6 --max-time 30 "${np[@]}" "${hdr[@]}" -X POST --data-binary @"$jf" "$url" 2>&1) && rc=0 || rc=$?
    if [ "$rc" != 0 ]; then
        warn "在线报告生成失败($OPT_SERVER 不可达或站点未部署,rc=$rc)"
        [ "$rc" = 22 ] && note "若站点要求令牌:用 curl -sL https://hostqos.com/hq.sh | bash 运行可自动携带,或手动 --token"
        return 1
    fi
    local id rid pct
    id=$(jfield "$resp" id)
    if [ -n "$id" ]; then
        printf '  %s✔%s 报告链接: %s%s/run/%s\n' "$C_GREEN" "$C_OFF" "$OPT_SERVER" "${C_DIM}" "$id"
        pct=$(jfield "$resp" pct)
        [ -n "$pct" ] && note "$(L pct_note '历史对比:本次总分超过') ${pct}%"
        # 报告页"查看完整报告"按钮指向在线报告
        if [ -n "${REPORT_FILE:-}" ] && [ -f "$REPORT_FILE" ]; then
            sed -i "s|__ONLINE_URL__|${OPT_SERVER%/}/run/$id|g" "$REPORT_FILE"
        fi
    else
        warn "在线报告响应异常: $(printf '%s' "$resp" | head -c 120)"
        return 1
    fi
}

join_rows() { # <列数> [值...] -> JSON 数组
    local ncols=$1; shift
    local row i val out="" first=1
    local -a cols
    [ $# -gt 0 ] || return 0
    for row in "$@"; do
        IFS='|' read -ra cols <<< "$row"
        out=''
        for ((i=0; i<ncols; i++)); do
            val=${cols[$i]:-}
            [ $i -gt 0 ] && out="$out, "
            is_num "$val" && out="$out$val" || out="$out\"$(jesc "$val")\""
        done
        [ $first = 1 ] || printf ', '
        printf '[%s]' "$out"; first=0
    done
}
# ============================================================
# 主流程
# ============================================================
run_module() { # <序号i> <总数n> <模块名> <函数>
    local i=$1 n=$2 mname=$3 fn=$4
    printf '\n%s[%d/%d] %s%s\n' "$C_BOLD" "$i" "$n" "$mname" "$C_OFF"
    hq_pids_adjust   # 模块边界:PID 余量不足时提前收缩并发,防 fork: retry 退避拖死
    local t0; t0=$(date +%s)
    if "$fn"; then
        local t1=$(( $(date +%s) - t0 ))
        [ $t1 -gt 0 ] && note "($((t1/60))m$((t1%60))s)"
    else
        warn "该模块部分检测项未成功,已跳过并继续后续检测(对应项在报告中如实标待测试)"
    fi
}

main() {
    if [ "${_HQ_ALLEXPORT:-0}" = 1 ]; then
        warn "\`bash -a\` 的 -a 被 bash 解释为 allexport 而非脚本参数(已自动关闭)"
        if [ "${_HQ_ARGS_N:-0}" = 0 ]; then
            HQ_MODE="full"; MOD_ON[route]=1
            note "完整模式已是默认,推荐命令: curl -sL https://hostqos.com/hq.sh | bash"
        fi
    fi
    parse_cli "$@"
    [ -n "$OPT_PLAN_BW" ]  && G[plan_bw]=$OPT_PLAN_BW
    [ -n "$OPT_PLAN_TRF" ] && G[plan_traffic]=$OPT_PLAN_TRF
    init_lang
    preflight
    print_banner
    hq_par_init

    mod_sysinfo
    mod_provider

    local -a queue=()
    local -a labels=()
    local m
    for m in cpu disk ping tcpmtu speed intl ipq media mail route; do
        [ "${MOD_ON[$m]:-0}" = 1 ] || continue
        queue+=("mod_$m")
        labels+=("$(L $m "$m")")
    done

    local i=0 n=${#queue[@]}
    while [ $i -lt $n ]; do
        run_module $((i+1)) "$n" "${labels[$i]}" "${queue[$i]}"
        i=$((i+1))
    done

    # provider flags(布尔→字符串供 JSON/DB)
    [ -n "${G[proxy]:-}" ] && G[proxy_flag]=$([ "${G[proxy]}" = true ] && echo yes || echo no)
    [ -n "${G[hosting_flag]:-}" ] && G[hosting_flag]=$([ "${G[hosting_flag]}" = true ] && echo yes || echo no)
    [ -n "${G[mobile_flag]:-}" ] && G[mobile_flag]=$([ "${G[mobile_flag]}" = true ] && echo yes || echo no)
    build_cn_matrix
    calc_grade
    term_summary
    gen_report_html
    gen_json
    upload_result
    # 未上传时,报告按钮回退到本地历史索引
    if [ -n "${REPORT_FILE:-}" ] && [ -f "$REPORT_FILE" ] && grep -q '__ONLINE_URL__' "$REPORT_FILE"; then
        sed -i 's|__ONLINE_URL__|./index.html|g' "$REPORT_FILE"
    fi
    gen_index_html
}

main "$@"
