# SecondSight Mac（老人端）

macOS 14+ / Swift 5.10+ / SwiftUI 菜单栏 App。启动时会自动显示主窗口，关闭后仍可从菜单栏眼睛图标重新打开。志愿者只能看已经在老人电脑本机打码后的屏幕，并通过圆圈、箭头和激光点指路；协议里没有鼠标或键盘控制消息。

实时协助默认保持 LiveKit 房间、摄像头、打码屏幕和麦克风启用。老人主动开启安全监听后，
双方语音会转成实时字幕；本机规则和 DeepSeek 安全分析才会开始工作。

## 构建和测试

```bash
cd mac
swift package resolve
swift build
swift test
```

生成手工 `.app` bundle（release 构建、嵌入 LiveKit 的两个动态 framework、稳定的 Apple Development 签名）：

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open SecondSightMac.app
```

日常构建并启动统一使用：

```bash
scripts/build-and-run.sh --verify
```

它会先结束旧的 `SecondSightMac` 进程，再重新打包、启动并确认进程存在；也支持
`--debug`、`--logs` 和 `--telemetry`。

产物是 `mac/SecondSightMac.app`。脚本会自动选择钥匙串里的 Apple Development 证书，并运行 `plutil`、`codesign --verify --deep --strict`。也可通过 `SECONDSIGHT_SIGNING_IDENTITY` 指定稳定的签名证书；脚本不会退回 ad-hoc 签名，因为那会让屏幕录制、辅助功能等 TCC 权限在重新构建后失效。这里仍只是本地开发签名，不包含公证或分发流程。

## 配置

复制公开配置模板：

```bash
cp Config.template.plist Config.plist
```

填写 B 提供的 `SUPABASE_URL` 和 `SUPABASE_ANON_KEY`，再运行打包脚本。`Config.plist` 已被 `.gitignore` 忽略。也可在直接运行 `swift run SecondSightMac` 时通过同名环境变量提供。

客户端不得包含 `LIVEKIT_API_SECRET`、Supabase service role key、DeepSeek key 或
`ASSEMBLYAI_API_KEY`。LiveKit URL/token 只来自 `create-session` 响应；AssemblyAI 只使用
`assemblyai-token` 返回的短期单次凭证。

## 模块与 TASK A 对应关系

- A1：`AppModel` + `SecondSightApp` 的 `idle → requesting → waiting → connected → frozen → ended` 状态机；原窗口内展示 6 位房间码并使用中文 TTS 朗读。
- 志愿者网页端离开 LiveKit 房间后，Mac 端会自动结束本次求助并同步显示结束状态；Mac 主动结束时不会重复处理离开回调。
- A2：`PermissionManager` + 主页权限卡片当前检查屏幕录制、辅助功能和麦克风；启用 AI 后才追加语音识别。系统提示出现时用不拦截点击的浮动箭头指向“打开系统设置”。进入系统设置后，若辅助功能已授权则从控件树精确定位 `SecondSightMac` 行，否则使用窗口内保守回退位置；提示窗显示在目标开关上方并用向下箭头指引点击，也可直接跳转对应权限页面。
- A3：`ScreenCaptureService` 用 ScreenCaptureKit 采主显示器 12fps，按 bundle id 排除本 App 窗口；用户点击“求助”并确认隐私提示后，`LiveKitTransport` 同时发布 720p/15fps 的 `elder-camera` 摄像头轨、`screen-redacted` 打码屏幕轨和 `elder-microphone` 麦克风轨。志愿者端应按轨道名分别展示两条视频。
- A4：`AccessibilityScanner` 用 AX 焦点事件即时触发并以 5Hz 扫描兜底；它扫描老人屏幕上所有可见窗口，以输入控件、静态隐私叶节点和私密应用/网页上下文生成局部矩形。`VisualPrivacyScanner` 再以本机 Vision OCR、人脸和条码检测补足 Canvas、PDF、图片与自绘内容。扫描只判断/匹配本机内容，不把原始值写进摘要或日志；`FrameRedactor` 按 Retina 比例只覆盖这些矩形。Secure Event Input 无定位矩形、AX/窗口/Vision 检查不可用或扫描超时时，停止发布新帧并保留上一张已打码帧；永远不以整屏或整窗黑块代替隐私定位。
- A5：`OverlayWindowController` 是必要的薄 AppKit 窗口桥接，内容由 SwiftUI `OverlayView` 渲染圆圈、箭头、pointer、TTL 和 clear。`DataMessageCodec` 在解析边界拒绝 `volunteer:*` 的全部 `control.*`。
- A6：用户主动点“开始安全监听”后，老人本地麦克风和志愿者远端音频分别转换为
  16 kHz mono PCM16，使用两枚单次 token 接入 AssemblyAI Streaming v3。双方 partial/final
  字幕实时发到志愿者页；志愿者 partial 先由本机 `FastRiskDetector` 检查，final 则进入
  串行、合并排队的 DeepSeek 安全分析。分析输入含老人求助目标、最近双方对话，以及仅在
  打码画面明显变化时生成的 JPEG。AI warning/danger 只提醒老人并通知志愿者，不自动冻结。
  “停止安全监听”会移除两个 renderer、关闭 websocket 并取消待处理分析，不保存原始音频。
- A7：SwiftUI “按住说话”转写任务；只取 `LatestFrameStore` 中已经打码的帧，JPEG 长边不超过 1568px；AX 摘要深度不超过 4 且不超过 8KB；响应圈选并 TTS。

## 首次运行与人工验收

1. 打开“第二双眼睛”，在主页权限卡片中依次授权。屏幕录制授权后退出并重新打开 App。
2. 填好真实公开配置，点“求助”，确认原窗口出现 6 位码且会朗读，同时没有弹出新的房间码窗口。
3. 点击“求助”后确认摄像头隐私提示；志愿者加入后确认原窗口内的房间码区域自动收起，LiveKit dashboard 出现 `elder-camera`、`screen-redacted` 和 `elder-microphone` 三条轨。志愿者页面需按名称分别展示两条视频。
4. Safari 和 Chrome 分别打开登录页：点击空邮箱框后，在输入第一个字符前确认只有输入区域变黑；输入后切走焦点仍应保持遮挡，清空后才解除。触发 iCloud 密码/浏览器自动填充候选时，确认邻近候选窗口也被遮挡。再用合成邮件、银行、证件、医疗、照片和二维码页面确认相应内容分别局部遮挡，而普通标题、说明与按钮保留。对 AX 无法定位、权限不可用或启用 Secure Event Input 且无矩形的页面，应看到画面停在上一张已打码帧，恢复检查后继续更新。
5. 确认原窗口内的房间码、悬浮圈和冻结警告不出现在志愿者视频里。
6. 从志愿者端发 circle/arrow/pointer/clear 并核对坐标；伪造 `control.freeze` 必须被老人端丢弃。
7. 在主页填写本次求助目标，志愿者加入后由老人点“开始安全监听”；确认状态显示正在监听
   双方对话，志愿者网页能分别显示“老人”和“志愿者”的 partial/final 实时字幕。
8. 依次说“Can you open the settings page?”（不报警）、“Please tell me the verification code you just received.”、“Transfer five hundred dollars to this bank account.”、“You need to install AnyDesk so I can control your computer.”；后三句应立即显示 Security Warning，志愿者网页同步出现风险卡。
9. 同一句危险话术连续产生 partial 时只应出现一次主要警告；点“关闭提醒”后监听继续，点“暂停通话”后 websocket 和监听停止并冻结通话，点“联系志愿者”会再次发送提醒。
10. 保持屏幕静止并连续说两轮话，确认 DeepSeek 只收到第一张打码截图；仅移动光标不应
    产生新截图。切换到明显不同的窗口后再说一轮，确认请求携带新的 `screen_revision`。
11. 在等待志愿者或通话期间按住“AI 帮我”说需求，确认发出的截图已经打码，返回后屏幕圈选并朗读一步指令。

自动构建和单测不能替代上述 LiveKit/Supabase、权限、两端画面和真实音频验收。尤其 300ms 打码时延和“自身窗口不回传”必须从志愿者视角测量。
