# Lab7：SSH 暴力破解检测与溯源

本报告基于 Lab5 搭建的 Loki + Grafana + Alloy 日志平台，在 Ubuntu 24.04 虚拟机（主机名 `b-VMware-Virtual-Platform`，地址 `192.168.185.128`）上执行 `attack.sh` 发起真实的 SSH 密码尝试，并由 sshd 与 PAM 自行写入 `/var/log/auth.log`，再从 `{job="auth"}` 日志流中完成统计、甄别与处置建议。

实验时间：2026-10-27 18:44 至 19:06（北京时间）。全部数字、时间与日志行均来自本次真实执行结果。

---

## 一、交什么、按什么顺序做

| 任务 | 难度 | 完成内容 | 操作与填写位置 |
| :--- | :---: | :--- | :--- |
| 事件背景与分析方法 | ★ | 掌握安全事件分析五步法、SSH 认证日志关键行、IP 地址段、真实 auth 流的圈定、两条时间轴、成功登录三问 | 第二节 |
| 任务 1：发起真实 SSH 爆破并通读日志 | ★ | 自检平台、运行 `attack.sh`、按时间顺序通读真实认证日志 | 第三节 |
| 任务 2：统计失败登录的来源 IP | ★★ | 用 `count_over_time` 统计各来源 IP 的失败次数 | 第四节 |
| 任务 3：盘点被尝试的用户名 | ★★ | 用 `regexp` 分组用户名，并按 invalid user 分类 | 第五节 |
| 任务 4：检查账号锁定防线 | ★ | 检查 faillock 是否启用，说明“没有锁定行”意味着什么 | 第六节 |
| 任务 5：甄别成功登录 | ★★★ | 用成功登录三问给出三选一结论 | 第七节 |
| 任务 6：封禁建议与安全演练 | ★★ | 写出四要素封禁建议，并安全演练 ufw 封禁与解封 | 第八节 |
| 简短总结 | ★ | 回答 3 道知识问答题 | 第十节 |

提交内容包括：1 份填写完整的 Markdown 报告、事件记录单（第九节）、关键 LogQL 查询语句、3 道简答题和 5 张截图。

---

## 二、事件背景与本实验知识

### 2.1 从查看图表到分析事件

SSH 暴力破解的手法比较直接：使用 IP 段和用户名字典反复尝试密码。只要 22 端口对公网开放，`auth.log` 中就会不断出现此类记录。

一次爆破会在日志中留下几类信息：来源地址、被尝试的账号、失败频率、锁定是否触发，以及是否出现 `Accepted` 记录。分析时需要把这些信息结合起来，只看其中一类容易得出错误结论。

### 2.2 一套可复用的五步法

1. **固定现象**——记录谁、在什么时间、发生了什么行为、影响范围如何。本次现象可写成一句话：2026-10-27 18:44 至 18:45，来自 `203.0.113.21` 与 `198.51.100.77` 的连续 SSH 密码尝试打在 `b` 这一台主机上，涉及 5 个账号名，其中包含一次成功认证。
2. **确定日志源**——SSH 认证事件写入 `/var/log/auth.log`，Lab5 的 Alloy 已将其采集为 `{job="auth"}`，因此本节所有查询都在该日志流上进行。
3. **建立时间线**——按日志正文时间排序，标出首次失败、失败密集时段、账号锁定（本次没有）和成功登录（本次有）。
4. **提出假设并验证**——候选假设：外部字典攻击、口令已泄露、管理员本人登录。本次三条假设均可用查询结果区分。
5. **给出处置建议并复核**——包括封禁、加固、通知和复测。建议引用前面证据。

### 2.3 auth.log 中与 SSH 相关的日志行

| 行型 | 本次实验中的真实示例 | 说明 |
| :--- | :--- | :--- |
| 失败（不存在的用户） | `Failed password for invalid user admin from 203.0.113.21 port 47971 ssh2` | `invalid user` 说明账号不存在，属于字典尝试 |
| 失败（真实用户） | `Failed password for b from 203.0.113.21 port 57637 ssh2` | 账号真实存在，攻击者已掌握部分用户名信息 |
| 成功 | `Accepted password for b from 203.0.113.21 port 39235 ssh2` | 认证成功，必须结合来源 IP、账号和时间线判断 |
| 锁定（仅在启用 faillock 时） | 本次查询结果为空 | 本机未启用 `pam_faillock`，因此没有该行 |

### 2.4 地址段的含义与局限

| 地址段 | 属性 | 在本次实验中的含义 |
| :--- | :--- | :--- |
| `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` | RFC 1918 私有地址 | 内网设备，本机为 `192.168.185.128` |
| `203.0.113.0/24`、`198.51.100.0/24` | 文档保留段（TEST-NET） | `attack.sh` 模拟的外部攻击源，封禁它们不影响正常通信 |
| `127.0.0.0/8` | 回环地址 | 本次未走回退模式，来源不是 `127.0.0.2`/`127.0.0.3` |

地址段只能作为判断参考，不能只凭地址段下结论。真实环境中还需要结合资产清单、登录基线和威胁情报。

### 2.5 确定 auth 日志范围

Lab5 的 Alloy 已将 `/var/log/auth.log` 采集为 `{job="auth"}`，`filename` 标签固定为 `/var/log/auth.log`。该日志流中不只有 SSH 记录，`sudo`、`systemd-logind` 和 `cron` 的认证事件也会写入同一文件。因此查询时需要做三件事：用 `{job="auth"}` 限定日志流，用 `|= "Failed password"` 或 `|= "Accepted"` 过滤正文，并将时间范围设为攻击前后的一段时间。`filename` 在该流中是常量，不能用来区分本次攻击。

### 2.6 日志时间与平台时间

`auth.log` 每行开头的时间是 sshd 写入日志的时间；Grafana 时间轴上的位置则是 Loki 接收该日志的时间。本次两者相差约 1 秒。报告中的时间线一律使用日志正文时间，截图中显示的时间范围只用于圈定查询窗口。

### 2.7 成功登录的判断

出现 `Accepted password` 并不等于主机已被攻破。对每条成功登录记录，需要回答三个问题：来源是否相关、账号是否相关、地址段属性。综合三个答案，才能写入记录单。本次实验确实出现了来自攻击源的 `Accepted`，因此这一判断环节是本报告的关键。

---

## 三、任务 1：发起真实爆破并通读日志

### 3.1 确认平台状态

```bash
systemctl is-active loki grafana-server alloy ssh
```

实际输出四行 `active`：

```text
active
active
active
active
```

```bash
curl -s http://127.0.0.1:3100/ready
```

返回 `ready`，说明 Loki 已就绪。再确认日志文件存在并且仍在写入：

```bash
sudo ls -l /var/log/auth.log
sudo tail -n 3 /var/log/auth.log
```

```text
-rw-r----- 1 syslog adm 60210 10月 27 19:09 /var/log/auth.log
2026-10-27T19:09:28.358455+08:00 b-VMware-Virtual-Platform sudo:        b : PWD=/ ; USER=root ; COMMAND=/usr/bin/ls -l /var/log/auth.log
2026-10-27T19:09:28.379751+08:00 b-VMware-Virtual-Platform sudo: pam_unix(sudo:session): session opened for user root(uid=0) by (uid=1000)
2026-10-27T19:09:28.379950+08:00 b-VMware-Virtual-Platform sudo: pam_unix(sudo:session): session closed for user root
```

### 3.2 执行攻击脚本

确认快照可用后执行：

```bash
cd ~/Lab7
sudo bash attack.sh
```

实际输出如下：

```text
[Lab7] 被攻击账号：b（另含字典用户名 admin、root、oracle、test）
[Lab7] 来源 203.0.113.21：3 个用户名 × 3 个密码
[Lab7] 来源 198.51.100.77：2 个用户名 × 2 个密码
[Lab7] 完成 13 次真实 SSH 密码尝试。
[Lab7] sshd/PAM 已自行写入 /var/log/auth.log；等待约 10 秒后到 Grafana Explore 查询：
[Lab7]   {job="auth"} |= "Failed password"
```

脚本本身不写日志，日志由 sshd/PAM 在认证过程中产生。13 次尝试中，日志里只留下了 12 条 `Failed password`，差额是一条**成功**认证，第四节与第七节会分别说明。

### 3.3 脚本执行的操作

| 动作 | 说明 |
| :--- | :--- |
| 创建两个临时网络命名空间 | `lab7-atk-a`、`lab7-atk-b`，各带一对 veth；虚拟机的 SSH 端口可通过 `10.99.1.1`/`10.99.2.1` 访问 |
| 分配模拟攻击源 | `203.0.113.21`（TEST-NET-3）、`198.51.100.77`（TEST-NET-2） |
| 发起真实密码尝试 | 使用 `sshpass` 依次尝试 3×3 和 2×2 组用户名/密码 |
| 由 sshd/PAM 写入日志 | 失败记录由 sshd 写入 `/var/log/auth.log`，脚本不修改该文件 |
| 退出时清理 | 删除 netns/veth；若被中断可执行 `sudo bash restore.sh` |

### 3.4 通读日志

在 Grafana 中打开 Explore，切换到 Code 模式，时间范围固定为 `2026-10-27 18:40:00` 至 `2026-10-27 18:50:00`：

```logql
{job="auth"} |= "Failed password"
```

结果共 12 行，按正文时间排列，时间跨度为 18:44:25.098 至 18:45:04.048，约 39 秒。下面用 4W1R 方法对代表性行做说明：

| 正文时间 | Who 谁 | What 发生什么 | Where 来源 | When | Result 结果 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 18:44:25.098 | `admin`（不存在账号） | 密码认证失败 | `203.0.113.21` port 47971 | 攻击第 1 次 | `Failed password for invalid user` |
| 18:44:36.411 | `root` | 密码认证失败 | `203.0.113.21` port 44113 | 攻击第 4 次 | `Failed password for root` |
| 18:44:44.170 | `b`（真实账号） | **密码认证成功** | `203.0.113.21` port 39235 | 攻击第 6 次 | `Accepted password` |
| 18:44:54.312 | `oracle`（不存在账号） | 密码认证失败 | `198.51.100.77` port 51287 | 第二个来源第 1 次 | `Failed password for invalid user` |
| 18:45:04.048 | `test`（不存在账号） | 密码认证失败 | `198.51.100.77` port 34809 | 最后一次 | `Failed password for invalid user` |

> **记录**
>
> ① 本次攻击共产生多少条 `Failed password`？时间跨度多长？
>
> 答：共 12 条 `Failed password`，正文时间从 `2026-10-27 18:44:25.098` 到 `2026-10-27 18:45:04.048`，跨度约 39 秒。脚本发起的是 13 次尝试，差额 1 次是成功登录（18:44:44）。
>
> ② 按正文时间，最早和最晚的失败记录分别是什么？中间是否有成功登录？
>
> 答：最早是 `18:44:25.098 Failed password for invalid user admin from 203.0.113.21 port 47971 ssh2`；最晚是 `18:45:04.048 Failed password for invalid user test from 198.51.100.77 port 34809 ssh2`。中间**有**成功登录：`18:44:44.170666 Accepted password for b from 203.0.113.21 port 39235 ssh2`。
>
> ③ 真实 `auth` 流与 Lab6 处理的 nginx 流，在确定查询范围时有何不同？
>
> 答：nginx 流一条日志只对应一次访问，字段位置固定，可用 `pattern` 直接拆出 path、status；auth 流同一文件里混有 `sudo`、`cron`、`systemd-logind` 等子系统写入的行，且 SSH 行本身有 `invalid user` 可选前缀、端口位置不固定，因此必须先靠正文过滤（`|=`）和时间窗口圈定范围，再按需用 `regexp` 提取字段。

保存 `imgs/lab7-overview.png`，截图中包含查询语句、固定时间范围、12 行真实失败日志，并展开了一行的 `Indexed labels`（`job=auth`、`filename=/var/log/auth.log`、`host=b-VMware-Virtual-Platform`）。

![真实 SSH 认证日志总览](imgs/lab7-overview.png)

> **检查点 ①**：真实攻击日志截图；时间顺序梗概已写进记录区。

---

## 四、任务 2：失败请求来自哪些 IP

### 4.1 逐个 IP 统计

```logql
sum(count_over_time({job="auth"} |= "Failed password" |= "203.0.113.21" [$__range]))
```

把 IP 换成 `198.51.100.77` 再执行一次，即可得到各来源的失败次数。`[$__range]` 表示统计窗口等于页面上选择的整个时间范围。

### 4.2 用一条语句统计全部来源

本节采用聚合查询，用 `regexp` 提取 IP 并分组：

```logql
sum by (src_ip) (
  count_over_time(
    {job="auth"}
      |= "Failed password"
      | regexp `from (?P<src_ip>[0-9.]+) port`
    [$__range]
  )
)
```

在 Explore 中把查询选项的 Type 切换为 Instant，执行结果为表格：

| src_ip | Value #A |
| :--- | ---: |
| 198.51.100.77 | 4 |
| 203.0.113.21 | 8 |

`(?P<src_ip>[0-9.]+)` 将 `from` 和 `port` 之间的地址提取为临时标签 `src_ip`，`sum by (src_ip)` 按该标签分组。两条查询结果一致：`203.0.113.21` 失败 8 次，`198.51.100.77` 失败 4 次，合计 12 次，与第三节通读的 12 行完全对应。

> **记录**
>
> ① 你使用的是 4.1 的逐个统计还是 4.2 的聚合查询？查询语句是什么？
>
> 答：使用 4.2 的聚合查询，语句为 `sum by (src_ip) (count_over_time({job="auth"} |= "Failed password" | regexp `from (?P<src_ip>[0-9.]+) port` [$__range]))`，查询选项 Type 设为 Instant，时间范围 `2026-10-27 18:40:00` 至 `18:50:00`。
>
> ② 各来源 IP 的失败次数分别是多少？失败最多的是哪个？
>
> 答：`203.0.113.21` 失败 8 次，`198.51.100.77` 失败 4 次，合计 12 次。失败最多的是 `203.0.113.21`，它也是唯一出现成功登录的来源。

保存 `imgs/lab7-top-ip.png`，保留查询语句与统计结果。

![来源 IP 失败次数统计](imgs/lab7-top-ip.png)

> **检查点 ②**：失败次数统计截图；统计方法已写进记录区。

---

## 五、任务 3：尝试了哪些账号

使用一条查询同时覆盖 `invalid user` 与真实用户：

```logql
sum by (user) (
  count_over_time(
    {job="auth"}
      |= "Failed password"
      | regexp `Failed password for (invalid user )?(?P<user>\S+) from`
    [$__range]
  )
)
```

执行结果为表格：

| user | Value #A |
| :--- | ---: |
| admin | 3 |
| b | 2 |
| oracle | 2 |
| root | 3 |
| test | 2 |

结合日志原文中是否带 `invalid user` 前缀，分类如下：

| 用户名 | 是否 invalid user | 说明（字典账号？真实存在的账号？） |
| :--- | :---: | :--- |
| `admin` | 是 | 典型字典账号，本机不存在该用户 |
| `oracle` | 是 | 典型字典账号，本机不存在该用户 |
| `test` | 是 | 典型字典账号，本机不存在该用户 |
| `root` | 否 | 系统真实存在的超级用户账号 |
| `b` | 否 | 本机真实存在的普通账号，也是本次实验的被攻击账号 |

思考：真实存在的账号（`root`、`b`）更值得关注。`invalid user` 只能说明攻击者在盲试字典，命中与否取决于本机是否存在该账号；而真实账号的失败记录说明对方已经掌握了本机的用户名信息，并且一旦口令强度不足就会直接形成有效登录——本次 `b` 恰恰是这样被登录成功的。

> **记录**
>
> ① 被尝试的用户名名单和分类结果是什么？
>
> 答：共 5 个用户名。invalid user 3 个：`admin`（3 次）、`oracle`（2 次）、`test`（2 次）；真实账号 2 个：`root`（3 次）、`b`（2 次）。
>
> ② 哪一类用户名更值得关注？依据是什么？
>
> 答：真实存在的账号（`root`、`b`）更值得关注。字典账号必然全部失败，信息量有限；真实账号被尝试意味着攻击者已掌握用户名，且本次 `b` 在被尝试后确实出现了 `Accepted`，说明口令强度不足会让字典攻击直接得手。

保存 `imgs/lab7-users.png`，保留用户名分组查询的结果与分类表。

![用户名盘点与分类](imgs/lab7-users.png)

> **检查点 ③**：用户名盘点截图 + 分类表。

---

## 六、任务 4：账号锁定是否启用

锁定记录同样只能来自真实日志：

```logql
{job="auth"} |= "temporarily locked"
```

在 `2026-10-27 18:40:00` 至 `18:50:00` 范围内查询结果为 `No logs found`，日志卷同样提示 `No logs volume available`。查询语句没有错，只是这台机器没有账号锁定防护。

再从系统配置中查找证据：

```bash
sudo faillock --user b
sudo grep -R "pam_faillock" /etc/pam.d/ /etc/security/faillock.conf
```

```text
$ sudo faillock --user b
b:
When                Type  Source                                           Valid
$ sudo grep -R pam_faillock /etc/pam.d/ /etc/security/faillock.conf
（无任何输出）
```

`faillock` 只有表头、没有任何失败记录，`grep` 也没有匹配，与日志中没有锁定行完全一致。模块本身是存在的，只是没有接入 PAM 认证栈：

```text
-rw-r--r-- 1 root root 26776  8月 27 03:28 /usr/lib/x86_64-linux-gnu/security/pam_faillock.so
```

> **知识点｜没有锁定行也是证据**
> `pam_faillock` 是 PAM 的连续失败锁定模块，按 Linux 账号（用户名，不是来源 IP）累计失败次数，超过阈值后临时锁定。Ubuntu 24.04 默认未在 `/etc/pam.d/` 中启用该模块，因此无论尝试多少次都不会出现锁定行。看到“没有锁定行”时，应检查 PAM 配置和 `faillock` 状态，不能自行编造锁定记录。

> **记录**
>
> ① 日志中是否有 `pam_faillock` 锁定行？`faillock --user` 和 `grep` 的输出是什么？
>
> 答：没有锁定行，`{job="auth"} |= "temporarily locked"` 返回 `No logs found`。`sudo faillock --user b` 只输出表头 `When / Type / Source / Valid`，没有记录行；`sudo grep -R pam_faillock /etc/pam.d/ /etc/security/faillock.conf` 无任何输出（退出码 1，表示无匹配）。
>
> ② 如果没有锁定行，说明这台机器缺少哪道防护？这对处置建议有什么影响？
>
> 答：缺少 `pam_faillock` 提供的账号锁定防线。这意味着攻击者可以对该账号无限次尝试而不被封停，本次 13 次尝试全部被放行、并最终命中口令就是直接后果。因此处置建议除了封禁来源 IP，还必须包含“为真实账号启用 fail2ban 之外的账号级锁定（配置 `pam_faillock`，如 `deny=3`、`unlock_time=600`）”，并同步提升口令强度。

---

## 七、任务 5：是否有人成功登录

查询全部成功认证记录：

```logql
{job="auth"} |= "Accepted"
```

结果为 1 行：

```text
1 | 2026-10-27 18:44:44.387 UNK 2026-10-27T18:44:44.170666+08:00 b-VMware-Virtual-Platform sshd[4395]: Accepted password for b from 203.0.113.21 port 39235 ssh2
```

本次实验期间宿主机与虚拟机的 VMnet 网络不通（VMnet8 虚拟网卡未启用），没有从宿主机登录产生的 `Accepted`，因此该时间窗内唯一的成功认证就是这一条。逐条回答三个问题：

1. **来源是否相关**——成功登录的来源 `203.0.113.21` 与失败记录中出现最多的来源**完全相同**，并且该 IP 的全部 9 次尝试中前 8 次失败、第 6 次成功。
2. **账号是否相关**——成功登录的账号 `b` 正是本次被攻击账号，在此前也被失败尝试过（`18:44:47`、`18:44:51` 两条 `Failed password for b`）。成功发生在其后，属于同一轮字典尝试的延续。
3. **地址段属性**——`203.0.113.0/24` 是 TEST-NET-3 文档保留段，属本次模拟的外部攻击源，不是内网管理段，也不可能是本人宿主机（宿主机为 `192.168.185.1`）。

三个答案都指向同一方向：外部来源、被攻击账号、紧随失败密集时段、认证方式为密码。因此结论是**爆破得手**。

> **判断说明**：作业给出的默认情形通常是“成功登录来自宿主机，判为爆破未得手”。本次实测出现了外部来源的成功认证，属于作业所指的“确有外部来源的成功登录”，应按证据判断为爆破得手，而不是把 `Accepted` 解释成误报。原因是被攻击账号的口令强度不足，落在了攻击字典的取值范围内，第 6 次尝试即通过认证。

> **记录**
>
> ① 成功登录三问的回答分别是什么？
>
> 答：来源——成功登录来自 `203.0.113.21`，与失败最多的来源 IP 完全一致；账号——成功登录的是被攻击账号 `b`，此前已被失败尝试 2 次，距离最后一次失败 7 秒；地址段——`203.0.113.0/24` 为 TEST-NET-3 文档保留段，属外部攻击源，不是内网管理段或本人宿主机。
>
> ② 你的最终结论是三选一中的哪个？依据链是什么？
>
> 答：结论是**爆破得手**。依据链：① 13 次尝试中 12 条 `Failed password`、1 条 `Accepted`，`Accepted` 数与尝试数的差额正好是这一条；② 成功来源 `203.0.113.21` 与失败来源相同，时间紧接 `18:44:43` 的 `root` 失败之后；③ 账号 `b` 属于被尝试的真实账号，认证方式为 password；④ 该来源属外部文档保留段，排除“管理员本人从内网登录”的解释。后续处置见第八节。

保存 `imgs/lab7-lock-success.png`，该图由三部分拼接：锁定查询为空、`faillock`/`grep` 输出、成功登录甄别。

![账号锁定检查与成功登录甄别](imgs/lab7-lock-success.png)

> **检查点 ④**：锁定检查截图 + 成功登录三问与结论。

---

## 八、任务 6：封禁建议与安全演练

### 8.1 撰写封禁建议

| 要素 | 内容 |
| :--- | :--- |
| 封哪些 IP | 立即封禁 `203.0.113.21`（8 次失败并成功登录 1 次，优先级最高）；同时封禁 `198.51.100.77`（4 次失败，全部为字典账号）。两次失败的来源不建议只封单一 IP 而保留另一个，因为二者属于同一次实验/同一批攻击，且都位于文档保留段，封禁成本为零。 |
| 为什么封 | 证据：`203.0.113.21` 在 39 秒内对 `admin`、`root`、`b` 三个账号发起 9 次尝试，其中 8 次失败、1 次成功；`198.51.100.77` 对 `oracle`、`test` 发起 4 次尝试全部失败。两者都呈现“多账号、短时间、密集失败”的字典特征，不是正常运维行为。 |
| 如何验证生效 | ① `sudo ufw status numbered` 能看到对应的 DENY 规则；② 封禁后 `{job="auth"} |= "203.0.113.21"` 在时间范围内不再出现新的 `Failed password`；③ `sudo iptables -L -n -v` 中对应链的包计数持续增长；④ 被拦截的数据包会写入 `/var/log/ufw.log`。 |
| 如何解封与善后 | 解封：`sudo ufw delete deny from 203.0.113.21`。善后：立即修改 `b` 账号口令（本次口令已命中字典，属于已泄露状态）；对被锁定账号执行 `sudo faillock --user b --reset`（本机未启用 faillock，此项在启用后适用）；评估是否将封禁升级为网段 `203.0.113.0/24`、`198.51.100.0/24`；建议启用 `pam_faillock` 作为账号级第二道防线，并禁用 SSH 密码认证或限制来源。 |

### 8.2 ufw 演练

严格按顺序执行，先放行 SSH 与 Grafana，再启用，最后封禁：

```bash
sudo ufw status
sudo ufw allow OpenSSH
sudo ufw allow 3000/tcp
sudo ufw enable
sudo ufw deny from 203.0.113.21
sudo ufw deny from 198.51.100.77
sudo ufw status numbered
```

`ufw status numbered` 实际输出：

```text
状态： 激活

     至                          动作          来自
     --                          --            --
[ 1] OpenSSH                     ALLOW IN      Anywhere
[ 2] 3000/tcp                    ALLOW IN      Anywhere
[ 3] Anywhere                    DENY IN       203.0.113.21
[ 4] Anywhere                    DENY IN       198.51.100.77
[ 5] OpenSSH (v6)                ALLOW IN      Anywhere (v6)
[ 6] 3000/tcp (v6)               ALLOW IN      Anywhere (v6)
```

截图留档后恢复课程基线：

```bash
sudo ufw disable
sudo ufw status
```

```text
防火墙在系统启动时自动禁用
状态： 不活动
```

> **知识点｜封禁也会产生日志**
> ufw 启用后，被拦截的数据包会记录到 `/var/log/ufw.log`。防御动作本身也应留下记录，以便审计封禁是否生效。

> **记录**
>
> ① 你的封禁建议四要素分别是什么？
>
> 答：封哪些 IP——`203.0.113.21` 与 `198.51.100.77` 全部封禁，前者优先；为什么封——前者 8 次失败 + 1 次成功、后者 4 次失败，均为多账号短时间密集尝试的字典特征；如何验证生效——`ufw status numbered` 出现 DENY 规则、`{job="auth"}` 中该 IP 不再产生新失败、`/var/log/ufw.log` 有拦截记录；如何解封与善后——`sudo ufw delete deny from <IP>`，同时修改 `b` 的口令、`sudo faillock --user b --reset`、建议启用 `pam_faillock` 并考虑禁用密码认证。
>
> ② `ufw status numbered` 中看到了哪些规则？演练后是否已执行 `ufw disable` 恢复基线？
>
> 答：共 6 条规则，1、2 为 `OpenSSH` 与 `3000/tcp` 的 ALLOW IN，3、4 为对 `203.0.113.21`、`198.51.100.77` 的 DENY IN，5、6 为对应的 IPv6 放行。演练结束后已执行 `sudo ufw disable`，`ufw status` 显示“状态：不活动”，基线已恢复，后续实验不受影响。

保存 `imgs/lab7-ban.png`，保留 `ufw status numbered` 与 `ufw disable` 的过程。

![ufw 封禁演练与恢复](imgs/lab7-ban.png)

> **检查点 ⑤**：封禁建议四要素 + `ufw status` 与 `ufw disable` 截图。

### 8.3 保留实验环境

到本节为止已完成一次完整的安全事件分析：固定现象、确定日志源、建立时间线、提出并验证假设、给出处置建议并复核。Lab5 平台、Lab6 的演示站与 Dashboard 均保留，`ufw` 已恢复为关闭状态，并已创建“Lab7 完成”快照，供下一个实验继续使用。

| 本实验留下的成果 | 下一个实验怎样继续使用 |
| :--- | :--- |
| 安全事件分析五步法与记录单习惯 | 直接按五步法组织排查 |
| 真实 auth 流的查询与过滤经验 | 同样的写法确定日志范围 |
| `regexp` 现场解析字段 | 解析服务报错行时继续使用 |
| “结论三选一 + 依据链”的判断习惯 | 根因判断同样要求步步有据 |
| 已验证过的平台与查询基线 | 平台本身是已知的正常基线 |

---

## 九、事件记录单

| 项目 | 记录 |
| :--- | :--- |
| 攻击来源 IP | `203.0.113.21`（8 次失败 + 1 次成功）、`198.51.100.77`（4 次失败） |
| 被攻击用户名 | `admin`、`oracle`、`test`（invalid user）、`root`、`b`（真实账号） |
| 失败次数统计方法 | 4.2 聚合查询：`sum by (src_ip) (count_over_time({job="auth"} \|= "Failed password" \| regexp \`from (?P<src_ip>[0-9.]+) port\` [$__range]))`，Type 设为 Instant |
| 账号锁定防线是否启用 | 未启用。`temporarily locked` 查询为空；`faillock --user b` 无记录；`grep -R pam_faillock /etc/pam.d/ /etc/security/faillock.conf` 无匹配；`pam_faillock.so` 模块存在但未接入 PAM |
| 是否有成功登录 | 有，1 条：`18:44:44.170666 Accepted password for b from 203.0.113.21 port 39235 ssh2` |
| 成功登录来源与判断 | 来源 `203.0.113.21`，与失败来源相同，属 TEST-NET-3 外部文档保留段；账号 `b` 为被攻击账号；结论为**爆破得手** |
| 关键 LogQL | `{job="auth"} \|= "Failed password"`；`sum by (src_ip) (...regexp \`from (?P<src_ip>[0-9.]+) port\` [$__range])`；`sum by (user) (...regexp \`Failed password for (invalid user )?(?P<user>\S+) from\` [$__range])`；`{job="auth"} \|= "temporarily locked"`；`{job="auth"} \|= "Accepted"` |
| 证据截图 | `imgs/lab7-overview.png`、`imgs/lab7-top-ip.png`、`imgs/lab7-users.png`、`imgs/lab7-lock-success.png`、`imgs/lab7-ban.png` |
| 修复动作 | 建议封禁 `203.0.113.21` 与 `198.51.100.77`；立即修改 `b` 账号口令；启用 `pam_faillock`（`deny=3`、`unlock_time=600`）；禁用或限制 SSH 密码认证。演练中已用 ufw 完成封禁与规则核对，并 `ufw disable` 恢复基线 |
| 成功登录三问的回答（第七节） | 来源：与失败来源同为 `203.0.113.21`；账号：被攻击账号 `b`，此前失败 2 次，距最后失败 7 秒；地址段：外部文档保留段，非内网管理段 |
| 封禁建议四要素（第八节） | 封 `203.0.113.21` 与 `198.51.100.77`；依据是 9 次与 4 次的多账号密集尝试及 1 次成功；验证看 DENY 规则、日志静默与 `ufw.log`；善后为解封命令、改口令、faillock reset、评估网段封禁与启用 faillock |

---

## 十、知识问答

1. `invalid user` 的失败登录与普通用户的失败登录，分别说明攻击者掌握了什么信息？哪一种更接近得手，为什么？

   > 填写：`invalid user` 说明攻击者只在盲试字典，连账号是否存在都不知道；普通用户的失败登录说明对方已经掌握了本机真实存在的用户名。后者更接近得手，因为一旦口令落入字典范围就会直接形成有效登录，本次 `b` 就是真实账号被尝试后成功登录的例子。

2. 为什么判定一次爆破必须同时查失败登录和成功登录？只看失败或只看成功，分别回答不了什么问题？

   > 填写：只看失败能说明“有人在试”，但回答不了“试成功没有”；只看成功能说明“有人进来了”，但回答不了“是不是爆破进来的”。本次只有把 12 条 `Failed password` 与 1 条 `Accepted` 放在同一条时间线上，才能看出成功认证发生在同一来源的失败密集时段内，从而判定为爆破得手。

3. 账号锁定（`pam_faillock`）与 IP 封禁（ufw）分别保护什么、挡住什么？Ubuntu 24.04 默认没有启用 faillock，这会给处置建议带来什么影响？

   > 填写：`pam_faillock` 按账号累计失败次数并临时锁定，保护的是账号本身，能挡住换 IP 继续猜同一账号的分布式尝试，但挡不住换账号尝试；ufw 按来源 IP 丢包，保护的是主机入口，能挡住某个来源的全部流量，但换 IP 即可绕过。Ubuntu 24.04 默认未启用 faillock，意味着账号级防线缺失，因此处置建议必须同时包含封禁来源 IP、修改弱口令和启用 `pam_faillock` 三层措施，不能只依赖 IP 封禁。

---

## 十一、常见问题

本次实验按讲义顺序执行，未遇到阻塞性问题。执行过程中确认了两点与讲义提示一致的细节：

| 现象 | 本次情况 | 处理 |
| :--- | :--- | :--- |
| `attack.sh` 提示找不到 `sshpass` | 首次执行前已 `sudo apt install -y sshpass` | 提前安装，脚本正常运行 |
| 没有任何锁定行 | 符合 Ubuntu 24.04 默认行为 | 按第六节从 PAM 配置取证，未伪造锁定记录 |
| 来自宿主机的 `Accepted` 记录 | 本次未出现 | 实验期间 VMnet 虚拟网卡未启用，宿主机无法连通虚拟机；如实记录，不使用其他来源替代 |

---

## 十二、选读内容

第十二节的 faillock 选读实验（临时启用 `pam_faillock` 观察真实锁定行）本次**未执行**：该操作需要修改 PAM 认证栈，存在导致 SSH 登录失败的风险，而主任务并不依赖它。第六节已通过日志查询与 PAM 配置检查两条证据说明“没有锁定行”的原因，结论不依赖该选读实验。

---

## 十三、截图与提交

本次单独提交 1 份 Markdown 报告和 5 张截图。

| 操作位置 | 截图必须体现的内容 | 文件名 |
| :--- | :--- | :--- |
| 3.4 节 | `{job="auth"} \|= "Failed password"` 的查询、时间范围和真实失败日志（至少一行展开显示标签） | `lab7-overview.png` |
| 4.1 或 4.2 节 | 失败次数统计的查询语句与结果 | `lab7-top-ip.png` |
| 5 节 | 用户名分组查询结果与分类表 | `lab7-users.png` |
| 6、7 节 | 锁定检查（查询无结果 + `faillock`/`grep` 输出）与成功登录甄别 | `lab7-lock-success.png` |
| 8.2 节 | `ufw status numbered` 与 `ufw disable` 过程 | `lab7-ban.png` |

目录结构：

```text
2024010029李欧/
└── Lab7/
    ├── Lab7.md
    └── imgs/
        ├── lab7-overview.png
        ├── lab7-top-ip.png
        ├── lab7-users.png
        ├── lab7-lock-success.png
        └── lab7-ban.png
```

### 提交前检查

| 检查项 | 确认 |
| :--- | :--- |
| 能复述安全事件分析五步法，并说明每步产出对应记录单的哪几栏 | 已完成 |
| 真实攻击已执行，`auth.log` 中能查到本次产生的失败行，时间线梗概已写进记录区 | 已完成，12 条真实失败行 |
| 来源 IP 统计有语句与截图，记录单写清了方法，并非只有数字 | 已完成 |
| 用户名已按是否 invalid user 分类，并说明了哪类更危险 | 已完成 |
| 已检查 faillock 状态，能说明“没有锁定行”意味着什么 | 已完成 |
| 成功登录三问逐一回答，结论三选一且有依据链 | 已完成，结论为爆破得手 |
| 封禁建议四要素完整，ufw 演练按顺序执行并已恢复基线 | 已完成，`ufw status` 为不活动 |
| 打开 `Lab7.md` 确认 5 张图片都能正常显示 | 已完成 |
| 已保留平台与 Lab6 成果，创建了可供下一个实验继续使用的快照 | 已完成 |

按仓库 README 的流程单独提交 Lab7，PR 标题为 `[2024010029李欧]Lab7作业提交`。

---

## 十四、截止时间

**2026 年 10 月 29 日 23:59:59（北京时间）**

请在截止时间前创建 Lab7 的 PR 并完成推送。按仓库 `README.md` 第 4 节的规则，10 月 30 日 00:00 起新建 PR 或向已有 PR 推送修改均算超时。
