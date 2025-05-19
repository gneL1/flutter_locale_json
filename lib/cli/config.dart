import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';
import 'package:yaml_edit/src/errors.dart';   // PathError

const _configFile = 'locale_gen.yaml';
const _defaultDir = 'assets/translations/';

/// 入口：确保配置文件和 pubspec.yaml 齐备，返回翻译目录
Future<String> prepareTranslationsDir() async {
  final dir = await _ensureConfigFile();
  final modified = await _ensurePubspecAssets(dir);

  /// 如修改了 pubspec.yaml，则自动执行一次 `dart pub get`
  if (modified) {
    stdout.writeln('▶ 执行 dart pub get …');
    final result = await Process.run('dart', ['pub', 'get']);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }

  return p.normalize(dir);
}

/// 若 locale_gen.yaml 不存在则创建，返回 translations_dir
Future<String> _ensureConfigFile() async {
  final file = File(_configFile);
  if (!file.existsSync()) {
    file.writeAsStringSync('translations_dir: $_defaultDir\n');
    stdout.writeln('✅ 创建 $_configFile，默认目录 $_defaultDir');
    return _defaultDir;
  }

  final map = loadYaml(await file.readAsString()) as YamlMap;
  var dir = map['translations_dir']?.toString() ?? _defaultDir;
  if (!dir.endsWith('/')) dir += '/';
  return dir;
}

/// 确保 pubspec.yaml 中包含 - <dir>，返回是否做了修改
Future<bool> _ensurePubspecAssets(String dir) async {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    throw Exception('未找到 pubspec.yaml，请在项目根目录运行。');
  }

  final editor = YamlEditor(await file.readAsString());
  final assetsPath = ['flutter', 'assets'];

  /// 判断 flutter.assets 是否已存在
  bool assetsExists;
  try {
    editor.parseAt(assetsPath);
    assetsExists = true;
  } on PathError {
    assetsExists = false;
  }

  if (!assetsExists) {
    /// 若整段不存在，先创建一个空列表
    editor.update(assetsPath, []);
  }

  final list = List.from(editor.parseAt(assetsPath).value);
  if (!list.contains(dir)) {
    list.add(dir);
    editor.update(assetsPath, list);
    await file.writeAsString(editor.toString());
    stdout.writeln('✅ 已向 pubspec.yaml 添加资产目录: $dir');
    return true;
  }

  stdout.writeln('ℹ️  pubspec.yaml 已包含 $dir');
  return false;
}
