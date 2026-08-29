# TASK A — 老人端 Mac App（负责人:Andy）

> 交给 Codex 的任务书。先读 `docs/CONTRACT.md`（接口契约，不得擅改），
> 背景细节在 `docs/DESIGN.md` §2。所有代码放 `mac/` 目录。
> demo 级实现:单显示器、中文优先、ad-hoc 签名、不做公证和分发。

## 技术栈

- Swift 5.10+ / SwiftUI，macOS 14+，菜单栏 App（`MenuBarExtra`）
- SPM 依赖:LiveKit Swift SDK `https://github.com/livekit/client-sdk-swift`
- 工程形式:SPM executable + 手工 .app bundle 均可，但必须带 Info.plist
  （含 `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`）

## 模块与要求

### A1. 会话状态机 + UI
`idle → requesting → waiting(展示房间码) → connected → frozen → ended`

- 菜单栏点"求助"→ 调 `create-session`（见 CONTRACT §4.1）→ 在原窗口大字显示
  6 位码，同时 `AVSpeechSynthesizer` 朗读，不另开房间码窗口。志愿者加入
  （LiveKit participant joined 事件）后该号码区域收起。
- 所有面向老人的 UI:字号 ≥ 24pt，按钮大，文案口语化中文。

### A2. 权限向导（首启动）
依次检测并引导:屏幕录制、辅助功能、麦克风、语音识别。每项显示实时状态，
未授权项给"打开系统设置"按钮。屏幕录制授权后提示需重启 App。

### A3. 屏幕采集
- ScreenCaptureKit:主显示器，10–15 fps，输出适配 LiveKit 自定义视频轨
  （`BufferCapturer` / custom video source，喂 `CVPixelBuffer`）。
- `SCContentFilter(display:excludingWindows:)` 排除本 App 全部窗口
  （主窗口、悬浮层、警告窗）。验收:志愿者视角看不到我们自己的 UI。
- **这是全项目最大不确定点，最先做**:先跑通"采集→推流→LiveKit dashboard
  能看到轨道"。失败退路:WKWebView 内嵌一个最小网页用浏览器 WebRTC 采集推流
  （体验降级但通路保住），退路触发条件 = Day 1 上午结束仍未推流成功。

### A4. 打码管线（核心卖点，不可裁）
三层，全部确定性逻辑，禁止引入 OCR/视觉模型:

1. **AX 焦点事件 + 5 Hz 扫描兜底**:AXUIElement 遍历焦点应用窗口控件树，
   收集 (a) 当前获得焦点的所有可编辑控件 (b) 已有非空值的可编辑控件
   (c) secure text field (d) title/placeholder 命中敏感词的普通文本框，以及
   焦点输入框附近的密码/自动填充候选窗口；跨进程候选无法定位时先保护输入框下方
   的常见候选区域；取 `AXFrame`，
   换算 AX 坐标系(左上原点/点) → 采集帧像素坐标（注意 Retina scale 和多分辨率），
   每个矩形外扩 8px，写入线程安全的 `currentRedactionRects`。只判断值是否为空，
   不保存、记录或发出用户输入内容。
2. **整屏兜底**:轮询 `IsSecureEventInputEnabled()`;为 true 且当前无对应
   遮蔽矩形时，整帧替换为占位图（灰底大字"正在输入敏感信息，画面已暂停"）。
   AX 权限不可用或扫描尚未就绪时也必须整屏占位，不允许原帧直接放行。
3. 每帧发布前用纯色块（黑）覆盖矩形（CoreImage 或直接改 pixel buffer，
   以性能稳定为准）。

验收:Safari 打开任意登录页，点入密码框 → 志愿者视角该区域为色块，
从获焦到遮蔽 ≤ 300ms（兜底机制保证期间零泄露，宁黑屏不露）。

### A5. 全局标注悬浮层
- 透明 NSWindow:`level=.screenSaver`、`ignoresMouseEvents=true`、
  `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]`、无阴影。
- 渲染 DataChannel 标注消息（CONTRACT §3）:圆圈（描边+呼吸动画）、箭头、
  激光笔轨迹点;归一化坐标乘回主屏 frame;各自 `ttl_ms` 后淡出;
  `annotate.clear` 清空。
- 丢弃来自 `volunteer:*` 的 `control.*` 消息（安全规则）。

### A6. AI 裁判
- 订阅志愿者远端音频轨 → LiveKit audio frame 回调 → `SFSpeechRecognizer`
  （`requiresOnDeviceRecognition=true`，locale zh-CN，demo 只做中文）。
- 每个 final segment（或 5s 超时切段）POST `ai-referee`（CONTRACT §4.4）。
- `warn` → 悬浮层顶部黄色提示条 5s;`freeze` → 冻结流程:
  悬浮层变全屏半透明红 + 大字警告 + TTS 播报"检测到可疑请求，通话已暂停。
  请勿告诉任何人您的密码或验证码"，同时 unpublish 音视频轨，
  广播 `control.freeze`，POST `log-event`。老人点"是误报，继续"→ 恢复推流 +
  `control.resume`。
- 网络失败降级:本地关键词表直匹配（"验证码""密码""转账""汇款""礼品卡"
  命中即 freeze）。

### A7. AI 引导模式
- 菜单"AI 帮我":老人按住说话（SFSpeechRecognizer 转写任务描述）→
  取当前**打码后**帧转 JPEG（长边 ≤1568px）→ 采集焦点窗口 AX 树精简 JSON
  （role/title/frame，深度 ≤4，截断 8KB）→ POST `ai-guide`（CONTRACT §4.3）。
- 响应:`target_rect` 非空则悬浮层画圈，`instruction_text` TTS 播报。单轮即可。

## Mock 与联调

B 完成后端前:用 LiveKit 控制台手签 token 硬编码调试（CONTRACT §7）。
联调时间表见 CONTRACT §5。B 的 `web/fake-elder.html` 是协议参考实现，
标注坐标换算跟它对齐。

## 明确不做

多显示器、Windows/iOS、多志愿者、录像回放、英文语音、公证分发、
自动更新。做完上述全部才允许打磨动画。
