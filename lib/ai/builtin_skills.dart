/// 内置中文调试 Skill：提取自 aipj 的网络逆向、证据报告和工作流思想，
/// 仅用于用户授权的本地测试与接口调试。
class BuiltinSkills {
  static const networkDebug = '''网络调试工作流：
1. 先确认目标请求、域名、方法、状态码和响应时间。
2. 对 Header、Query、Body、响应和重定向进行结构化分析。
3. 默认隐藏 Token、Cookie、密码和 API Key；仅在用户明确选择字段后展示。
4. 先提出可验证假设，再通过重放或改包预览验证，不把猜测当成事实。
5. 对每次修改记录原值、新值、影响范围和回滚方式。
6. 改包、重放、发包、脚本执行和网络环境变更必须等待用户确认。
7. 输出证据链：请求编号、字段路径、观察结果、结论和下一步。''';

  static const reverseAnalysis = '''接口分析 Skill：
请按“请求概览 → 参数结构 → 认证方式 → 数据流 → 错误行为 → 验证建议”的顺序分析。
如果 Body 是压缩、编码或二进制数据，先说明无法直接解码的原因，不要编造字段。
如果需要修改请求，先生成 JSON 变更计划和预期差异，等待确认后再调用重放能力。''';

  static const evidenceReport = '''证据报告 Skill：
每个结论都要引用对应的请求 ID、时间、URL、状态码或响应字段。
区分“已观察事实”“合理推断”和“待验证假设”。
不要把测试目标之外的系统、账号或第三方数据作为默认操作对象。''';

  static const all = [networkDebug, reverseAnalysis, evidenceReport];
}
