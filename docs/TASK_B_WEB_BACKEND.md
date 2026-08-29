# TASK B — 志愿者 Web 端 + Supabase 后端（负责人:队友）

> 交给 Codex 的任务书。先读 `docs/CONTRACT.md`（接口契约，不得擅改），
> 背景细节在 `docs/DESIGN.md` §3–§4。代码放 `web/` 和 `supabase/`。
> 你还负责两个云项目的创建与配置（LiveKit Cloud + Supabase），
> 建好后把三个公开配置值填进 CONTRACT §6 并 commit。

## B0. 云项目配置（最先做，A 在等）

1. LiveKit Cloud 免费项目 → 记下 `LIVEKIT_URL`、API key/secret。
2. Supabase 项目 → 记下 URL、anon key。
3. `supabase secrets set LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=... LIVEKIT_URL=... ANTHROPIC_API_KEY=...`
4. 把三个公开值填进 `docs/CONTRACT.md` §6，commit + push，通知 A。
5. 给 A 开 LiveKit 控制台访问（A 需要手签测试 token）。

## B1. 数据库（`supabase/migrations/`）

三张表按 `docs/DESIGN.md` §4.1 的 DDL 原样建:`sessions`、`session_events`、
`alerts`。全部开启 RLS 且**不写任何 allow 策略**（deny-all）——所有读写
只经 Edge Function 的 service_role。

## B2. Edge Functions（`supabase/functions/`，Deno/TS）

五个,请求/响应格式**严格按 CONTRACT §4**（A 的客户端按契约硬编码）:

1. **create-session**:生成不冲突 6 位数字码;插 sessions(status=waiting);
   用 livekit-server-sdk 签 token（identity=`elder`, room=code,
   canPublish+canSubscribe）→ 按契约返回。
2. **join-session**:按 code 查 sessions，不存在→404，status=ended→410;
   更新 volunteer_label、status=active;签 token（identity=`volunteer:{name}`，
   `canPublishSources: ["microphone"]` —— 这是"只看不控"的 token 层防线，
   必须验证生效）→ 按契约返回。
3. **ai-guide**:调 Claude API，model `claude-sonnet-5`，vision。
   system prompt 要点:你在指导不熟悉电脑的中国老人;一次只给一步;
   `instruction_text` 必须是口语化中文短句;若提供 ax_summary 优先用其坐标;
   输出严格 JSON `{instruction_text, target_rect|null, confidence}`
   （target_rect 归一化 0–1，基于传入截图）。落 session_events 后透传。
4. **ai-referee**:调 Claude API，model `claude-haiku-4-5-20251001`，纯文本。
   分类志愿者话语:(a)索要密码/验证码/PIN → freeze;(b)诱导转账/汇款/礼品卡
   → freeze;(c)诱导装软件/访问陌生网址 → warn;(d)高压催促 → warn;
   否则 ok。返回 `{verdict, reason}`。verdict≠ok 时插 alerts、
   freeze 时更新 sessions.status。目标端到端 < 2s。
5. **log-event**:插 session_events，返回 `{ok:true}`。

用 `supabase functions deploy` 部署;每个 function 写一条可复制的 curl
测试命令到 `supabase/README.md`（演示前预热也用它们）。

## B3. 志愿者 Web 端（`web/`）

React + Vite + TypeScript + `livekit-client`。单页，无路由，桌面浏览器即可。

- **加入页**:6 位码输入 + 昵称 → POST join-session → 错误码给人话提示。
- **会话页**:
  - 订阅 elder 的视频轨渲染 `<video>`（保持宽高比，letterbox）+ 音频轨播放;
    发布自己的麦克风。
  - video 上覆盖同尺寸 `<canvas>`:点击 → `annotate.circle`;拖拽 →
    `annotate.arrow`;按住移动 → `pointer`（30ms 节流，LOSSY）;
    工具栏:圈/箭头/激光笔/清除。**坐标归一化到 0–1 相对视频帧**
    （注意 letterbox 偏移量要扣掉）。本地 canvas 同步回显自己的标注（含 ttl 淡出）。
  - 消息经 `room.localParticipant.publishData()`，格式严格按 CONTRACT §3。
  - 每条标注 fire-and-forget POST `log-event`。
  - 收到 `control.freeze` → 全屏遮罩"会话已被 AI 安全助手暂停";
    `control.resume` → 解除。
  - 固定文案（醒目位置）:"你只能看和指，操作永远由长辈本人完成"。
    界面上不得出现任何形似远程控制的元素。
- **alerts 展示页**（demo 用，可简陋）:`/alerts.html` 或页内面板，
  经一个只读 Edge Function（或直接复用 log-event 同款鉴权思路）列出本会话
  alerts——演示第 6 幕"全程可追溯"用它。做不完的话裁掉，用表截图代替。

## B4. fake-elder 测试页（`web/fake-elder.html`，重要）

纯 HTML+JS 一页:输入手签 token 或调 create-session → 以 identity=`elder`
连房间 → `getDisplayMedia` 推屏幕流 → 收到的 DataChannel 消息全部
`console.log` 并在页面列表显示。用途:
1. 你不依赖 A 的 Mac App 就能端到端调志愿者 UI 和坐标归一化;
2. 它是 DataChannel 协议的参考实现，A 对齐用。

## 联调里程碑

见 CONTRACT §5。Day 1 中午前 B0–B2 的 create/join 必须可用（A 在等 token 链路）;
ai-guide/ai-referee 可以到 Day 1 晚。

## 明确不做

移动端适配、志愿者注册/实名、多志愿者匹配池、历史会话列表、i18n。
