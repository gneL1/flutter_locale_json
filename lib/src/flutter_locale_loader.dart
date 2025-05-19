import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p; // 🔹 统一跨平台拼接路径

class FlutterLocaleLoader{

  /// 从 `项目根目录/assets/translations/` 文件夹下加载所有翻译文本。
  ///
  /// * 返回值：
  ///   - `key`  : `locale`（例如 `zh_CN`、`en_US`）
  ///   - `value`: 对应的 `<String, String>` 文本映射
  static Future<Map<String, Map<String, String>>> loadLocalesFromAssets() async {

    /// 1. 载入清单
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

    /// 2. 获取目录地址 assets/translations
    final jsonDir = p.join('assets', 'translations');

    /// 3. 过滤 assets/translations 下的所有 json
    final paths = manifest
        .listAssets()
        .where((p) => p.startsWith(jsonDir) && p.endsWith('.json'))
        .toList();

    /// 4. 读取并返回内容
    final Map<String, Map<String, String>> result = {};
    for (final path in paths) {
      /// 从 assets 里读取字符串
      final data = await rootBundle.loadString(path);

      /// decode 为动态类型
      final Map<String, dynamic> jsonMap = json.decode(data);

      /// 将动态类型转为 <String, String>
      /// 这里假设 JSON 就是普通的 key-value, value 直接是 string
      /// 如果 JSON 结构更复杂，需要自行解析。
      final Map<String, String> stringMap =
      jsonMap.map((key, value) => MapEntry(key, value.toString()));

      /// 填充到定义的 result 中
      result[p.basenameWithoutExtension(path)] = stringMap;
    }

    return result;
  }


  /// 从指定目录读取所有 `.json` 翻译文件并解析为 `Map`。
  ///
  /// * [directory] 传入的目录必须已经存在。
  ///
  /// * 返回值：
  ///   - `key`  : `locale`（例如 `zh_CN`、`en_US`）
  ///   - `value`: 对应的 `<String, String>` 文本映射
  static Future<Map<String, Map<String, String>>> loadLocalesFromDirectory(Directory directory) async {

    final Map<String, Map<String, String>> result = {};

    /// 如果目录不存在
    if (!await directory.exists()) {
      return result;
    }

    /// 1. 递归遍历目录下所有文件
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;

      /// 2. 读取文件内容
      final jsonStr = await entity.readAsString();

      /// 3. 解析 JSON（假设是简单的 key-value 结构）
      final Map<String, dynamic> jsonMap = json.decode(jsonStr);

      /// 4. 转成 <String, String>
      final Map<String, String> stringMap =
      jsonMap.map((k, v) => MapEntry(k, v.toString()));

      /// 5. 以文件名（不含扩展名）作为 locale 键
      final localeKey = p.basenameWithoutExtension(entity.path);
      result[localeKey] = stringMap;
    }

    return result;
  }
}