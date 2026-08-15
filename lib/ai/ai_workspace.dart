import '../network/http/http.dart';

/// 浏览器、抓包和 AI 面板共享的本地工作区状态。
/// 不保存敏感原文，只保存当前页面和请求定位信息；请求详情仍由 AI 面板按脱敏策略读取。
class AiWorkspace {
  static final AiWorkspace instance = AiWorkspace._();
  AiWorkspace._();

  String? browserUrl;
  String? browserTitle;
  HttpRequest? currentRequest;

  void setBrowserPage({required String url, String? title}) {
    browserUrl = url;
    browserTitle = title;
  }

  void setCurrentRequest(HttpRequest? request) {
    currentRequest = request;
  }

  String get promptContext {
    final parts = <String>[];
    if (browserUrl?.trim().isNotEmpty == true) {
      parts.add('当前浏览器页面：${browserTitle?.trim().isNotEmpty == true ? '${browserTitle!.trim()} · ' : ''}$browserUrl');
    }
    if (currentRequest != null) {
      parts.add('当前抓包请求：${currentRequest!.method.name} ${currentRequest!.requestUrl}');
    }
    return parts.isEmpty ? '' : '\n\n共享工作区上下文：\n${parts.join('\n')}';
  }
}
