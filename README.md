# Bluetooth Auto Connect

> 一个跑在 ARM 开发板上的蓝牙键鼠自动连接守护脚本。
> 本仓库不只是脚本，更是一份「**AI 辅助下从零排查硬件问题 → 收敛方案 → 落地成可安装工具**」的完整实战案例。
> 面向「刚学会用 AI 写代码、但没怎么碰过 Linux / 蓝牙 / systemd」的初学者。

---

## 目录

- [一、项目背景：我们到底在解决什么问题](#一项目背景我们到底在解决什么问题)
- [二、需求分析：把模糊痛点拆成可执行清单](#二需求分析把模糊痛点拆成可执行清单)
- [三、方案探索：那些失败的尝试同样重要](#三方案探索那些失败的尝试同样重要)
- [四、技术原理：你必须先懂的几个概念](#四技术原理你必须先懂的几个概念)
- [五、架构设计](#五架构设计)
- [六、代码逐段讲解](#六代码逐段讲解)
- [七、安装与使用](#七安装与使用)
- [八、常见问题 FAQ](#八常见问题-faq)
- [九、这个项目想教会 AI 初学者什么](#九这个项目想教会-ai-初学者什么)

---

## 一、项目背景：我们到底在解决什么问题

### 1.1 硬件环境

| 项目 | 型号 |
| --- | --- |
| 开发板 | Orange Pi 3B（瑞芯微 RK3566） |
| 蓝牙模组 | RTL8761B（USB 接口，USB ID 通常为 `0bda:8761`） |
| 系统镜像 | Ubuntu Jammy 桌面版（预装 Blueman 托盘） |
| 外设 | 蓝牙键盘、蓝牙鼠标 |

### 1.2 现象

板子每次开机，在图形界面的蓝牙托盘里都能看到「最近连接」里有键盘和鼠标的名字，但是：

1. 键鼠**不会自动连上**；
2. 命令行跑 `bluetoothctl devices` **什么都不输出**；
3. 每次都要在图形界面里手动点一下「连接」，偶尔还要重新配对；
4. 重启之后问题复现。

### 1.3 根因（一句话版）

> 这块板子的蓝牙固件在每次加载时会**随机生成蓝牙适配器自己的 MAC 地址**，而 BlueZ（Linux 蓝牙栈）是把配对密钥绑定在「本机适配器 MAC」这个目录名下存储的。MAC 一变，BlueZ 就认为自己换了一块新蓝牙，原来的配对数据库直接被「隔离」了，所以 `bluetoothctl devices` 是空的。

而图形界面托盘里那个「最近连接」，是 **Blueman 这个第三方小程序自己维护的一份 UI 书签**，它只存了外设的 MAC + 名字，**不存配对密钥**，所以重启之后你还能看到名字，但点了也连不上。

---

## 二、需求分析：把模糊痛点拆成可执行清单

用户最初的描述是：

> "我希望开机之后蓝牙键鼠能自动连上，不用每次手动点。"

这种描述对 AI 来说是没法直接编码的，必须先拆。我们最终拆出了这些需求：

### 2.1 功能需求

| # | 需求 | 验收标准 |
| --- | --- | --- |
| F1 | 开机自动尝试连接键盘和鼠标 | 重启板子后不用手动操作，键鼠在 5 分钟内自动连上 |
| F2 | 不需要每次手动改脚本去维护设备列表 | 提供命令行子命令增删设备 |
| F3 | 设备列表来源有两个：托盘 UI 的「最近连接」 + 手动列表 | 默认优先用托盘缓存，缓存空了用手动列表 |
| F4 | 同名设备（比如两个同名键盘）要连信号最强的那一个 | 扫描时读 RSSI，按数值排序取最大 |
| F5 | 最多扫描 5 分钟，全部连上就提前退出 | 不能无限循环占用 CPU |
| F6 | 第一次运行要能自动完成安装（写 systemd、开机自启） | 无参数跑脚本 = 安装向导 |

### 2.2 非功能需求

- **不依赖网络**：板子经常没网，脚本不能要求联网安装。
- **日志可查**：用 systemd journal，`journalctl -u ...` 就能看。
- **对 AI 友好**：每一步失败都要有明确报错，不能静默失败。

---

## 三、方案探索：那些失败的尝试同样重要

这一节是整个项目最有价值的部分。**AI 初学者最容易踩的坑就是：第一版代码能跑就交差，不愿意回头问"为什么我换了方法"。**

我们先后尝试了四条路：

### 3.1 方案 A：改固件加载脚本，删掉 `--bd_addr_rand`

香橙派镜像里有一个 `/usr/bin/bt_pla_test` 脚本，里面给 Realtek 蓝牙固件传了一个 `--bd_addr_rand`（随机生成 BD 地址）参数。直觉上，把它删掉 MAC 就固定了。

**结果**：改完之后重启，MAC 照样随机变。

**为什么失败**：这个脚本根本不是开机时真正被调用的那一份。镜像里还有别的脚本（systemd 服务、udev 规则）在真正加载固件，我们改错了文件。

**教训**：**不要假设某个文件是"真正生效的那一个"**。要用 `systemctl cat`、`grep -r`、`ls -l /etc/systemd/system/` 找到真正的调用链。

### 3.2 方案 B：用 `btmgmt set-addr` 动态改写 MAC

BlueZ 提供了 `btmgmt` 工具，理论上可以在蓝牙启动后改写控制器地址。

**结果**：板子上这个版本的 `btmgmt` 根本没有 `set-addr` 子命令（`Unknown command`）。

**为什么失败**：不同内核 / 固件版本对 mgmt 接口的支持不一样，而且很多 USB 蓝牙模组的地址是固件烧死的，用户态不允许改。

**教训**：**先 `btmgmt --help` 看支持哪些命令，再写代码**。不要凭文档记忆。

### 3.3 方案 C：换操作系统镜像

香橙派官方的 Debian 12 桌面镜像据说修过这个随机 MAC 的问题。

**结果**：能根治，但用户不想重装系统（里面已经配好了一堆环境）。

**教训**：当软件层已经被证明无解时，**换环境永远是一个选项，但要让用户自己权衡成本**。

### 3.4 方案 D（最终采用）：不固定 MAC，绕过去

既然 MAC 固定不了，配对密钥存不住，那就**每次开机都重新走一遍"扫描 → 配对 → 信任 → 连接"**。

关键是怎么知道要连哪些设备？两个来源：

1. **Blueman 托盘的「最近连接」**：这是 GUI 自己存的，重启不丢，里面有外设 MAC。
2. **手动列表**：兜底，万一托盘缓存被清空了还能用。

这就是本仓库脚本的由来。

> 💡 **给 AI 初学者的提醒**：当你连续失败两三次的时候，不要继续在原方向上硬刚。退一步问自己：**"我真正想要的最终状态是什么？"** 我们想要的是"键鼠能用"，不是"MAC 必须固定"。换条路往往更简单。

---

## 四、技术原理：你必须先懂的几个概念

如果你跳过这一节直接看代码，你会在 `gsettings`、`DBUS_SESSION_BUS_ADDRESS` 这些地方卡住。先花 5 分钟搞懂它们。

### 4.1 BlueZ 是什么

BlueZ 是 Linux 官方的蓝牙协议栈，后台进程叫 `bluetoothd`。你在命令行用的 `bluetoothctl` 就是它的客户端。

它把所有配对信息（密钥、信任标记、设备名字）存在磁盘上：

```
/var/lib/bluetooth/
├── <本机适配器MAC>/           ← 注意这个目录名！
│   ├── <外设1 MAC>/
│   │   └── info              ← 里面有 LinkKey（配对密钥）
│   └── <外设2 MAC>/
│       └── info
```

**关键坑**：`<本机适配器MAC>` 这个目录名是动态的。一旦本机蓝牙 MAC 变了，BlueZ 就去读一个新目录，旧目录里的密钥就再也用不上了。这就是我们这个项目的根因。

### 4.2 Blueman 是什么

Blueman 是一个第三方 GTK 蓝牙管理小程序（`blueman-applet`），香橙派 / Ubuntu 桌面镜像默认装它，就是右上角那个蓝牙图标。

它和 BlueZ 是**两层皮**：

- BlueZ 负责"真正的蓝牙通信和配对"；
- Blueman 负责"好看的 GUI 托盘菜单"。

Blueman 的「最近连接」插件叫 `RecentConns`，它把历史记录存在自己的 gsettings 里：

```bash
gsettings get org.blueman.plugins.recentconns recent-connections
```

输出长这样（已经脱敏）：

```python
[
  {'adapter': 'XX:XX:XX:XX:XX:XX', 'address': 'AA:BB:CC:DD:EE:01',
   'alias': '我的键盘', 'icon': 'input-keyboard', ...},
  {'adapter': 'XX:XX:XX:XX:XX:XX', 'address': 'AA:BB:CC:DD:EE:02',
   'alias': '我的鼠标', 'icon': 'input-mouse', ...}
]
```

**注意**：这里面有 `address`（外设 MAC）和 `alias`（名字），但**没有 LinkKey**。所以它只能告诉你"要连谁"，不能帮你跳过配对。

### 4.3 gsettings 和 D-Bus 是什么

`gsettings` 是 GNOME 系桌面程序存配置的地方（类似 Windows 注册表，但是纯文本）。它通过 **D-Bus** 这个进程间通信总线来读写。

这里有个超级容易踩的坑：

> **systemd 后台服务默认是 root 跑的，它连不上"用户的 D-Bus 会话"，所以读不到 Blueman 的 gsettings。**

解决方法是在 systemd 单元里显式声明：

```ini
User=orangepi
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
```

`/run/user/1000/bus` 就是当前登录用户（uid=1000）的 D-Bus socket。

### 4.4 RSSI 是什么

RSSI（Received Signal Strength Indication）是蓝牙广播包里带的"信号强度"，单位是 dBm，**是个负数**：

- `-40`：贴着脸，信号极强
- `-60`：同一个房间，信号好
- `-80`：隔了一堵墙，信号差
- `-90`：基本连不上

我们要"同名设备里选信号最强的"，就是在扫描日志里抓 `RSSI: -62` 这种行，然后按数值**从大到小**排序。

### 4.5 systemd 的 Type=oneshot 是什么

systemd 服务有几种类型：

- `simple`：进程一直在后台跑；
- `oneshot`：进程跑完就退出，systemd 会等它结束才算"启动成功"。

我们的脚本是"开机扫一遍，连上就退"，所以用 `oneshot` 最合适。

---

## 五、架构设计

### 5.1 整体流程图

```
开机
 │
 ▼
systemd 启动 bt-auto-connect.service
 │
 ▼
读取 Blueman gsettings (recent-connections)
 │
 ├── 有数据 ──► 拿到 [alias, address] 列表 ──┐
 │                                          │
 └── 空 ──► 读 /etc/bt_autoconnect_devices.list
                                            │
                                            ▼
                                  进入轮询循环（最多 300 秒）
                                            │
                                            ▼
                                  bluetoothctl scan on (2 秒)
                                            │
                                            ▼
                                  收集 RSSI + Alias
                                            │
                                            ▼
                                  对每个目标：
                                    - 已连接？跳过
                                    - 纯名称？找同名 RSSI 最强的 MAC
                                    - connect → 失败则 pair+trust+connect
                                            │
                                            ▼
                                  全部连上？退出
                                  否则睡 3 秒再来一轮
```

### 5.2 两种列表模式对比

| 维度 | Blueman 缓存模式 | 手动列表模式 |
| --- | --- | --- |
| 数据来源 | `gsettings org.blueman.plugins.recentconns` | `/etc/bt_autoconnect_devices.list` |
| 可读 | ✅ | ✅ |
| 新增 | ❌（GUI 自己维护） | ✅ `list-add` |
| 删除 | ✅ `cache-del`（托盘菜单同步消失） | ✅ `list-del` |
| 自带 MAC | ✅（dict 里有 address） | 可选（名称 / MAC / 名称+MAC） |
| 触发条件 | 默认优先 | 缓存为空时自动回落 |

### 5.3 手动列表条目格式

一行一个设备，三种写法都合法：

```text
# 纯名称：扫描时按 alias 匹配，同名按 RSSI 择优
我的键盘

# 纯 MAC：直接连这个地址
AA:BB:CC:DD:EE:01

# 名称 + MAC：MAC 用于连接，名称仅用于日志
我的鼠标 AA:BB:CC:DD:EE:02

# 以 # 开头的是注释，会被忽略
```

---

## 六、代码逐段讲解

完整脚本就在仓库根目录 [`bt-auto-connect.sh`](./bt-auto-connect.sh)，这里挑最容易卡住的几段讲。

### 6.1 解析 Blueman 的 gsettings 输出

`gsettings get` 返回的是一个 Python 字面量风格的字符串，不是 JSON。最稳的办法是交给 `python3` 用 `ast.literal_eval` 解析：

```python
import ast, sys
data = ast.literal_eval(sys.stdin.read())
for d in data:
    print(f"{d['alias']}\t{d['address']}")
```

> 💡 为什么不用 `json.loads`？因为 gsettings 输出的是单引号字典（Python dict 风格），JSON 标准要求双引号，直接 `json.loads` 会报错。`ast.literal_eval` 专门干这个。

### 6.2 从扫描日志里抓 RSSI

`bluetoothctl` 在扫描时会往 stdout 打这种行：

```text
[CHG] Device AA:BB:CC:DD:EE:01 RSSI: -62
```

用 Bash 正则匹配：

```bash
if [[ "$ln" =~ Device[[:space:]]+(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})[[:space:]]+RSSI[[:space:]]+(-[0-9]+) ]]; then
    found_rssi["${BASH_REMATCH[1]}"]="${BASH_REMATCH[3]}"
fi
```

`BASH_REMATCH` 是 Bash 内置数组，存放正则的捕获组。

### 6.3 同名设备 RSSI 择优

对所有 alias 相同的 MAC，比较 RSSI，取最大的：

```bash
local best_mac="" best_rssi=-999
for m in "${!found_alias[@]}"; do
    if [ "${found_alias[$m]}" = "$want_name" ]; then
        r="${found_rssi[$m]:-999}"
        if [ "$r" -gt "$best_rssi" ]; then
            best_rssi="$r"; best_mac="$m"
        fi
    fi
done
```

注意 RSSI 是负数，`-40 > -70`，所以直接数值比较就行。

### 6.4 systemd 里的 D-Bus 坑

```ini
[Service]
Type=oneshot
User=orangepi
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
ExecStart=/usr/local/bin/bt-auto-connect run
```

- `User=orangepi`：必须切到登录用户，否则读不到他的 gsettings；
- `DBUS_SESSION_BUS_ADDRESS`：告诉程序"用户的 D-Bus socket 在哪里"；
- `1000` 是第一个普通用户的 uid，脚本里用 `id -u` 动态算出来，不是硬编码。

### 6.5 无参数运行 = 安装向导

```bash
case "${1:-}" in
    ""|install)   install_wizard ;;
    ...
esac
```

`install_wizard` 会做四件事：

1. 检查依赖（bluetoothctl / gsettings / python3）；
2. 把自己复制到 `/usr/local/bin/bt-auto-connect`；
3. 生成 `/etc/systemd/system/bt-auto-connect.service`；
4. `systemctl enable` 开机自启。

如果发现自己不是 root，会 `exec sudo "$0"` 自动提权重跑。

---

## 七、安装与使用

### 7.1 依赖

```bash
sudo apt update
sudo apt install -y bluez blueman python3 libglib2.0-bin
```

### 7.2 安装

把脚本下载到板子上，加可执行权限，然后**不带任何参数**跑：

```bash
chmod +x bt-auto-connect.sh
./bt-auto-connect.sh
```

它会自动完成安装。装完之后全局命令叫 `bt-auto-connect`。

### 7.3 日常命令

```bash
# 手动跑一次连接流程（调试用）
bt-auto-connect run

# 查看 Blueman 托盘里的「最近连接」缓存
bt-auto-connect cache-list

# 从托盘菜单删除一个设备（同步消失）
bt-auto-connect cache-del "我的键盘"

# 查看手动列表
bt-auto-connect list-list

# 添加一个设备（支持三种写法）
bt-auto-connect list-add "我的键盘"
bt-auto-connect list-add "AA:BB:CC:DD:EE:01"
bt-auto-connect list-add "我的鼠标 AA:BB:CC:DD:EE:02"

# 删除手动列表里的一条
bt-auto-connect list-del "我的键盘"

# 查看开机自启日志
journalctl -u bt-auto-connect.service -f
```

### 7.4 验证开机自启

```bash
systemctl status bt-auto-connect.service
sudo reboot
# 重启后再看日志
journalctl -u bt-auto-connect.service -e
```

---

## 八、常见问题 FAQ

**Q1：跑 `bt-auto-connect cache-list` 提示 gsettings 读取失败？**

A：你大概率是用 `sudo` 跑的。gsettings 是用户会话的配置，**不要加 sudo**。`cache-del` 同理。

**Q2：systemd 日志里说 "无法连接 bus"？**

A：说明 `DBUS_SESSION_BUS_ADDRESS` 路径不对。先在图形界面登录的用户下跑：

```bash
echo $DBUS_SESSION_BUS_ADDRESS
id -u
```

把 systemd 单元里的 `1000` 改成你实际的 uid，把 socket 路径改成你 `echo` 出来的值。

**Q3：脚本说 "全部目标设备连接成功"，但实际键鼠没反应？**

A：蓝牙 HID 设备连上之后，内核需要时间加载 HID 驱动。等 5~10 秒再试。如果还不行，手动在托盘里点一次连接，配对密钥就会在当前会话里生效。

**Q4：为什么不直接 `bluetoothctl trust` 一次永久生效？**

A：因为板子本机蓝牙 MAC 每次重启随机，BlueZ 的配对库按本机 MAC 分目录存。新 MAC = 新目录 = 空库。这是硬件固件的限制，脚本层绕不过去。要根治只能换镜像。

**Q5：能不能把脚本改成后台常驻、断了自动重连？**

A：可以。把 `Type=oneshot` 改成 `Type=simple`，把脚本里的 `while true` 外层再加一个"每 30 秒检查一次连接状态"的循环就行。本项目默认做成 oneshot 是为了简单稳定。

---

## 九、这个项目想教会 AI 初学者什么

如果你是一个刚学会用 AI 写 Python 爬虫、但没怎么碰过 Linux 硬件的人，这个项目值得你跟着做一遍。它真正教你的不是 Bash 语法，而是这几件事：

### 9.1 "现象"和"数据来源"是两回事

图形界面上看到"最近连接里有我的键盘"，这不等于"系统知道怎么连我的键盘"。
- GUI 缓存是一回事；
- BlueZ 配对数据库是另一回事；
- 固件加载脚本又是第三回事。

**AI 最容易犯的错就是把"我看到的现象"直接当成"我能操作的数据"。** 你必须先搞清楚这份数据到底存在哪个文件、哪个 D-Bus 接口里。

### 9.2 失败的尝试要写进 README

很多人写 README 只写"最终方案是什么"。但对学习者来说，**"我们试过 A、B、C 都失败了，为什么失败"** 才是最值钱的部分。这能帮你建立对"哪些路是死胡同"的直觉。

### 9.3 让 AI 帮你定位，而不是替你拍脑袋

整个排查过程中，关键的转折都是这些命令触发的：

```bash
bluetoothctl devices          # 空？说明 BlueZ 库是空的
gsettings list-schemas | grep blueman   # 找到真正的配置 schema
systemctl cat bt-auto-connect.service   # 看真正的服务单元长啥样
```

**AI 不应该直接告诉你答案，它应该告诉你"去跑哪条命令看哪个输出"。** 学会问 AI "我下一步该跑什么命令来验证我的假设"，比学会"AI 帮我写代码"重要得多。

### 9.4 边界要清楚

这个脚本解决不了"蓝牙 MAC 随机"这个根因，它只是**绕过去**。README 里必须明明白白写出来：

> "本脚本不修复随机 MAC，它接受这个限制，然后在限制里把体验做到最好。"

**知道什么是 AI / 脚本做不到的，和知道什么是能做的，一样重要。**

---

## 许可证

MIT

## 致谢

本项目由 AI 辅助全程排查、编写、迭代。所有硬件现象、失败尝试、解决方案均来自一次真实的 Orange Pi 3B + RTL8761B 蓝牙调试会话。
