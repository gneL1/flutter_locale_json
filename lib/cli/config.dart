import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml_edit/yaml_edit.dart';
import 'package:yaml/yaml.dart';

import 'constants.dart';

/// 入口：准备配置、注入 pubspec，返回规范化目录
Future<String> prepareTranslationsDir() async {
  final dir = await _ensureConfigFile();

  /// 往 pubspec.yaml 写入配置文件
  await _ensurePubspecAssets(configFile);

  final modified = await _ensurePubspecAssets(dir);

  /// 如修改了 pubspec.yaml，则自动执行一次 `dart pub get`
  if (modified) {
    /// 自动 pub get
    stdout.writeln('✅ 执行 dart pub get …');
    final result = await Process.run('dart', ['pub', 'get']);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }

  return p.normalize(dir);
}

/// 若 locale_gen.yaml 不存在则创建，返回 _translationKey 的值
Future<String> _ensureConfigFile() async {
  final file = File(configFile);

  /// 如果不存在 locale_gen.yaml
  if (!file.existsSync()) {
    file.writeAsStringSync('$translationKey: $defaultTranslationsDir\n');
    stdout.writeln('✅ 创建 $configFile，默认目录 $defaultTranslationsDir');
    return defaultTranslationsDir;
  }

  final map = loadYaml(await file.readAsString()) as YamlMap;
  var dir = map[translationKey]?.toString() ?? defaultTranslationsDir;
  if (!dir.endsWith('/')) dir += '/';
  return dir;
}

/// 确保给定的资产目录路径被添加到 pubspec.yaml 的 flutter.assets 列表中
/// - 不重复添加
/// - 最终保持多行列表格式
/// - 保留原有注释和结构
/// 返回值表示是否对文件进行了修改。
Future<bool> _ensurePubspecAssets(String dir) async {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    /// 如果未找到 pubspec.yaml，直接返回 false
    stdout.writeln('⚠️ 未找到 pubspec.yaml ！');
    return false;
  }
  String content = await file.readAsString();

  /// 解析原始 YAML 文档
  final doc = loadYaml(content);

  /// 创建编辑器
  final editor = YamlEditor(content);
  bool modified = false;

  if (doc is YamlMap) {
    /// 根节点是 Map
    if (!doc.containsKey('flutter')) {
      /// 不存在 flutter 节点：直接创建一个带 assets 列表的新 flutter
      editor.update(['flutter'], {
        'assets': [dir],
      });
      modified = true;
    } else {
      /// 已有 flutter 节点
      final flutterSection = doc['flutter'];
      if (flutterSection is YamlMap) {
        /// flutter 本身是一个 Map（可能包含其他键）
        if (!flutterSection.containsKey('assets')) {
          /// 无 assets 键：新增 assets 列表
          editor.update(['flutter', 'assets'], [dir]);
          modified = true;
        } else {
          /// 已有 assets 键
          final assetsVal = flutterSection['assets'];
          if (assetsVal is YamlList) {
            /// 如果已是列表，检查是否已包含 dir
            bool exists = false;
            for (var item in assetsVal) {
              final value = item is YamlScalar ? item.value : item;
              if (value == dir) {
                exists = true;
                break;
              }
            }
            if (!exists) {
              final index = assetsVal.length;
              try {
                /// 在列表末尾追加新项
                editor.update(['flutter', 'assets', index], dir);
              } catch (_) {
                /// 若追加失败，则整体替换为新列表
                final newList = [
                  for (var item in assetsVal)
                    (item is YamlScalar ? item.value : item),
                  dir
                ];
                editor.update(['flutter', 'assets'], newList);
              }
              modified = true;
            }
          } else {
            /// assets 存在但不是列表，直接替换为新列表
            editor.update(['flutter', 'assets'], [dir]);
            modified = true;
          }
        }
      } else {
        /// flutter 存在但不是 Map（格式异常），重置为 Map 并添加 assets
        editor.update(['flutter'], {});
        editor.update(['flutter', 'assets'], [dir]);
        modified = true;
      }
    }
  } else {
    /// 根节点不是 Map（极少见），直接重建一个带 flutter 的 Map
    editor.update([], {
      'flutter': {'assets': [dir]},
    });
    modified = true;
  }

  /// 如果没有任何修改，提前返回
  if (!modified){
    stdout.writeln('ℹ️ pubspec.yaml 已包含 $dir');
    return false;
  }

  /// 获取编辑后的 YAML 字符串
  String newContent = editor.toString();

  /// 检查是否意外生成了 inline 映射（如 flutter: {...}），若有则转换为块状格式
  final inlinePattern = RegExp(r'^flutter:\s*\{([^}]*)\}', multiLine: true);
  final match = inlinePattern.firstMatch(newContent);
  if (match != null) {
    final inside = match.group(1);
    if (inside != null) {
      final parsed = loadYaml('{$inside}');
      if (parsed is YamlMap) {
        /// 重建 flutter 块状部分
        final buffer = StringBuffer('flutter:\n');
        for (var key in parsed.keys) {
          final keyStr = key is YamlScalar ? key.value : key;
          final value = parsed[key];
          if (value is YamlList) {
            buffer.writeln('  $keyStr:');
            for (var item in value) {
              final itemVal = item is YamlScalar ? item.value : item;
              buffer.writeln('    - $itemVal');
            }
          } else if (value is YamlMap) {
            buffer.writeln('  $keyStr:');
            value.forEach((subKey, subVal) {
              final subKeyStr = subKey is YamlScalar ? subKey.value : subKey;
              final subValStr = subVal is YamlScalar ? subVal.value : subVal;
              buffer.writeln('    $subKeyStr: $subValStr');
            });
          } else {
            final valStr = value is YamlScalar ? value.value : value;
            buffer.writeln('  $keyStr: $valStr');
          }
        }
        /// 替换原有 inline 段为块状段
        newContent =
            newContent.replaceRange(match.start, match.end, buffer.toString().trimRight());
      }
    }
  }

  /// 将最终内容写回文件
  await file.writeAsString(newContent);
  stdout.writeln('✅ 向 pubspec.yaml 添加资产目录: $dir');
  return true;
}