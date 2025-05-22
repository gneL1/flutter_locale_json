library flutter_locale_json;

/// 不能把`cli`目录下的文件也`export`进来，否则会报错：
/// /C:/Users/Lee/fvm/versions/3.7.12/packages/flutter/lib/src/gestures/converter.dart:
/// 19:5: Error: A non-null value must be returned since the return type 'int' doesn't allow null.
export 'src/locale_base.dart';
export 'src/flutter_locale_loader.dart';