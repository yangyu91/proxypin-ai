import 'dart:ui';

import 'package:proxypin_ai/ui/configuration.dart';

/// @author wanghongen
class Localizations {
  static bool get isZH {
    if (AppConfiguration.current?.language != null) {
      return AppConfiguration.current?.language!.languageCode == 'zh';
    }

    return PlatformDispatcher.instance.locale.languageCode == 'zh';
  }
}
