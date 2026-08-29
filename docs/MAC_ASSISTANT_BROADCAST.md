# Mac 端在线助手广播接入

## 目标

Mac 端同时保留两种求助方式：

1. **呼叫在线助手**：向所有在线助手发布一条待响应求助，由助手自行选择是否响应；第一位成功响应者接入 LiveKit 会话。
2. **使用 6 位分享码**：老人把号码直接告诉认识的帮助者，原有流程不变。

Mac 端不会因为广播功能暂不可用而中断已创建的安全会话。广播接口失败时，界面会明确降级到分享码，不会显示“广播成功”。

## Mac 已实现的流程

1. 用户选择“呼叫在线助手”或“使用 6 位分享码”。
2. 用户确认摄像头隐私提示。
3. Mac 调用现有 `create-session`，连接 LiveKit，并开始发布摄像头、打码后的屏幕和麦克风。
4. 若选择在线助手，Mac 调用 `POST broadcast-session` 开启广播。
5. LiveKit 出现第一个远端助手 participant 后，Mac 沿用现有状态机进入 `connected`。
6. 用户结束会话时，Mac 尽力调用同一接口撤回广播，然后立即完成本地音视频清理。

等待广播时仍显示 6 位号码作为备用路径。即使没有在线助手，老人也能把号码告诉熟人。

## 伙伴端需要实现的接口

> 2026-08-29：以下伙伴端链路已经在本仓库实现。Web 标签页打开且未进入会话时，
> 会串行调用 `assistant-poll`；每次响应完成后等待 100ms 再发下一次，因此不会堆积
> 并发请求。页面明确显示“正在接收广播”。

### `POST broadcast-session`

请求开启广播：

```json
{
  "session_id": "9d1d5434-6da5-41e0-af70-c5aa35c6816f",
  "is_active": true
}
```

成功响应：

```json
{
  "ok": true,
  "notified_assistants": 4
}
```

`notified_assistants` 可省略。若提供，Mac 会显示本次实际通知的在线助手数量；`0` 表示广播已登记，但当前无人在线。

请求撤回广播：

```json
{
  "session_id": "9d1d5434-6da5-41e0-af70-c5aa35c6816f",
  "is_active": false
}
```

响应：

```json
{
  "ok": true
}
```

接口继续使用与其他 Edge Function 相同的 Supabase anon Bearer header。非 2xx、无法解码或 `ok=false` 都会被 Mac 视为广播未生效，并安全降级到分享码。

### `POST assistant-poll`

```json
{"assistant_id":"5f028bd8-9602-40ed-8c39-e35c6bca1a21","name":"小王"}
```

`assistant_id` 是当前浏览器标签页在 `sessionStorage` 中生成的 UUID。服务端同时刷新
`last_seen_at` 并返回仍处于 `waiting`、未撤回且未超过 15 分钟 TTL 的广播：

```json
{
  "broadcasts": [{
    "session_id": "9d1d5434-6da5-41e0-af70-c5aa35c6816f",
    "requested_at": "2026-08-29T10:00:00.000Z",
    "elder_label": "长辈"
  }]
}
```

响应不包含房间码或 LiveKit token。`broadcast-session` 统计 3 秒内刷新过的标签页为
在线助手。

### `POST claim-broadcast`

```json
{
  "session_id": "9d1d5434-6da5-41e0-af70-c5aa35c6816f",
  "assistant_id": "5f028bd8-9602-40ed-8c39-e35c6bca1a21",
  "name": "小王"
}
```

认领成功后返回与 `join-session` 相同的 `{session_id, lk_url, lk_token}`；并发输家返回
HTTP 409，且不会收到已签发给赢家的 token。认领成功会在同一个条件更新中把会话改为
`active` 并撤下广播。

## 网页端认领规则

- 广播列表只展示仍处于 `waiting` 且广播有效的会话。
- 列表不得暴露 LiveKit token，也不应直接暴露 6 位分享码。
- 助手点击“响应”后，后端必须原子认领；同一会话只能有一位成功响应者。
- 认领成功后再签发该助手的 LiveKit token，并立即从其他在线助手列表撤下。
- 会话结束、老人撤回、LiveKit 房间失效或超过服务端 TTL 后，必须清除广播。
- 助手身份、在线状态、广播送达和认领结果由伙伴的网页/后端负责；Mac 不维护助手名单。

## 兼容性与联调验收

当前已部署后端如果还没有 `broadcast-session`，Mac 会显示“广播暂时不可用”，但分享码、音视频和安全打码仍然工作。伙伴端接口上线后，无需再次修改 Mac 请求格式。

联调至少验证：

1. 两位助手在线时都看到同一条求助。
2. 第一位认领成功，第二位收到“已被响应”且不能拿到房间 token。
3. Mac 自动进入 `connected`，广播从所有助手列表消失。
4. Mac 主动结束时广播被撤回。
5. 广播接口离线时 Mac 明确降级到分享码，原有会话仍可加入。

## 后续扩展

100ms HTTP 轮询严格实现了当前 demo 的交互要求，但每个空闲标签页理论上最多产生
每秒 10 次 Edge Function 调用。正式扩容前应改为 Supabase Realtime Broadcast +
Presence 的 WebSocket 长连接；页面状态和 `claim-broadcast` 原子认领接口可以保持不变。
