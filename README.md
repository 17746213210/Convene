# Convene

局域网内两端发现并对连，交换 UTF-8 字符串。消息内容由接入方定义。

- Bonjour 发布 / 浏览（默认 `_convene._tcp`）
- 一条 TCP 会话，同一时刻一个对端
- 连上之后两端都能发、都能收
- 帧：应用消息 / ping / pong / close
- iOS 13+、tvOS 13+、macOS 10.15+

## 角色

| 子规格 | 职责 |
| --- | --- |
| `Convene/Host` | 发布服务，接受连接 |
| `Convene/Guest` | 浏览服务，发起连接 |

谁发业务数据、谁收业务数据由接入方决定，SDK 不绑定设备类型。

两边 `ConveneConfiguration` 的 `serviceType` 和 `applicationId` 必须一致，否则发现不到或会被过滤。

## 安装

```ruby
pod 'Convene/Host',  :path => 'path/to/Convene'
pod 'Convene/Guest', :path => 'path/to/Convene'
```

## Info.plist

需要 **Bonjour services**（`NSBonjourServices`）和本地网络说明（`NSLocalNetworkUsageDescription`）：

```xml
<key>NSBonjourServices</key>
<array>
    <string>_convene._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>Find nearby devices on your network.</string>
```

`serviceType` 若改成别的，这里的字符串要一起改。

## 配置

```swift
let configuration = ConveneConfiguration(
    applicationId: "com.example.app"
)
```

常用字段：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `serviceType` | `_convene._tcp` | Bonjour 服务类型 |
| `applicationId` | `""` | TXT `app`。空则不过滤 |
| `pingInterval` | 5s | 心跳 |
| `pingTimeout` | 15s | 心跳超时 |
| `connectTimeout` | 10s | 发起连接超时 |

发现和 TCP 走局域网 IPv4，不走 AWDL / IPv6 链路本地。

## Host

发布并等待连接，连上后收发字符串。

```swift
let host = ConveneHost(configuration: configuration)
host.delegate = self
host.start(displayName: "My Device")

host.send("hello")
host.stop()
```

```swift
func hostDidConnectGuest(_ host: ConveneHost) {}
func hostDidDisconnectGuest(_ host: ConveneHost) {}
func host(_ host: ConveneHost, didReceive message: String) {}
func host(_ host: ConveneHost, didFail error: Error) {}
```

已有对端时，多余入站连接会丢掉，不会踢掉当前会话。断开时先发 close 帧。`didFail` 只在尚未连上时回调；已连上后对端离开走 `hostDidDisconnectGuest`。

## Guest

浏览并发起连接，连上后收发字符串。

```swift
let browser = ConveneBrowser(configuration: configuration)
browser.delegate = self
browser.start()

let session = ConveneSession(configuration: configuration)
session.delegate = self
session.connect(to: device)
session.send("hello")
session.disconnect()
```

```swift
func browser(_ browser: ConveneBrowser, didUpdate devices: [ConveneDevice]) {}
func sessionDidConnect(_ session: ConveneSession) {}
func sessionDidDisconnect(_ session: ConveneSession) {}
func session(_ session: ConveneSession, didReceive message: String) {}
```

`ConveneDevice.id` 来自 TXT `id`，`name` 是 Bonjour 显示名。`applicationId` 非空时，只保留 TXT `app` 匹配的设备。

Host、Browser、Session 均 `@MainActor`。

## 帧

```
1 byte type + 4 byte big-endian length + payload
```

| type | 含义 |
| --- | --- |
| 0 | UTF-8 应用消息 |
| 1 | ping |
| 2 | pong |
| 3 | close |

单帧 payload 上限 256 KB。接入方只处理 `send` / `didReceive` 的字符串即可。
