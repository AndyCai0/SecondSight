# SecondSight（第二双眼睛）— 设计文档 v1

> 交给编码 agent 实现用。产品:帮助老人完成数字操作（MyGov、网银、Service NSW 等）的
> "只看不控"远程协助工具。老人端 Mac 原生 App，志愿者端网页。
> 黑客松 48 小时 demo 级实现，非生产级。

---

## 0. 核心原则（所有实现决策的判断依据）

1. **只看不控**:志愿者永远拿不到键盘鼠标控制权。协议里根本不存在控制消息。
2. **默认不信任（fail-safe）**:敏感区域先遮蔽后推流；检测暂时不可用就停止发布新帧并
   保留上一张已完成局部打码的安全帧，永远不用整屏黑块替代内容，也绝不"先露再补"。
3. **实时安全裁判在场**:双方语音持续转写；志愿者 partial 先由本地规则即时审查，
   final 回合再由 DeepSeek 结合老人目标、双方近段对话和必要时的打码截图复核。
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
│  - 双路流式转写+本地规则│
│  - AI 引导模式       │        ┌────────────────────────────────┐
└─────────┬───────────┘        │  Supabase                       │
          │                    │  - Postgres: sessions/events/   │
          └──── HTTPS ────────▶│    alerts (+RLS)                │
                               │  - Edge Functions:              │
                               │    create-session / join-session│
                               │    assemblyai-token / risk-event│
                               │  - (匿名 Auth)                  │
                               └───────────┬────────────────────┘
                                           │ DEEPSEEK_API_KEY 仅存在于此
                                           ▼
                                   DeepSeek API (vision + 文本分类)
```

**关键决策与理由:**

- **传输层用 LiveKit Cloud，不用裸 WebRTC P2P。** 原生端有官方 Swift SDK（支持自定义
  视频轨，直接喂 ScreenCaptureKit 帧）;不用自己处理信令/STUN/TURN/打洞;自带
  DataChannel 封装（`publishData`）;免费额度足够 demo。信令由 LiveKit 负责，
  Supabase Realtime 不参与媒体信令。
- **Supabase 职责收窄为**:会话记录、审计事件、告警落库、以及两个 AI 代理
  Edge Function（DeepSeek key 绝不出现在客户端）。LiveKit 的 room token 也由
  Edge Function 签发（LIVEKIT_API_SECRET 只在服务端）。
- **打码在老人端本地完成**，推到 SFU 的流已经是打码后的。服务器和志愿者都拿不到原始画面。
- **安全编排跑在老人端**（双方音频在老人设备接入 AssemblyAI → 带说话人标签的 final
  回合和可选打码截图送 Edge Function → DeepSeek 分类）。志愿者客户端无法伪造字幕或
  干预这条链路。

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

多路本机防护共同生成精确矩形；任何一路无法完成可信检查时都暂停新帧，不做整屏打码:

1. **AX 焦点事件 + 扫描兜底（~5 Hz）**:
   - 监听焦点应用、焦点窗口和焦点控件变化；老人点击任意可编辑控件后立即遮挡，
     不等待第一个字符进入视频帧。定时器用于处理浏览器漏发 AX 通知和自动填充变化。
   - 用 Accessibility API（`AXUIElementCreateSystemWide` → 焦点应用 → 遍历窗口控件树）
     找出所有 `AXSecureTextField` 及其屏幕坐标 `AXFrame`。
   - 所有 `AXTextField`、`AXTextArea`、`AXComboBox`、搜索框及浏览器报告为
     editable 的控件，在获得焦点时遮挡；只要值非空，失焦后继续遮挡，清空后解除。
     扫描只判断值是否为空，不保存、记录或发出实际内容。
   - 同时保留普通输入框 label/placeholder 敏感词规则，并遮挡焦点输入框附近的小型
     menu/list/popover/window，覆盖密码管理器和浏览器自动填充候选；若系统候选窗口
     属于独立进程、暂时无法从 AX 定位，则先保护输入框下方的常见候选区域。
   - 产出 `[CGRect]`（屏幕坐标系），存入线程安全的 `currentRedactionRects`。
   - 发给 AI 的 AX 摘要会删除所有遮挡区域内的 title，并标记
     `privacy_protected=true`；若同一帧还用了 Vision 补漏矩形，则整份 AX 摘要省略，
     避免图像已经遮住、文字摘要却旁路泄露。
   - 坐标记得处理 AX（左上原点）与 CoreGraphics/采集帧的坐标系换算及 Retina scale。
2. **静态内容与隐私上下文**:逐个扫描老人屏幕上所有可见窗口，而不是只看当前焦点。
   邮件、消息、日历、通讯录、银行、身份、医疗等上下文中的静态文字、链接、图片和
   列表行按 AX 叶节点局部遮挡；严禁拿 `AXWebArea`、`AXScrollArea` 或带子节点的
   `AXGroup` 当作一个大遮罩。通知中心、控制中心等系统浮层直接从采集源排除。
3. **本机视觉补漏**:对 Canvas、PDF、图片和自绘控件用 Vision 做 OCR、人脸和条码检测。
   OCR 只在本机匹配邮箱、长账号、电话、金额、证件/医疗等敏感模式，只输出矩形；
   原始 OCR 文字不写日志、不进 AX 摘要，也不上传。
4. **安全输入与失败边界**:轮询 `IsSecureEventInputEnabled()`。若安全输入开启却没有
   可定位矩形，或 AX 权限、窗口扫描、Vision 检查暂不可用，就丢弃当前新帧；LiveKit
   维持上一张已打码帧。窗口恢复可检查后自动继续。
5. **帧处理**:每帧把当前矩形区域用 CoreImage `CIPixellate`（或纯色块，
   更快更稳）覆盖后再发布。矩形向外扩 8px margin，防止 AX 坐标毫秒级滞后。

验收标准:在 Safari 打开任意登录页点进密码框，志愿者端看到的对应区域必须是马赛克/
色块，且从字段获得焦点到遮蔽出现 ≤ 300ms；普通标题、说明和按钮仍应清楚可见。

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

- 老人明确开启后，分别把老人本地麦克风和志愿者远端音频转为 16 kHz PCM16，各用一个
  后端短期 token 连接 AssemblyAI Streaming；客户端永远不持有永久 API Key。
- 两路 partial/final 字幕带 `elder` / `volunteer` 标签发到志愿者 Web。partial 立即更新
  屏幕字幕；只有 `end_of_turn=true` 的 final 才加入约 30 秒、最多 24 回合的 DeepSeek 输入。
- 志愿者 partial 同时进入本地中英规则引擎，明显高危话术无需等待网络。DeepSeek 请求
  严格串行；分析期间的新 final 合并到下一次快照，通过 `through_sequence` 防止旧结果回写。
- 老人在求助前可写本次目标。DeepSeek 将目标、双方对话和可选屏幕证据一起判断风险或
  明显偏离需求。AI 只弹出提醒，不自动冻结；暂停通话仍由老人决定。
- 用 48×27 的打码帧采样检测明显视觉变化。小范围光标/输入光标变化不触发 JPEG；只有
  首次分析或足够大的局部/整体变化才生成并上传新截图。连续 LiveKit 屏幕共享不受影响。

### 2.7 AI 引导模式（AIGuide）

- 老人也可以不等志愿者，点"AI 帮我"（或志愿者不在线时自动提供）。
- 老人语音说需求（SFSpeechRecognizer 转写）→ 截当前屏（复用采集帧，**过打码管线后**的帧）
  → POST `ai-guide`:`{session_id, task, screenshot_base64, ax_summary}`。
  `ax_summary` = 当前焦点窗口 AX 树的精简 JSON（控件 role/title/frame，深度≤4，
  截断到 8KB）——给 DeepSeek 精确坐标依据，不靠视觉猜。
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

- **加入流程**:输入 6 位码（+ 输入自己昵称）→ 志愿者主动点击后取得摄像头和麦克风
  → POST `join-session` → 得 `{lk_token, lk_url}` → 连 room 并发布已取得的两条轨道
  → 分别订阅老人脱敏屏幕、摄像头和音频；页面显示本地摄像头预览。权限、接口或连接
  失败以及退出会话时都停止本地轨道。
- **标注工具栏**:圆圈（默认）/ 箭头 / 激光笔 / 清除。在 video 上盖一层
  `<canvas>` 捕获点击与拖拽:
  - 点击 → `annotate.circle`，圆心为点击点;
  - 拖拽 → `annotate.arrow`，从起点到终点;
  - 按住移动 → `pointer` 节流 30ms 连发。
  - 坐标一律**归一化到 0–1**（相对视频帧宽高）再发送，老人端乘回屏幕尺寸。
- 通过 `room.localParticipant.publishData()`（RELIABLE 模式，pointer 用 LOSSY）发送。
- **界面上不存在任何形似"控制"的元素**，工具栏旁固定文案:"你只能看和指，
  操作永远由长辈本人完成"。
- 志愿者发布摄像头和麦克风轨（麦克风是被裁判监听的对象），但不能发布屏幕共享。
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
`DEEPSEEK_API_KEY` 仅在启用 `ai-guide` / `ai-referee` 时配置；未配置时这两个
端点返回 503，但不影响创建房间、加入房间和 LiveKit 实时音视频。

1. **`create-session`** (POST, 无 body)
   → 生成不冲突 6 位码，插 sessions，签发 LiveKit token
   （identity=`elder`，room=code，canPublish=true, canSubscribe=true）
   → `{session_id, code, lk_url, lk_token}`
2. **`join-session`** (POST `{code, name}`)
   → 查 sessions 校验 status=waiting|active，更新 volunteer_label、status=active，
   签 token（identity=`volunteer:{name}`，**canPublishSources 仅 microphone + camera**——
   支持双向视频，同时在 token 层面继续禁止志愿者发布屏幕）
   → `{session_id, lk_url, lk_token}`
3. **`ai-guide`** (POST `{session_id, task, screenshot_base64, ax_summary}`)
   → 调 DeepSeek（`deepseek-v4-flash-vision-exp`，vision）。System prompt 要点:你在指导不熟悉
   电脑的老人;返回 JSON `{instruction_text(口语化中文一步一句), target_rect
   {x,y,w,h} 归一化坐标(基于截图), confidence}`;只给一步，不给一串。
   ax_summary 存在时优先用 AX 坐标。→ 落 session_events → 透传响应。
4. **`ai-referee`** (POST `{session_id, elder_goal, through_sequence, dialogue,
   screenshot_base64?, screen_revision?}`)
   → 无截图时调 `deepseek-v4-flash`；画面明显变化时调
   `deepseek-v4-flash-vision-exp`。分类双方对话是否存在安全风险、志愿者指导是否明显
   偏离老人目标，以及话语是否与当前打码屏幕不符。返回
   `{level, category, reason, through_sequence}`；warning/danger 写 alerts，但不自动冻结会话。
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
- **任何客户端不得包含** LiveKit secret 或 DeepSeek key。

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
- AX + Vision 精确打码管线 + 检查失败时暂停新帧
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
| AX 树在部分 App（Electron/网页内控件）拿不到密码框 | 本机 Vision 补漏；检查仍不可信时暂停新帧并保留上一张已打码帧 |
| SFSpeechRecognizer on-device 中文效果不稳 | demo 台词固定;备关键词直匹配兜底（§2.6） |
| LiveKit Swift 自定义视频轨 API 与文档有出入 | 这是 Day1 上午最大不确定点，最先做;失败退路=WKWebView 内嵌网页版采集（体验降级但通路在） |
| ScreenCaptureKit 排除自窗口失效导致标注被回传 | 验收时检查志愿者视角无圈;不行就接受回传（不致命） |
| Edge Function 冷启动延迟 | 演示前 curl 预热 |
| 现场网络 | 手机热点 + 录好的备份视频 |
