# 安全策略（Security Policy）

**本页只做一件事：告诉你「发现了一个问题，该往哪儿说、该说什么、绝不该说什么」。**

这个文件是**报告入口**。这个工具的信任模型、两条采集路径的取舍、签名与分发信任、
以及 T1–T10 威胁模型清单，都在
**[`Documentation/SECURITY.md`](Documentation/SECURITY.md)**。
本页**刻意不复制**那份内容——一个仓库里放两份安全全文，迟早变成两份互相矛盾的叙述，
那是缺陷不是便利。两处不一致时，以 `Documentation/SECURITY.md` 为准。

> 位置说明：GitHub 会在仓库根目录、`.github/` 或 `docs/` 三处识别安全策略文件
> （见 [GitHub 官方文档](https://docs.github.com/zh/enterprise-server@3.13/code-security/getting-started/adding-a-security-policy-to-your-repository)），
> 所以放根目录即可被 Security 页识别，不需要再复制一份到 `.github/`。

---

## ⚠️ 报告时**绝不要**附上原始数据库

**Do not attach `observatory.sqlite`. It contains your own absolute paths, your own
command lines, and your own file history. A database file is never needed to diagnose
anything described here.**

这一条不是客套，是这个仓库最容易发生的事故：**报告一个隐私工具的隐私问题，
本身极易变成一次隐私泄漏。**

`observatory.sqlite`（以及 `-wal` / `-shm` 边车）里是：

| 列 | 为什么不能贴 |
| --- | --- |
| `commands.arguments_json` / `search_text` | **全库敏感度最高**。命令行参数里就是文件路径、仓库地址、内联 token |
| `file_changes.path` / `diffs.path` / `file_snapshots.path` | 绝对路径 ⇒ 直接公开你的账户名与目录布局 |
| `diffs.lines_json` | **文件明文片段本身**，私有仓库内容会跟着走 |
| `agents` / `sessions` 的可执行路径与 cwd | 你装过什么、在哪些项目里工作过 |

同样**不要**附：含真实路径的界面截图（Timeline / Files / Commands / Sessions 这几页
会把绝对路径画在屏幕上）、任何真实 token 原文、`~/.ssh` `~/.aws` `~/.gnupg`
`~/Library/Keychains` 里的任何文件内容（这些在本项目里只作为**风险升级的前缀字符串**存在，
我们从来不需要文件本身）。

**该附什么——形状，不是内容：**

```bash
sqlite3 -readonly observatory.sqlite ".schema file_changes"          # 表结构
sqlite3 -readonly observatory.sqlite "select count(*) from diffs;"   # 有多少，不是有什么
select count(*) from commands where arguments_json != '[]';          # 某列非空这件事
```

用 `-readonly`。如果某个**具体值**确实是定位问题的关键，
**造一个能呈现同样形状的假值，并说明它是假的**。

---

## 用哪个模板

| 你要报告的是 | 用这个 |
| --- | --- |
| 这个工具**记录 / 存储 / 导出 / 残留**了让你不安的东西 | [`.github/ISSUE_TEMPLATE/privacy_report.yml`](.github/ISSUE_TEMPLATE/privacy_report.yml) |
| 行为不符合预期：崩溃、错数据、算错的数值、界面与文档不符 | [`.github/ISSUE_TEMPLATE/bug_report.yml`](.github/ISSUE_TEMPLATE/bug_report.yml) |
| 代码层面的安全缺陷（可利用的） | 见下一节「当前没有私密渠道」，先用上面两个模板能说的部分 |

**隐私顾虑不是「跑错地方的 bug 报告」。** 对一个审计工具来说，
「它到底记了多少我的东西」正是最对题的问题，`privacy_report.yml` 就是为它写的
（里面列的每一项都对应本仓库真实代码，不是通用检查清单）。

---

## 当前**没有**私密渠道（如实说明）

本仓库**尚未公开**（`git remote -v` 输出为空）。因此：

- **没有**公开的安全邮箱、**没有** PGP key、**没有** embargo（保密期）约定、
  **没有**响应时限承诺、**没有** disclosure 计划、**没有** moderation 团队。
- 写一个不存在的邮箱在这里，比不写更糟。`Documentation/SECURITY.md` §7 明确拒绝虚构渠道。
- 公开之后：计划启用 GitHub 的 **private vulnerability reporting**（仓库 Security 设置项），
  届时更新本节。在那之前，issue 是**唯一**渠道——而它是公开的，
  点击提交的那一刻就没有撤回的余地，所以请先读完上面那一节。

**能预期的响应**：读到它的是当时手握合并闸门的人。如果你的报告是
「`PRIVACY.md` / `SECURITY.md` 里的某句话比代码强」，
预期结果是**文档被改正**，而不是功能被删——过去每一次这类发现都是这么处理的，
那两份文档里带着日期化的更正记录可以证明。

---

## 什么**不算**漏洞（省掉双方一轮往返）

这几项是**已记录、已定性的设计边界**，重复提交不会提高优先级：

| 现象 | 为什么是记录在案的边界，不是缺陷 |
| --- | --- |
| 轮询采不到短命命令、拿不到退出码 | macOS 无公开非 root 的 exec 事件流可用；退出码需你自己安装 `Tools/AgentHooks/`（默认关）。见 `Documentation/SECURITY.md` §2 |
| 温度 / 功耗显示「这台机器拿不到」 | Apple Silicon 上 SMC 温度 key 多数不存在、整机功耗无公开 API。实现里写明「严禁伪造」，返回 `nil` 是**正确行为** |
| GPU / 网络数值不能归因到某个 Agent | 内核没有公开的非 root 按进程 API，界面上它们只在「整机」口径出现 |
| 命中不到破坏性命令（`r\m -rf`、变量拼接、别名） | 规则是子串/正则匹配，绕过容易 —— `Documentation/SECURITY.md` §5 已如实声明「这是告警，不是阻断」 |
| 数据库可被本机任意进程改写 | 无静态加密、无审计链、非密码学证据。见 T2 |
| 没有「一键删除我的数据」按钮 | 已记录缺口；当前清空是手工 `rm`，见 `Documentation/PRIVACY.md` §3 |
| diff 明文**没有开关可关** | 已记录缺口（`enableDiff` / `captureDiff` 全仓 grep 为 0）。**但如果你发现它比文档写得更宽，那是缺陷，请报** |
| 装了 hook 后可以伪造命令记录 | 已知边界（T9）：能写 `<数据目录>/agent-hooks/` 的人可以伪造额外记录或编造退出码，**不能**抹掉另一条命令 |

**永远值得报的**：**文档声称与代码实际行为不一致。** 这个项目的自我定位是
「宁可把缺口印在首页，也不维持幻觉」，所以这类报告是最高价值的。

---

## 支持哪些版本

0.x 阶段，**只有 `main` 接受安全问题修复**。没有已发布版本的 backport 承诺，
没有版本支持矩阵——因为还没有发布过任何版本。

---

## 相关文档

- [`Documentation/SECURITY.md`](Documentation/SECURITY.md) — 信任模型、能证明什么/不能证明什么、T1–T10 威胁清单、签名与分发信任、无 App Sandbox 的取舍
- [`Documentation/PRIVACY.md`](Documentation/PRIVACY.md) — 数据落在哪、正在采什么（§5.1）、**尚未实现**什么（§7）、本策略**不**声称的内容（§8）
- [`README.md`](README.md) — 八个能力模块的真实完成度与已知限制
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — 社区行为准则
- [`Tools/AgentHooks/README.md`](Tools/AgentHooks/README.md) — 可选精确命令来源，**安装前必读**的隐私说明
