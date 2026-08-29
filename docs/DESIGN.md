# SecondSight（第二双眼睛）— 设计文档 v1

> 交给编码 agent 实现用。产品:帮助老人完成数字操作（MyGov、网银、Service NSW 等）的
> "只看不控"远程协助工具。老人端 Mac 原生 App，志愿者端网页。
> 黑客松 48 小时 demo 级实现，非生产级。

---

## 0. 核心原则（所有实现决策的判断依据）

1. **只看不控**:志愿者永远拿不到键盘鼠标控制权。协议里根本不存在控制消息。
2. **默认不信任（fail-safe）**:敏感区域先遮蔽后推流;检测不到就整屏暂停，绝不"先露再补"。
3. **实时安全裁判在场**:志愿者语音持续转写并由本地规则即时审查；危险话术立即警告，
   LLM 只保留给未来可疑/未知上下文的按需复核。
4. **全程可追溯**:每条 AI 指令、每个标注、每次告警落库。
5. 老人端体验:一个大按钮，零注册，零学习成本。

## 1. 总体架构

```
┌─────────────────────┐      LiveKit Cloud (SFU)      ┌──────────────────────┐
│  老人端 Mac App      │  ──打码后的屏幕视频轨──────▶  │  志愿者端 Web (React) │
│  (Swift/SwiftUI)    │  ──麦克风音频轨──────────▶    │  (LiveKit JS SDK)    │
│                     │  ◀──志愿者音频轨──────────    │                      │
│  - ScreenCaptureKit │  ◀──DataChannel: 标注消息──   │  - 视频画布 + 标注层   │
│  - AX 打码管线       │                               │  - 画圈/箭头工具       │
│  - 全局悬浮标注层     │                               └──────────────────────┘
│  - 流式转写+本地规则  │
│  - AI 引导模式       │        ┌────────────────────────────────┐
└─────────┬───────────┘        │  Supabase                       │
          │                    │  - Postgres: sessions/events/   │
          └──── HTTPS ────────▶│    alerts (+RLS)                │
                               │  - Edge Functions:              │
                               │    create-session / join-session│
                               │    assemblyai-token / risk-event│
                               │  - (匿名 Auth)                  │
                               └───────────┬────────────────────┘
                                           │ ANTHROPIC_API_KEY 仅存在于此
                                           ▼
                                     Claude API (vision + 文本分类)
```

**关键决策与理由:**

- **传输层用 LiveKit Cloud，不用裸 WebRTC P2P。** 原生端有官方 Swift SDK（支持自定义
  视频轨，直接喂 ScreenCaptureKit 帧）;不用自己处理信令/STUN/TURN/打洞;自带
  DataChannel 封装（`publishData`）;免费额度足够 demo。信令由 LiveKit 负责，
  Supabase Realtime 不参与媒体信令。
- **Supabase 职责收窄为**:会话记录、审计事件、告警落库、以及两个 AI 代理
  Edge Function（Claude key 绝不出现在客户端）。LiveKit 的 room token 也由
  Edge Function 签发（LIVEKIT_API_SECRET 只在服务端）。
- **打码在老人端本地完成**，推到 SFU 的流已经是打码后的。服务器和志愿者都拿不到原始画面。
- **AI 裁判跑在老人端**（志愿者音频到达老人设备后本地转写 → 文本送 Edge Function 分类）。
  志愿者客户端无法干预这条链路。

## 2. 老人端 Mac App（工作量大头）

技术栈:Swift 5.10+ / SwiftUI，菜单栏 App（`MenuBarExtra` 或 NSStatusItem），
macOS 14+。依赖:LiveKit Swift SDK（SPM: `https://github.com/livekit/client-sdk-swift`）。

### 2.1 模块划分

```
SecondSightMac/
├── App/                 # 入口、菜单栏、权限引导
├── Capture/             # ScreenCaptureKit 采集
├── Redaction/           # AX 扫描 + 帧遮蔽管线
├── Transport/           # LiveKit 连接、轨道发布、Data 消息
├── Overlay/             # 全局透明标注窗口
├── Referee/             # 本地语音转写 + 告警处理
├── AIGuide/             # 截图 → ai-guide → 播报/标注
└── Session/             # 会话状态机、与 Supabase 的 HTTP 交互
```

### 2.2 会话状态机

```
idle → requesting(创建会话,拿6位码) → waiting(展示大字号房间码)
     → connected(志愿者已加入) → frozen(裁判告警,可由老人手动解除)
     → ended
```

- 老人点菜单栏"求助"→ 调 `create-session` Edge Function → 得 `{code, lk_token, lk_url,
  session_id}` → 连 LiveKit room → 在原窗口展示 6 位码（同时用 AVSpeechSynthesizer 读出来）。
- 志愿者加入后自动开始推屏幕轨 + 麦克风轨。

### 2.3 采集（Capture）

- `SCShareableContent` 取主显示器，`SCStream` 采集，1080p 或原生分辨率降采样，
  **10–15 fps 足够**（屏幕内容大部分静止，帧率留给打码管线余量）。
- 用 `SCContentFilter(display:excludingWindows:)` **把本 App 自己的窗口
  （房间码窗、告警窗、标注悬浮层）排除出采集**，志愿者看到的是干净的老人屏幕。
- 输出 `CMSampleBuffer` → 交 Redaction 管线 → 转 `CVPixelBuffer` 喂给 LiveKit
  自定义视频轨（LiveKit Swift SDK 的 custom video capturer / `BufferCapturer`）。

### 2.4 打码管线（Redaction）— 本项目技术核心之一

两层防护，都是确定性逻辑，**不做任何视觉识别**:

1. **AX 扫描（~5 Hz 独立定时器，不逐帧）**:
   - 用 Accessibility API（`AXUIElementCreateSystemWide` → 焦点应用 → 遍历窗口控件树）
     找出所有 `AXSecureTextField` 及其屏幕坐标 `AXFrame`。
   - 同时收集普通 `AXTextField` 中 label/placeholder 命中敏感词
     （password/PIN/验证码/card number/CVV 等）的。
   - 产出 `[CGRect]`（屏幕坐标系），存入线程安全的 `currentRedactionRects`。
   - 坐标记得处理 AX（左上原点）与 CoreGraphics/采集帧的坐标系换算及 Retina scale。
2. **安全输入模式全局兜底**:轮询 `IsSecureEventInputEnabled()`。
   为 true（说明系统里有密码框正在接受输入）且 AX 没定位到具体矩形时，
   **整帧替换为占位图**（"正在输入敏感信息，画面已暂停"），宁可黑屏不可泄露。
3. **帧处理**:每帧把 `currom` 的矩形区域用 CoreImage `CIPixellate`（或纯色块，
   更快更稳）覆盖后再发布。矩形向外扩 8px margin，防止 AX 坐标毫秒级滞后。

验收标准:在 Safari 打开任意登录页点进密码框，志愿者端看到的对应区域必须是马赛克/
色块，且从字段获得焦点到遮蔽出现 ≤ 300ms（靠"安全输入模式整屏兜底"保证零泄露窗口）。

### 2.5 全局标注悬浮层（Overlay）

- 一个覆盖全屏的透明 `NSWindow`:`isOpaque=false`、`backgroundColor=.clear`、
  `level = .screenSaver`、`ignoresMouseEvents = true`（点击穿透）、
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`。
- 内容为 SwiftUI Canvas / CAShapeLayer，渲染来自 DataChannel 的标注（见 §5 协议）:
  圆圈（描边动画 + 呼吸效果，醒目）、箭头、激光笔轨迹。每个标注带 `ttl_ms` 自动淡出。
- 收到 `control.freeze` 时:悬浮层切换为**全屏半透明红色警告**（大字:
  "检测到可疑请求，通话已暂停。请勿告诉任何人您的密码或验证码"+ AVSpeech 播报），
  同时停止发布音视频轨。老人点"我知道了，是误报"可恢复（demo 允许）。

### 2.6 实时安全监听

- 老人明确开启后，订阅志愿者远端音频轨并转为 16 kHz PCM16，通过后端短期 token
  连接 AssemblyAI Streaming；客户端永远不持有永久 API Key。
- partial/final transcript 立即进入本地中英规则引擎。危险话术显示高对比警告，写入
  `risk-event`，并通过 `safety.risk` 通知志愿者端。
- 同一 streaming turn 使用 cooldown 去重，最近上下文限制在约 25 秒；第一版不逐句
  调用 LLM。旧 `ai-referee` 仅保留给兼容/手工测试。

### 2.7 AI 引导模式（AIGuide）

- 老人也可以不等志愿者，点"AI 帮我"（或志愿者不在线时自动提供）。
- 老人语音说需求（SFSpeechRecognizer 转写）→ 截当前屏（复用采集帧，**过打码管线后**的帧）
  → POST `ai-guide`:`{session_id, task, screenshot_base64, ax_summary}`。
  `ax_summary` = 当前焦点窗口 AX 树的精简 JSON（控件 role/title/frame，深度≤4，
  截断到 8KB）——给 Claude 精确坐标依据，不靠视觉猜。
- 响应 `{instruction_text, target_rect?, arrow_from?}` → 悬浮层画圈 + TTS 播报
  instruction_text → 落库 events。
- 单轮即可，不用做成多轮 agent（demo 裁剪线之内）。

### 2.8 权限引导（首启动向导）

依次引导授权并显示实时状态（授权后需重启 App 的项要提示）:
1. 屏幕录制（Screen Recording）— ScreenCaptureKit 需要
2. 辅助功能（Accessibility）— AX 扫描需要
3. 麦克风 — 通话需要；语音识别只在启用可选 AI 引导时需要

demo 前一天在演示机上全部授好。开发签名用 ad-hoc 即可，不做公证。

## 3. 志愿者端 Web

技术栈:React + Vite + TypeScript + `livekit-client`。单页面，无路由。

- **加入流程**:输入 6 位码（+ 输入自己昵称）→ POST `join-session` → 得
  `{lk_token, lk_url}` → 连 room → 订阅视频轨渲染到 `<video>`。
- **标注工具栏**:圆圈（默认）/ 箭头 / 激光笔 / 清除。在 video 上盖一层
  `<canvas>` 捕获点击与拖拽:
  - 点击 → `annotate.circle`，圆心为点击点;
  - 拖拽 → `annotate.arrow`，从起点到终点;
  - 按住移动 → `pointer` 节流 30ms 连发。
  - 坐标一律**归一化到 0–1**（相对视频帧宽高）再发送，老人端乘回屏幕尺寸。
- 通过 `room.localParticipant.publishData()`（RELIABLE 模式，pointer 用 LOSSY）发送。
- **界面上不存在任何形似"控制"的元素**，工具栏旁固定文案:"你只能看和指，
  操作永远由长辈本人完成"。
- 志愿者也发布麦克风轨（这是被裁判监听的对象）。
- 收到 `control.freeze` 的镜像通知时显示"会话已被 AI 安全助手暂停"。

## 4. Supabase 设计

### 4.1 表结构（迁移 SQL）

```sql
create table sessions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,              -- 6位数字房间码
  status text not null default 'waiting', -- waiting|active|frozen|ended
  elder_label text default '长辈',
  volunteer_label text,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);

create table session_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references sessions(id),
  ts timestamptz not null default now(),
  actor text not null,     -- elder|volunteer|ai_guide|ai_referee|system
  kind text not null,      -- annotate.circle|annotate.arrow|ai.instruction|freeze|...
  payload jsonb not null default '{}'
);

create table alerts (
  id bigint generated always as identity primary key,
  session_id uuid not null references sessions(id),
  ts timestamptz not null default now(),
  severity text not null,  -- warn|freeze
  transcript text not null,
  reason text not null
);
```

RLS:demo 级从简——四表开启 RLS，客户端一律不直连表写入，**所有写入走
Edge Function（service_role）**;客户端只读需求也走 function。这样 RLS 策略
可以是"全拒绝"，最省事且不出安全洞。

### 4.2 Edge Functions（Deno/TypeScript）

实时房间需要 `LIVEKIT_API_KEY` `LIVEKIT_API_SECRET` `LIVEKIT_URL`。
`ANTHROPIC_API_KEY` 仅在启用 `ai-guide` / `ai-referee` 时配置；未配置时这两个
端点返回 503，但不影响创建房间、加入房间和 LiveKit 实时音视频。

1. **`create-session`** (POST, 无 body)
   → 生成不冲突 6 位码，插 sessions，签发 LiveKit token
   （identity=`elder`，room=code，canPublish=true, canSubscribe=true）
   → `{session_id, code, lk_url, lk_token}`
2. **`join-session`** (POST `{code, name}`)
   → 查 sessions 校验 status=waiting|active，更新 volunteer_label、status=active，
   签 token（identity=`volunteer:{name}`，**canPublishSources 仅 microphone**——
   在 token 层面就禁止志愿者发布屏幕/摄像头，纵深防御）
   → `{session_id, lk_url, lk_token}`
3. **`ai-guide`** (POST `{session_id, task, screenshot_base64, ax_summary}`)
   → 调 Claude（`claude-sonnet-5`，vision）。System prompt 要点:你在指导不熟悉
   电脑的老人;返回 JSON `{instruction_text(口语化中文一步一句), target_rect
   {x,y,w,h} 归一化坐标(基于截图), confidence}`;只给一步，不给一串。
   ax_summary 存在时优先用 AX 坐标。→ 落 session_events → 透传响应。
4. **`ai-referee`** (POST `{session_id, transcript}`)
   → 调 Claude（`claude-haiku-4-5`，纯文本，要快）。分类:志愿者话语中是否存在
   (a)索要密码/验证码/PIN (b)诱导转账汇款/购买礼品卡 (c)诱导安装软件或
   访问陌生网址 (d)制造紧迫感施压。返回 `{verdict: ok|warn|freeze, reason}`。
   命中 a/b → freeze;c/d → warn。→ verdict≠ok 时插 alerts、更新 session
   status → 透传响应。
5. **`log-event`** (POST `{session_id, actor, kind, payload}`) — 通用审计落库。
   客户端标注、冻结、恢复等都打到这里（fire-and-forget，失败不阻塞 UI）。
6. **`assemblyai-token` / `risk-event`** — 分别签发短期流式转写凭证、记录经本地规则
   去重后的 warning/danger 事件；两者都校验 elder LiveKit JWT 与 room 绑定。

## 5. DataChannel 消息协议

JSON，UTF-8，经 LiveKit `publishData`。所有坐标归一化 0–1（相对共享视频帧）。

```jsonc
{"v":1,"type":"annotate.circle","id":"a1","x":0.42,"y":0.31,"r":0.05,"ttl_ms":6000}
{"v":1,"type":"annotate.arrow","id":"a2","x1":0.2,"y1":0.5,"x2":0.45,"y2":0.33,"ttl_ms":6000}
{"v":1,"type":"pointer","x":0.5,"y":0.5}                  // LOSSY, 30ms 节流
{"v":1,"type":"annotate.clear"}
{"v":1,"type":"control.freeze","reason":"..."}             // 仅老人端有权发出
{"v":1,"type":"control.resume"}
{"v":1,"type":"chat.tts","text":"..."}                     // 志愿者发文字请老人端播报(可选)
```

老人端**忽略**任何来自 volunteer identity 的 `control.*` 消息（只认本机裁判产生的），
校验发送者 identity 前缀。协议中不存在鼠标/键盘事件类型——"只看不控"在协议层成立。

## 6. 环境与配置

- LiveKit Cloud 免费项目:得 `LIVEKIT_URL`（wss://xxx.livekit.cloud）、API key/secret。
- Supabase 项目:URL + anon key（客户端只用来调 Edge Functions）。
- Mac App 配置:`Config.plist` 或编译常量——`SUPABASE_URL`、`SUPABASE_ANON_KEY`。
- Web 端 `.env`:`VITE_SUPABASE_URL`、`VITE_SUPABASE_ANON_KEY`。
- **任何客户端不得包含** LiveKit secret 或 Anthropic key。

## 7. 48 小时任务切分（含裁剪线）

**Day 1 上午 — 通路** ✂️不可裁
- Supabase 项目 + 4 张表 + `create-session`/`join-session`
- Mac App 骨架:菜单栏 + 权限向导 + ScreenCaptureKit 采集 → LiveKit 推流
- Web 端:输码加入 + 看到屏幕 + 语音双向通话
- 里程碑:两台机器互通，志愿者看到老人屏幕并能对话

**Day 1 下午 — 标注与引导** ✂️不可裁
- 志愿者画圈/箭头 → DataChannel → 老人端全局悬浮层渲染
- `ai-guide` + AI 引导模式（截图→指令→画圈→TTS）
- 里程碑:志愿者在 MyGov 页面上圈出按钮，老人屏幕上直接看到圈

**Day 2 上午 — 安全核心** ✂️不可裁（这是 pitch 的命）
- AX 打码管线 + 安全输入模式整屏兜底
- 实时安全监听:远端音频 → AssemblyAI partial → 本地规则 → 警告/冻结流程
- 里程碑:密码框实时打码;"坏志愿者"说出索要验证码触发全屏警告

**Day 2 下午 — 打磨与演示** 可部分裁剪
- 审计事件全量落库 + 简单会话回放页（可裁→只展示 alerts 表截图）
- 激光笔、标注动画、老人端大字号 UI 打磨（可裁）
- 录备份演示视频（✂️不可裁）、彩排两遍

**明确不做（写给 Codex，防止跑偏）**:Windows/iOS 端、志愿者实名审核、
App 公证与分发、多志愿者同时接入同一通话、通话录像回放、多显示器。

## 8. 演示脚本（3 分钟）

两台笔记本 + 手机热点（同一热点，绕开场馆网络）。
1. 【20s】问题:老人被 MyGov 卡住 → 现状要么等子女、要么被 TeamViewer 骗。
2. 【40s】老人点一个大按钮 → 念出 6 位码 → 志愿者网页输码接入 →
   在老人真实屏幕上画圈引导点击（镜头给老人屏幕上的悬浮圈）。
3. 【30s】老人点进密码框 → **切志愿者视角:密码区域是马赛克** →
   台词:"打码发生在老人电脑本地，原始画面从未离开这台机器"。
4. 【40s】坏志愿者环节:"把手机上的验证码念给我" → 老人屏幕瞬间全屏红色警告、
   通话冻结 → 台词:"我们连志愿者也不信任，每场求助都有实时安全裁判在场"。
5. 【30s】AI 引导模式:没有志愿者时 AI 直接圈出下一步 + 语音播报。
6. 【20s】审计记录一屏带过 + 叙事收尾:数字素养 × 反诈，一套"默认不信任"架构。

## 9. 已知风险与对策

| 风险 | 对策 |
|---|---|
| AX 树在部分 App（Electron/网页内控件）拿不到密码框 | 安全输入模式整屏兜底保证零泄露;demo 选 Safari 原生表单 |
| SFSpeechRecognizer on-device 中文效果不稳 | demo 台词固定;备关键词直匹配兜底（§2.6） |
| LiveKit Swift 自定义视频轨 API 与文档有出入 | 这是 Day1 上午最大不确定点，最先做;失败退路=WKWebView 内嵌网页版采集（体验降级但通路在） |
| ScreenCaptureKit 排除自窗口失效导致标注被回传 | 验收时检查志愿者视角无圈;不行就接受回传（不致命） |
| Edge Function 冷启动延迟 | 演示前 curl 预热 |
| 现场网络 | 手机热点 + 录好的备份视频 |
