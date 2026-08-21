# 最终源码复审记录

**审计范围**：Android Firefox GeckoView 内置浏览器、Dart 本机代理生命周期、端口设置、Android VPN/TUN 转发器。

本次审计在成功基线提交 `03ba14391439f1173ac1c431ea14b5bd304b62a9` 后重新进行。以下问题均为可由实际控制流推导出的缺陷，而非仅做格式或命名调整。

| 编号 | 缺陷 | 影响 | 修复 |
|---|---|---|---|
| 1 | GeckoRuntime 只在首次启动时从 YAML 读取 `localProxyPort`；端口随后修改时原代码只记录警告，Firefox 会继续发送到旧端口。 | 内置浏览器抓包和代理级联可能静默中断，直到重启应用。 | 在首次创建内置浏览器时固化本机代理端口；端口设置页在 Firefox 已启动后拒绝变更并提示重启；代理服务也拒绝重绑到不同端口；Android 层再以硬性保护拒绝不同端口的陈旧会话。 |
| 2 | 浏览器无活动标签索引；所有导航都写入 `_tabs[_tabs.length - 1]`，切换旧标签后的跳转会改写最后一个标签。 | 标签页 URL/历史漂移，用户无法可靠切换多标签。 | 增加 `_activeTabIndex`；新建、选择和关闭标签时维护索引；导航仅更新当前标签，并确保至少保留一个标签。 |
| 3 | TUN 路由器拿到的是 IP，却将 `*.example.com` 等域名规则与 IP 比较，并对每个包在 NIO 转发线程调用 `InetAddress.getByName()`。 | 域名绕过规则从语义上不会正确匹配；阻塞 DNS 查询会拖慢 VPN 转发，且 CDN 地址变化时结果不可靠。 | TUN 侧仅允许 IPv4、IPv4 CIDR 与 `localhost` 规则；删除阻塞 DNS 和无效通配符匹配；明确说明域名绕过需要 DNS 层截获。 |
| 4 | `initProxyConnect()` 先标记 `isInitConnect=true`，上游 `connect()` 或 NIO 注册失败后不回滚。 | TCP 会话会被永久视为已初始化，后续数据包提前返回，造成 VPN 连接卡死。 | 连接初始化改为返回成功状态；失败时回滚状态、关闭并移除会话，再向 TUN 客户端发送 RST。 |
| 5 | 端口设置允许 `0`。操作系统会随机绑定实际端口，但配置、VPN、Firefox 和其他设备仍使用 `0`。 | 用户配置 0 后，代理服务和外部连接目标不一致。 | 将可持久监听端口限制为 `1–65535`。 |

## 发布前验证

| 检查项 | 当前结果 | 最终验证方式 |
|---|---|---|
| Dart 变更空白检查 | 已通过 `git diff --check` | GitHub Android/Windows Release 构建 |
| 本机 Dart 格式化 | 当前沙箱未安装 Flutter/Dart SDK，无法本地执行 | GitHub Actions 使用固定 Flutter SDK 编译 |
| Kotlin/Android 编译 | 待执行 | GitHub Android Release 构建 |
| Windows 打包 | 待执行 | GitHub Windows Release 构建 |

最终提交后将以 GitHub Actions 的 Android APK 和 Windows x64 ZIP 成功结果作为发布门槛。
