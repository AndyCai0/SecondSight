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

- 菜单栏提供“呼叫在线助手”和“使用 6 位分享码”两条入口；两者都先明确说明摄像头
  将被分享并由老人确认，再调用 `create-session`（见 CONTRACT §4.1）。等待广播时仍在
  原窗口展示备用 6 位码；分享码模式同时用 `AVSpeechSynthesizer` 朗读。志愿者加入
  （LiveKit participant joined 事件）后号码区域收起。
- 所有面向老人的 UI:字号 ≥ 24pt，按钮大，文案口语化中文。

### A2. 权限向导（首启动）
默认安全协助依次检测并引导:屏幕录制、辅助功能、麦克风。每项显示实时状态，
未授权项给"打开系统设置"按钮。屏幕录制授权后提示需重启 App。只有启用可选的
本地 AI 引导时才额外要求语音识别权限。

### A3. 屏幕采集
- ScreenCaptureKit:主显示器，10–15 fps，输出适配 LiveKit 自定义视频轨
  （`BufferCapturer` / custom video source，喂 `CVPixelBuffer`）。
- `SCContentFilter(display:excludingWindows:)` 排除本 App 全部窗口
  （主窗口、悬浮层、警告窗）。验收:志愿者视角看不到我们自己的 UI。
- **这是全项目最大不确定点，最先做**:先跑通"采集→推流→LiveKit dashboard
  能看到轨道"。失败退路:WKWebView 内嵌一个最小网页用浏览器 WebRTC 采集推流
  （体验降级但通路保住），退路触发条件 = Day 1 上午结束仍未推流成功。

### A4. 打码管线（核心卖点，不可裁）
多路本机检测共同产出精确矩形，禁止用整屏或整窗遮罩代替隐私定位:

1. **AX 焦点事件 + 5 Hz 扫描兜底**:AXUIElement 遍历焦点应用窗口控件树，
   收集 (a) 当前获得焦点的所有可编辑控件 (b) 已有非空值的可编辑控件
   (c) secure text field (d) title/placeholder 命中敏感词的普通文本框，以及
   焦点输入框附近的密码/自动填充候选窗口；跨进程候选无法定位时先保护输入框下方
   的常见候选区域；取 `AXFrame`，
   换算 AX 坐标系(左上原点/点) → 采集帧像素坐标（注意 Retina scale 和多分辨率），
   每个矩形外扩 8px，写入线程安全的 `currentRedactionRects`。只判断值是否为空，
   不保存、记录或发出用户输入内容。
2. **静态内容和本机视觉补漏**:扫描老人屏幕上全部可见窗口的 AX 叶节点；按邮件、
   消息、日历、银行、身份、医疗等上下文局部保护文字、链接、图片和列表行。对 Canvas、
   PDF、照片和自绘内容用本机 Vision OCR、人脸、二维码/条码检测，只保留矩形。
3. **失败时暂停新帧**:轮询 `IsSecureEventInputEnabled()`；若开启却没有对应矩形，或
   AX/窗口/Vision 检查暂不可用，则不发布当前帧，保留上一张已经局部打码的安全帧。
   不得生成整屏或整窗黑块，也不得放行未检查原帧。
4. 每帧发布前用纯色块（黑）覆盖矩形（CoreImage 或直接改 pixel buffer，
   以性能稳定为准）。

验收:Safari 打开任意登录页，点入密码框 → 志愿者视角该区域为色块，
从获焦到遮蔽 ≤ 300ms；同一页面的普通标题、说明和操作按钮继续可见。

### A5. 全局标注悬浮层
- 透明 NSWindow:`level=.screenSaver`、`ignoresMouseEvents=true`、
  `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]`、无阴影。
- 渲染 DataChannel 标注消息（CONTRACT §3）:圆圈（描边+呼吸动画）、箭头、
  激光笔轨迹点;归一化坐标乘回主屏 frame;各自 `ttl_ms` 后淡出;
  `annotate.clear` 清空。
- 丢弃来自 `volunteer:*` 的 `control.*` 消息（安全规则）。

### A6. 实时安全监听
- 只能由老人主动点击“开始安全监听”开启；停止后必须关闭音频 renderer 和
  AssemblyAI websocket，断线时 UI 明确显示未受保护。
- 订阅志愿者远端音频轨，转成 16 kHz PCM16，通过后端短期 token 连接 AssemblyAI
  Streaming；永久 `ASSEMBLYAI_API_KEY` 不进入客户端。
- partial/final transcript 立即进入本地中英规则引擎；仅 warning/danger 显示大字警告、
  POST `risk-event` 并通过 DataChannel 发送 `safety.risk`。同一 streaming turn 使用
  8 秒 cooldown 去重，最近上下文只保留约 25 秒。
- 第一版不逐句调用 LLM；`ai-referee` 只保留为旧版/手工测试接口。未来 AI context
  analyzer 只能在规则判断可疑或未知时按需调用。

### A7. AI 引导模式
- 菜单"AI 帮我":老人按住说话（SFSpeechRecognizer 转写任务描述）→
  取当前**打码后**帧转 JPEG（长边 ≤1568px）→ 采集焦点窗口 AX 树精简 JSON
  （role/title/frame，深度 ≤4，截断 8KB）→ POST `ai-guide`（CONTRACT §4.3）。
- 响应:`target_rect` 非空则悬浮层画圈，`instruction_text` TTS 播报。单轮即可。
- 本次实时安全 demo 默认关闭该可选入口，避免额外的语音识别权限和持续 AI 成本；
  重新启用时必须恢复对应权限门和回归测试。

## Mock 与联调

B 完成后端前:用 LiveKit 控制台手签 token 硬编码调试（CONTRACT §7）。
联调时间表见 CONTRACT §5。B 的 `web/fake-elder.html` 是协议参考实现，
标注坐标换算跟它对齐。

## 明确不做

多显示器、Windows/iOS、多志愿者、录像回放、英文语音、公证分发、
自动更新。做完上述全部才允许打磨动画。
