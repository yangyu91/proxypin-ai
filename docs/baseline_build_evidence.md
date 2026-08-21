# Firefox GeckoView 基线构建证据

| 项目 | 结果 |
|---|---|
| 基线提交 | [`03ba14391439f1173ac1c431ea14b5bd304b62a9`](https://github.com/yangyu91/proxypin-ai/commit/03ba14391439f1173ac1c431ea14b5bd304b62a9) |
| Android 构建 | [GitHub Actions #32496184158](https://github.com/yangyu91/proxypin-ai/actions/runs/32496184158) |
| Android 结果 | `success` |
| APK artifact | `proxypin-android-apk` |
| APK artifact ID | `9452026146` |
| APK 压缩 artifact 大小 | `262,876,236` bytes |
| Windows 构建 | [GitHub Actions #32496184103](https://github.com/yangyu91/proxypin-ai/actions/runs/32496184103) |
| Windows 结果 | `success` |
| Windows ZIP artifact | `proxypin-windows-x64`，artifact ID `9451884390` |

该构建为 Firefox GeckoView、HTTPS CA/Enterprise Roots、HTTP/2 协商、本机 MITM 级联和 R8 规则修复后的首个成功基线。后续独立代码复审和最终构建必须以该提交和 artifact 作为对照。
