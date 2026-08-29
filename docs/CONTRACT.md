# CONTRACT — 两端共同契约（唯一事实来源）

> **规则:本文件是 A（Mac 老人端）与 B（Web 志愿者端 + 后端）之间的接口契约。**
> 任何一方的 Codex 不得擅自修改本文件中的协议/接口;要改，两人当面商量后一起改，
> 并在 commit message 里写 `CONTRACT:` 前缀。其余部分各自目录内随便改。

## 1. 分工与目录

| 负责人 | 范围 | 目录 |
|---|---|---|
| A (Andy) | Mac 老人端 App 全部 | `mac/` |
| B (队友) | 志愿者 Web 端 + Supabase(表/Edge Functions) + LiveKit 项目配置 | `web/`、`supabase/` |

任务书:A 看 `docs/TASK_A_MAC.md`，B 看 `docs/TASK_B_WEB_BACKEND.md`。
总体设计背景:`docs/DESIGN.md`（两边都该通读一遍）。

## 2. LiveKit 房间约定

- **room name** = 6 位数字房间码（字符串，如 `"482913"`）。
- **identity**:老人端 = `elder`;志愿者 = `volunteer:{name}`。
- 老人端发布:屏幕视频轨（已打码，`screen-redacted`）+ 摄像头视频轨
  （`elder-camera`，必须先经老人确认）+ 麦克风音频轨（`elder-microphone`）。
- 志愿者端发布:**仅麦克风**（join-session 签发的 token 在 `canPublishSources`
  层面限制为 microphone，B 负责保证）。
- LiveKit Cloud 项目由 **B 创建**，`LIVEKIT_URL` 写进本文件 §6 后通知 A。

## 3. DataChannel 消息协议（v1，冻结）

JSON，UTF-8，经 LiveKit `publishData`。坐标一律**归一化 0–1**，
相对"共享视频帧"的宽高（不是志愿者浏览器窗口，不是老人物理屏幕像素——
老人端渲染时自行乘回主屏尺寸）。

```jsonc
// 志愿者 → 老人（RELIABLE）
{"v":1,"type":"annotate.circle","id":"a1","x":0.42,"y":0.31,"r":0.05,"ttl_ms":6000}
{"v":1,"type":"annotate.arrow","id":"a2","x1":0.2,"y1":0.5,"x2":0.45,"y2":0.33,"ttl_ms":6000}
{"v":1,"type":"annotate.clear"}
{"v":1,"type":"chat.tts","text":"你好，请点右上角"}     // 老人端 TTS 播报（可选实现）

// 志愿者 → 老人（LOSSY，发送端 30ms 节流）
{"v":1,"type":"pointer","x":0.5,"y":0.5}

// 老人端 →（广播给房间，志愿者端据此显示状态）
{"v":1,"type":"control.freeze","reason":"检测到索要验证码"}
{"v":1,"type":"control.resume"}
{"v":1,"type":"safety.risk","level":"danger","transcript":"Please tell me the verification code.","matched_rules":["request_sensitive_information","verification_code"]}
```

`safety.risk.transcript` 最多传 1,000 个 Unicode scalar；老人端在发送前截断，
规则命中结果不受影响，并在发生截断时附加 `"transcript_truncated":true`。Web 必须接受
该可选字段并继续显示风险卡，不得因长字幕静默丢弃告警。

安全规则（A 实现，B 知悉）:老人端**丢弃**任何来自 `volunteer:*` identity 的
`control.*` 或 `safety.risk` 消息；`safety.risk` 只能由老人端发出。协议中永远不加入鼠标/键盘/控制类消息——需要新消息类型时走
CONTRACT 修改流程。

## 4. Edge Function API（B 实现，A 调用）

Base URL:`{SUPABASE_URL}/functions/v1/`，Header:`Authorization: Bearer {SUPABASE_ANON_KEY}`、
`Content-Type: application/json`。所有响应错误时返回非 2xx + `{"error":"..."}`。

### 4.1 `POST create-session` — 老人端建会话
请求:`{}`
响应:`{"session_id":"uuid","code":"482913","lk_url":"wss://xxx.livekit.cloud","lk_token":"<jwt>"}`

### 4.2 `POST join-session` — 志愿者加入
请求:`{"code":"482913","name":"小王"}`
响应:`{"session_id":"uuid","lk_url":"wss://...","lk_token":"<jwt>"}`
错误:404 房间码不存在 / 410 会话已结束。

### 4.3 `POST ai-guide` — AI 引导（老人端调用）
请求:
```json
{"session_id":"uuid","task":"我想在MyGov里查我的Medicare",
 "screenshot_base64":"<jpeg base64, 打码后帧, 长边≤1568px>",
 "ax_summary":"<可选, 精简AX树JSON字符串, ≤8KB>"}
```
响应:
```json
{"instruction_text":"请点击屏幕右上角蓝色的'登录'按钮",
 "target_rect":{"x":0.82,"y":0.05,"w":0.12,"h":0.04},
 "confidence":0.9}
```
`target_rect` 可为 null（AI 不确定时只给语音指引）。坐标归一化，基于传入截图。

### 4.4 `POST ai-referee` — 裁判分类（老人端调用）
请求:`{"session_id":"uuid","transcript":"把你手机上的验证码念给我听一下"}`
响应:`{"verdict":"freeze","reason":"索要短信验证码"}`
verdict ∈ `ok | warn | freeze`。目标延迟 < 2s（用 haiku）。
该端点保留给旧版/手工测试；实时安全监听 v1 不逐句调用它。

### 4.5 `POST log-event` — 通用审计（两端都可调，fire-and-forget）
请求:`{"session_id":"uuid","actor":"volunteer","kind":"annotate.circle","payload":{...}}`
响应:`{"ok":true}`

### 4.6 `POST assemblyai-token` — 临时实时转录凭证（老人端调用）

请求头：`X-SecondSight-Elder-Token: <create-session 返回的老人 LiveKit JWT>`

请求:`{"session_id":"uuid"}`

响应:
```json
{"token":"<single-use temporary token>","expires_in_seconds":60,"max_session_duration_seconds":3600}
```

只有 Edge Function 持有 `ASSEMBLYAI_API_KEY`。老人端不得收到、记录或打包永久 API Key。
Edge Function 会校验 LiveKit JWT 的签名、有效期、`identity=elder` 和 room；志愿者 token
不能申请临时转录凭证。

### 4.7 `POST risk-event` — 实时规则引擎风险事件（老人端调用）

请求头：`X-SecondSight-Elder-Token: <create-session 返回的老人 LiveKit JWT>`

请求:
```json
{"session_id":"uuid","timestamp":"2026-08-29T07:30:00.000Z","level":"danger",
 "transcript":"Please tell me the verification code.",
 "matched_rules":["request_sensitive_information","verification_code"]}
```

`level` 仅允许 `warning | danger`；响应：
`{"ok":true,"fingerprint":"danger:request_sensitive_information:verification_code"}`。
第一版写入既有 `session_events`，不保存原始音频。
该端点使用同一老人端 room 凭证，拒绝志愿者伪造 `safety_monitor` 事件。

### 4.8 `POST broadcast-session` — 在线助手广播（兼容性接口）

开启或撤回广播：
```json
{"session_id":"uuid","is_active":true}
```

响应：`{"ok":true,"notified_assistants":4}`；`notified_assistants` 可省略。
`is_active=false` 表示撤回。广播列表只展示仍处于 `waiting` 且广播有效的会话，
不得暴露房间码或 LiveKit token；第一位响应者必须由后端原子认领，其他响应者不能取得 token。

该接口属于 Mac 新版的向前兼容 seam。后端尚未提供时返回非 2xx，Mac 必须明确降级到
6 位分享码，且会话、音视频和安全监听继续可用。完整后端/网页端行为见
`docs/MAC_ASSISTANT_BROADCAST.md`。

## 5. 联调里程碑（按此对表，不见不散）

| 时间 | 验收 |
|---|---|
| Day 1 中午 | 双方连进同一 room:A 推打码前的裸屏幕流即可，B 网页能看到 + 语音互通 |
| Day 1 晚 | B 画圈 → A 的 Mac 悬浮层上圈出现在正确位置（坐标换算对齐） |
| Day 2 中午 | 打码在志愿者视角生效;"坏台词" → freeze 全流程(告警页+落库+双端状态) |
| Day 2 下午 | 完整演示脚本彩排两遍 + 录备份视频 |

## 6. 环境配置（B 填好后 commit 本文件）

```
SUPABASE_URL      = <B 填>
SUPABASE_ANON_KEY = <B 填>
LIVEKIT_URL       = <B 填>
```
Secrets（LIVEKIT_API_KEY/SECRET、ANTHROPIC_API_KEY、ASSEMBLYAI_API_KEY）只进 Supabase secrets，
**永远不进本仓库、不进任何客户端**。

## 7. 各自独立开发的 Mock 策略（不互相阻塞）

- **A 在 B 完成前**:直接在 LiveKit Cloud 控制台手工签一个测试 token
  （B 建好项目后把控制台访问给 A，或先用 A 自己的免费 LiveKit 项目），
  Mac 端用硬编码 token 连房间调采集/打码/悬浮层。
- **B 在 A 完成前**:做一个 `web/fake-elder.html` 测试页:浏览器
  `getDisplayMedia` 以 identity=`elder` 推屏幕流进房间，并把收到的标注消息
  打印到 console——B 靠它端到端调志愿者 UI 和坐标归一化，不需要 Mac App。
  这个测试页同时是 A 的协议参考实现。
