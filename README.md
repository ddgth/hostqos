<div align="center">

# Host QoS

**一行命令,给你的 VPS 做全面体检**

VPS / 独服主机质量评测脚本:Bash 单文件、零依赖、只读检测

[![version](https://img.shields.io/badge/version-2.8.2-blue)]()
[![bash](https://img.shields.io/badge/bash-4%2B%20%7C%20BusyBox%20ash-green)]()
[![license](https://img.shields.io/badge/license-MIT-orange)]()
[![platform](https://img.shields.io/badge/platform-Linux%20x86_64%20%7C%20arm64-lightgrey)]()

**[English](README_EN.md)** · 中文

</div>

---

## 简介

`hostqos.sh` 是一个 **Bash 单文件** VPS 评测脚本:在待测服务器上一条命令跑完
系统信息 / 商家识别 / 性能跑分 / 磁盘 I/O / 三网回程线路与测速 / IP 质量与风险 /
流媒体与 AI 解锁 / 邮件端口连通等检测,生成终端摘要,并自动汇总到在线站点
([hostqos.com](https://hostqos.com))生成可分享、可检索的在线报告。

```bash
curl -sL https://hostqos.com/hq.sh | bash
```

### 核心特性

- **零依赖**:只需 `bash` + `curl`;Alpine/BusyBox 可直接 `sh` 运行(自动切换到已有 bash),不调用任何包管理器
- **只读检测**:不改系统配置、不安装软件包、不读敏感文件;默认**不在磁盘留任何文件**,临时文件与运行内缓存退出即清
- **三种模式**:完整(默认)/ 精简 `-s` / 极小 `--tiny`(128MB 内存小机可用),按资源与时间预算自选
- **双栈支持**:IPv4 / IPv6 全套检测,无 v6 环境自动跳过并如实标注
- **移动端友好**:在线报告完整适配手机浏览(375px 级窄屏实测)
- **隐私可控**:不想上传加 `--no-upload` 完全离线;不想落盘默认即不落盘
- **超售检测**:virtio_balloon 气球回收 / KSM 内存页合并特征识别,一眼看出宿主机超开
- **可自建**:服务端(Python + MySQL,同样零第三方依赖)开源于本组织,客户端 `--server` 一指切换

---

## 检测维度

| 模块 | 检测内容 | 输出 |
|---|---|---|
| 硬件与系统 | CPU 型号/核心/频率、内存、磁盘容量与类型、虚拟化平台、KSM/balloon 超售特征、系统与架构 | 基本信息 + 超售警示 |
| 性能跑分 | sha256 单核/多核、内存带宽写、FIO 顺序与 4K 随机读写 | CPU 分级评级(sha256 单核/多核/内存/磁盘五项) |
| 三网线路 | 电信/联通/移动回程线路识别(163/9929/CMIN2/CN2 GIA/CTGNet/CUII)、逐跳路由 | 每运营商线路标签 |
| 三网测速 | 运营商定向单线程上下行实测、延迟、重传/丢包 | 单线程实测表(非多线程峰值) |
| 省份网格 | 31 省 × 三网 93 测点零丢包率(每测点 4×ICMP) | 零丢包占比环形图 |
| 大小包 | 64/512/1200/1400B 载荷探测(默认 TCP 80,回退 ICMP DF)+ TCP·443 握手失败率 | 三网 × 档位延迟/丢包矩阵 |
| 国际测速 | 就近节点多线程 + 日本/新加坡/香港/美西/美东/法兰克福等区域单线程 | 下载/上传/延迟对/重传 |
| IP 质量 | Scamalytics 欺诈分、原生/广播、使用类型(机房/商宽/家宽)、ASN 与公司归属、注册地/使用地 | IPv4 + IPv6 双列风险面板 |
| 黑名单 | 96 个 DNSBL 数据库抽查 | 有效数/清洁/已标记/黑名单 |
| 流媒体解锁 | Netflix(含自制/全解)、Disney+、YouTube、TikTok 等 | 解锁状态 + 区域 |
| AI 服务解锁 | ChatGPT、Claude、Gemini 等 | 双栈解锁状态 + 区域 |
| 邮件端口 | SMTP 25/465/587、IMAP、POP3 出站连通,主流邮局 MX 探测、PTR、DNSBL | 端口矩阵 + 邮局面板 |

## 快速开始

### 方式一:远程一键跑分(推荐,报告自动汇总到在线站点)

```bash
curl -sL https://hostqos.com/hq.sh | bash                      # 完整模式
curl -sL https://hostqos.com/hq.sh | bash -s -- -t "备注标签"   # 带备注标签
```

### 方式二:下载到本机运行

```bash
wget https://hostqos.com/hq.sh -O hostqos.sh    # 或从本仓库 Releases 下载
bash hostqos.sh
```

### 三种运行模式

| 命令 | 模式 | 适用 |
|---|---|---|
| `bash hostqos.sh` | 完整模式(默认) | 全量检测:系统+商家+性能+磁盘 fio+逐跳路由+DNSBL+25 端口+更多测速节点 |
| `bash hostqos.sh -s` | 精简模式 | 跳过磁盘 fio、逐跳路由、DNSBL、25 端口等重模块,更快出报告(约 3-6 分钟) |
| `bash hostqos.sh --tiny` | 极小模式 | 128MB 内存 / 1GB 磁盘小机:纯 curl 测速、零二进制下载(约 1-3 分钟) |

## 常用参数

| 参数 | 说明 |
|---|---|
| `-p, --provider <s>` | 手动指定商家/产品(如 `"搬瓦工\|CN2 GIA"`),覆盖自动识别 |
| `-t, --tag <s>` | 主机备注标签,显示在报告头部与列表 |
| `--plan-bandwidth <s>` | 标称带宽(如 `2Gbps`),报告附实测对照 |
| `--plan-traffic <s>` | 月流量额度(如 `2000GB/月`) |
| `--report` | 本地保存 HTML 报告(默认 `./hostqos/`);默认不落盘 |
| `-o, --html <dir>` | 报告输出目录(隐含 `--report`) |
| `-4` / `-6` | 仅测 IPv4 / IPv6(默认双栈) |
| `-E, --lang en` | 英文输出 |
| `--route` | 强制启用回程线路检测(任意模式,含 `--tiny`) |
| `--skip <模块>` | 跳过模块:`cpu,disk,ping,tcpmtu,speed,intl,ipq,media,mail,route` |
| `--only <模块>` | 仅运行指定模块 |
| `--mirror [url]` | 二进制下载走 GitHub 镜像(默认 ghfast.top,可指定前缀) |
| `--low-traffic` | 测速时长减半,省流量 |
| `--low-mem` | 强制低资源模式(内存 <700MB 自动启用) |
| `--json` | 输出全量 JSON(配合 `--report` 写入报告目录,单独使用打印到 stdout) |
| `--no-upload` | **完全离线**,不上传在线报告 |
| `--server <url>` | 在线报告站点(默认 `https://hostqos.com`;自建站点填自己的地址) |
| `--token <s>` | 站点访问令牌(站点启用鉴权时;远程一键跑分自动携带,无需手填) |
| `--keep` / `--no-color` / `-h` | 保留临时文件 / 关闭彩色输出 / 帮助 |

### 使用示例

```bash
bash hostqos.sh -s -p "RackNerd|2C2G 年付" --skip media      # 精简 + 手动商家 + 跳过解锁
bash hostqos.sh --only speed,ipq -4 --no-upload              # 只测速+IP质量,仅 IPv4,离线
bash hostqos.sh --tiny --route                               # 小机也要看回程线路
bash hostqos.sh --low-traffic --json                         # 省流量 + 输出 JSON
bash hostqos.sh --report --json                              # 本地保存报告(含 JSON)
```

## 会得到什么

1. **终端摘要**:跑分结束直接打印评分、CPU/内存/磁盘、三网逐行、大小包、解锁、NAT 等结论,
   末尾附可一键复制的分享摘要(适配 NodeSeek 等论坛排版)。
2. **在线报告**(默认开启):上传后返回 `https://hostqos.com/run/<编号>` 链接——
   深浅色主题、中英双语、手机/平板/桌面全适配,可在站点按商家/主机/线路检索全部历史报告。
3. **本地报告**(仅 `--report` / `-o` 时):`hostqos/report_<主机名>_<时间>.html`
   (单文件,浏览器直接打开,顶栏有"打印"和"下载图片"按钮)+ `index.html` 本地索引;
   加 `--json` 同时落一份全量 JSON。

不想在磁盘留任何文件?默认即是。不想上传任何数据?加 `--no-upload`。

## 隐私与安全

**上传内容**(报告 JSON 本身):系统信息(主机名/CPU/内存/磁盘/系统)、公网 IP 与归属、
虚拟化/商家识别结果、性能与网络实测数据。**不包含**任何密码、密钥、`/etc` 配置或进程列表。
报告中的主机名在列表页默认打码展示。

**安全承诺**:

- 脚本**不会**执行任何从网络拉取的 shell 代码——下载仅限 GitHub Releases 中的
  测试二进制(nexttrace / speedtest-go / fio 等),且校验后使用;
- 不调用包管理器安装软件、不读取敏感文件、不写 crontab、不留后门;
- 测速二进制与中间文件全部放在临时目录(`$HQ_TMP`),退出即删;历次异常退出的
  残留临时目录会在下次运行时按 24h 门槛自动清扫;`--keep` 可保留供自行审查;
- 探测目标仅为:三网运营商节点、公共测速节点、IP 信誉/DNSBL 公共接口、
  流媒体官方接口、GitHub Releases。

## 常见问题

- **Alpine / 无 bash?** 直接 `sh hostqos.sh`,脚本自动查找并切换到已有 bash;
  系统没有 bash 时提示先手动安装(脚本自身不安装任何软件包)。
- **GitHub 下载慢/失败?** `--mirror` 走镜像前缀;或 `--tiny`(纯 curl 测速,不下载二进制)。
- **内存/磁盘很小的机器?** `--tiny`;1GB 磁盘请保证 ≥80MB 可用空间。
- **跑分影响生产服务?** 内存 <700MB 自动进入低资源模式;也可手动 `--low-mem --low-traffic`。
- **想自建收集站点?** 服务端(Python3 + MySQL,零第三方依赖)随本组织发布,
  部署后客户端加 `--server https://你的域名` 即可;见 [hostqos.com](https://hostqos.com)。

## 兼容性

- **系统**:Debian/Ubuntu/CentOS/Alma/Rocky/Fedora/Alpine/Arch 等主流发行版
- **架构**:x86_64 / arm64
- **要求**:`bash 4+`(或 BusyBox ash)+ `curl`;`dd`/`ping`/`dig` 等缺失时自动降级并提示

## 致谢

测速、路由与解锁检测思路参考社区优秀脚本与公开实践(NodeQuality / TcpQuality /
RegionRestrictionCheck 等),测速与路由核心使用 speedtest-go、nexttrace、fio 等
开源工具的官方预编译二进制。感谢开源社区。

---

## License

[MIT](LICENSE)

<div align="center">
<sub>Host QoS · VPS 主机质量评测 · <a href="https://hostqos.com">hostqos.com</a></sub>
</div>
