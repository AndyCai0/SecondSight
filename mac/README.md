# SecondSight Mac（老人端）

macOS 14+ / Swift 5.10+ / SwiftUI 菜单栏 App。启动时会自动显示主窗口，关闭后仍可从菜单栏眼睛图标重新打开。志愿者只能看已经在老人电脑本机打码后的屏幕，并通过圆圈、箭头和激光点指路；协议里没有鼠标或键盘控制消息。

## 构建和测试

```bash
cd mac
swift package resolve
swift build
swift test
```

生成手工 `.app` bundle（release 构建、嵌入 LiveKit 的两个动态 framework、ad-hoc 签名）：

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

产物是 `mac/SecondSightMac.app`。脚本会运行 `plutil`、`codesign --verify --deep --strict`。这只是黑客松 demo 的 ad-hoc 签名，不包含公证或分发流程。

## 配置

复制公开配置模板：

```bash
cp Config.template.plist Config.plist
```

填写 B 提供的 `SUPABASE_URL` 和 `SUPABASE_ANON_KEY`，再运行打包脚本。`Config.plist` 已被 `.gitignore` 忽略。也可在直接运行 `swift run SecondSightMac` 时通过同名环境变量提供。

客户端不得包含 `LIVEKIT_API_SECRET`、Supabase service role key、Anthropic key 或
`ASSEMBLYAI_API_KEY`。LiveKit URL/token 只来自 `create-session` 响应；AssemblyAI 只使用
`assemblyai-token` 返回的短期单次凭证。

## 模块与 TASK A 对应关系

- A1：`AppModel` + `SecondSightApp` 的 `idle → requesting → waiting → connected → frozen → ended` 状态机；SwiftUI 菜单栏、全屏 6 位房间码和中文 TTS。
- A2：`PermissionManager` + 主页权限卡片实时检查屏幕录制、辅助功能、麦克风、语音识别；系统提示出现时用不拦截点击的浮动箭头指向“打开系统设置”，并可直接跳转对应权限页面。
- A3：`ScreenCaptureService` 用 ScreenCaptureKit 采主显示器 12fps，按 bundle id 排除本 App 窗口；`LiveKitTransport` 使用 `BufferCapturer` 发布自定义屏幕轨和麦克风轨。
- A4：`AccessibilityScanner` 5Hz 扫描 secure text field/敏感标题；`FrameRedactor` 先复制帧，再按 Retina 比例覆盖黑块；Secure Event Input 无定位矩形时整屏替换为安全占位图。
- A5：`OverlayWindowController` 是必要的薄 AppKit 窗口桥接，内容由 SwiftUI `OverlayView` 渲染圆圈、箭头、pointer、TTL 和 clear。`DataMessageCodec` 在解析边界拒绝 `volunteer:*` 的全部 `control.*`。
- A6：用户主动点 `Start Safety Listening` 后，`RemoteAudioTrack.add(audioRenderer:)` 才把志愿者 PCM 帧转换为 16 kHz mono PCM16 并送入 AssemblyAI Streaming v3。partial/final 字幕先经过本机 `FastRiskDetector`；相同 fingerprint 8 秒去重，最近上下文只保留 25 秒。warning/danger 立即显示大字安全层、写入 `risk-event` 并通过 LiveKit `safety.risk` 通知志愿者。Stop 会移除 renderer、发送 `Terminate` 并关闭 websocket；不会保存原始音频，也不会逐句调用 LLM。
- A7：SwiftUI “按住说话”转写任务；只取 `LatestFrameStore` 中已经打码的帧，JPEG 长边不超过 1568px；AX 摘要深度不超过 4 且不超过 8KB；响应圈选并 TTS。

## 首次运行与人工验收

1. 打开“第二双眼睛”，在主页权限卡片中依次授权。屏幕录制授权后退出并重新打开 App。
2. 填好真实公开配置，点“求助”，确认全屏出现 6 位码且会朗读。
3. 志愿者加入后确认房间码窗口自动收起，LiveKit dashboard/志愿者页面出现 `screen-redacted` 和麦克风轨。
4. Safari 打开登录页，聚焦密码框；从志愿者视角确认对应区域在 300ms 内变黑。对 AX 无法定位但启用 Secure Event Input 的页面，应看到整屏安全占位图。
5. 确认房间码窗、悬浮圈和冻结警告不出现在志愿者视频里。
6. 从志愿者端发 circle/arrow/pointer/clear 并核对坐标；伪造 `control.freeze` 必须被老人端丢弃。
7. 志愿者加入后，由老人点 `Start Safety Listening`；只有状态显示 `Safety Monitoring: ON / Listening…` 才表示保护已连接。确认 `Live Transcript` 在讲话未结束时就更新。
8. 依次说“Can you open the settings page?”（不报警）、“Please tell me the verification code you just received.”、“Transfer five hundred dollars to this bank account.”、“You need to install AnyDesk so I can control your computer.”；后三句应立即显示 Security Warning，志愿者网页同步出现风险卡。
9. 同一句危险话术连续产生 partial 时只应出现一次主要警告；点 Dismiss 后监听继续，点 Pause 后 websocket 和监听停止并冻结通话，点 Contact Volunteer 会再次发送提醒。
10. 在等待志愿者或通话期间按住“AI 帮我”说需求，确认发出的截图已经打码，返回后屏幕圈选并朗读一步指令。

自动构建和单测不能替代上述 LiveKit/Supabase、权限、两端画面和真实音频验收。尤其 300ms 打码时延和“自身窗口不回传”必须从志愿者视角测量。
