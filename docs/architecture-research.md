# ProxyPin 新架构审计记录

## 用户目标

新增可被自身抓包的内置浏览器、浏览器内 AI 悬浮球、隐藏工具箱/配置/设置底部入口；加入 v2rayNG 风格的订阅导入、配置分组、节点测速和连接；评估接入 aipj Skill。

## 当前项目发现

移动端主导航位于 `lib/ui/mobile/mobile.dart`。当前 `navigationView` 包含请求页、工具箱、配置页和设置页；底部导航选择索引由 `_selectIndex` 控制。代理服务由 `ProxyServer(widget.configuration)` 启动，抓包请求通过 `MobileApp.requestStateKey.currentState!.add(channel, request)` 进入请求列表。

项目依赖已有 `webview_flutter`，但当前 Dart 代码中未发现已完成的内置浏览器页面或完整导航控制器。代理核心已有本地 `ProxyServer`、Android VPN 相关入口、外部代理配置、请求改写、脚本、环境变量和网络条件管理。

## v2rayNG 研究发现

仓库：https://github.com/2dust/v2rayNG

v2rayNG 是 Android 上的 V2Ray 客户端，支持 Xray core 和 v2fly core。源码中存在订阅管理、配置分组、配置导入、测速/连接测试、核心服务、VPN 服务、每应用代理和服务器配置编辑等模块。其功能不能直接复制到 Flutter；需要复用协议解析思路或通过兼容核心实现。代理核心能力与 ProxyPin 当前 MITM 抓包代理是不同层次，若要“浏览器全部走代理”，需要把浏览器 WebView 的网络请求接入 ProxyPin 的外部代理或 Android VPN/代理链路。

## 订阅地址研究发现

用户给出的地址：
https://gcore.jsdelivr.net/gh/aews/jd/v20812.txt

当前返回内容是一长段 Base64 风格文本。它看起来是订阅编码内容，不能简单按明文 JSON 解析；需要先尝试 Base64 解码，再按换行解析常见 URI 协议（vmess、vless、trojan、ss、socks、http 等），并把解析结果归入配置分组。真实导入前应做格式识别、去重、字段校验和敏感信息本地存储保护。

## aipj 研究发现

仓库：https://github.com/yangyu91/aipj

AIPJ 主要由 `SKILL.md`、`agents/`、`references/`、`scripts/` 和 `index.html` 构成，README 说明使用口令“实干模式”，并声明仅用于合法范围内测试。仓库包含网络逆向、登录爬虫、工具目录、漏洞审查、Nginx 反向代理和自动化脚本等内容。它更适合提取为用户可编辑的中文 Skill/提示词模板，不能未经审查直接把自动化测试脚本接入手机应用并允许 AI 无确认执行。

## 设计结论

第一阶段应先完成导航重构和内置浏览器容器；第二阶段完成浏览器请求进入 ProxyPin 的统一抓包路径及 AI 悬浮球；第三阶段完成订阅解析、分组、测速和“连接到外部代理”的数据层；第四阶段再接入经过审查的 aipj Skill 模板，并对外部请求、配置修改、脚本执行、连接和发包操作保留用户确认。
