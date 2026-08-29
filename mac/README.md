# SecondSight Mac（老人端）

macOS 14+ / Swift 5.10+ / SwiftUI 菜单栏 App。启动时会自动显示主窗口，关闭后仍可从菜单栏眼睛图标重新打开。志愿者只能看已经在老人电脑本机打码后的屏幕，并通过圆圈、箭头和激光点指路；协议里没有鼠标或键盘控制消息。

当前先运行不含 AI 的实时协助流程：LiveKit 房间、摄像头、打码屏幕和麦克风保持启用；“AI 帮我”、AI 语音裁判以及对应的语音识别权限暂不启用。

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

客户端不得包含 `LIVEKIT_API_SECRET`、Supabase service role key 或 Anthropic key。LiveKit URL/token 只来自 `create-session` 响应。

## 模块与 TASK A 对应关系

- A1：`AppModel` + `SecondSightApp` 的 `idle → requesting → waiting → connected → frozen → ended` 状态机；原窗口内展示 6 位房间码并使用中文 TTS 朗读。
- 志愿者网页端离开 LiveKit 房间后，Mac 端会自动结束本次求助并同步显示结束状态；Mac 主动结束时不会重复处理离开回调。
- A2：`PermissionManager` + 主页权限卡片当前检查屏幕录制、辅助功能和麦克风；启用 AI 后才追加语音识别。系统提示出现时用不拦截点击的浮动箭头指向“打开系统设置”。进入系统设置后，若辅助功能已授权则从控件树精确定位 `SecondSightMac` 行，否则使用窗口内保守回退位置；提示窗显示在目标开关上方并用向下箭头指引点击，也可直接跳转对应权限页面。
- A3：`ScreenCaptureService` 用 ScreenCaptureKit 采主显示器 12fps，按 bundle id 排除本 App 窗口；用户点击“求助”并确认隐私提示后，`LiveKitTransport` 同时发布 720p/15fps 的 `elder-camera` 摄像头轨、`screen-redacted` 打码屏幕轨和 `elder-microphone` 麦克风轨。志愿者端应按轨道名分别展示两条视频。
- A4：`AccessibilityScanner` 用 AX 焦点事件即时触发并以 5Hz 扫描兜底；所有获得焦点的可编辑控件会在老人开始输入前遮挡，非空控件失焦后仍保持遮挡，邻近的密码/自动填充候选窗口一并保护；跨进程候选无法定位时先保护输入框下方的常见候选区域。扫描只判断本机值是否为空，不保存或写入摘要；`FrameRedactor` 先复制帧，再按 Retina 比例覆盖黑块。Secure Event Input 无定位矩形、AX 权限不可用或扫描尚未就绪时，整屏替换为安全占位图。
- A5：`OverlayWindowController` 是必要的薄 AppKit 窗口桥接，内容由 SwiftUI `OverlayView` 渲染圆圈、箭头、pointer、TTL 和 clear。`DataMessageCodec` 在解析边界拒绝 `volunteer:*` 的全部 `control.*`。
- A6：`RemoteAudioTrack.add(audioRenderer:)` 把志愿者 PCM 帧交给本机 `SFSpeechRecognizer`；final/5 秒切段调用 `ai-referee`，warn/freeze/resume 连接到悬浮层、TTS、unpublish/republish、DataChannel 和 `log-event`。网络失败时本地敏感词兜底。
- A7：SwiftUI “按住说话”转写任务；只取 `LatestFrameStore` 中已经打码的帧，JPEG 长边不超过 1568px；AX 摘要深度不超过 4 且不超过 8KB；响应圈选并 TTS。

## 首次运行与人工验收

1. 打开“第二双眼睛”，在主页权限卡片中依次授权。屏幕录制授权后退出并重新打开 App。
2. 填好真实公开配置，点“求助”，确认原窗口出现 6 位码且会朗读，同时没有弹出新的房间码窗口。
3. 点击“求助”后确认摄像头隐私提示；志愿者加入后确认原窗口内的房间码区域自动收起，LiveKit dashboard 出现 `elder-camera`、`screen-redacted` 和 `elder-microphone` 三条轨。志愿者页面需按名称分别展示两条视频。
4. Safari 和 Chrome 分别打开登录页：点击空邮箱框后，在输入第一个字符前确认志愿者视角已经变黑；输入后切走焦点仍应保持遮挡，清空后才解除。触发 iCloud 密码/浏览器自动填充候选时，确认邻近候选窗口也被遮挡。对 AX 无法定位、权限不可用或启用 Secure Event Input 的页面，应看到整屏安全占位图。
5. 确认原窗口内的房间码、悬浮圈和冻结警告不出现在志愿者视频里。
6. 从志愿者端发 circle/arrow/pointer/clear 并核对坐标；伪造 `control.freeze` 必须被老人端丢弃。
7. 志愿者说“把验证码念给我”，确认全屏红色冻结、音视频轨停止、双方收到 freeze 状态；老人点“是误报，继续通话”后恢复。
8. 在等待志愿者或通话期间按住“AI 帮我”说需求，确认发出的截图已经打码，返回后屏幕圈选并朗读一步指令。

自动构建和单测不能替代上述 LiveKit/Supabase、权限、两端画面和真实音频验收。尤其 300ms 打码时延和“自身窗口不回传”必须从志愿者视角测量。
