# SecondSight（第二双眼睛）

帮老人完成数字操作（MyGov、网银、Service NSW）的**只看不控**远程协助工具。
志愿者/AI 能看到打码后的屏幕、画圈指路，永远拿不到控制权；老人主动开启安全监听后，
AssemblyAI 提供实时字幕，本机低延迟规则引擎检测索要验证码、转账和远程控制等话术，
无需把每句话交给昂贵的 LLM。

## 仓库结构与分工

```
docs/
├── DESIGN.md            # 总体设计（两人都读一遍）
├── CONTRACT.md          # ⚠️ 两端接口契约 — 唯一事实来源，不得单方修改
├── TASK_A_MAC.md        # Andy 的任务书 → 喂给 Andy 的 Codex
└── TASK_B_WEB_BACKEND.md# 队友的任务书 → 喂给队友的 Codex
mac/                     # A:老人端 Mac App (Swift)
web/                     # B:志愿者网页 + fake-elder 测试页
supabase/                # B:migrations + edge functions
```

## 协作规则

- 各自只在自己的目录里干活，`docs/CONTRACT.md` 改动必须两人同意。
- 直接 push `main`（48 小时黑客松，不搞 PR 流程），push 前先 `git pull --rebase`。
- 因为目录互斥，正常不会冲突;CONTRACT §6 的配置值由 B 填。
- 联调时间表:CONTRACT §5，四个检查点不见不散。

## 给 Codex 的启动指令（两人各自使用）

> 读 docs/CONTRACT.md 和 docs/TASK_{A|B}_*.md，严格按任务书实现，
> 只允许改动自己负责的目录;接口以 CONTRACT 为准，发现契约不合理之处
> 停下来汇报，不要自行修改契约。
