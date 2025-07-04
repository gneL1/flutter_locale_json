import 'package:args/args.dart';
import 'package:flutter_locale_json/cli/config.dart';
import 'package:flutter_locale_json/cli/generate_locales.dart';

/// ------------------------------------------------------------
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('lang', abbr: 'l', defaultsTo: 'zh_CN',help: 'Language code, e.g. zh_CN / en_US');

  final argResults = parser.parse(arguments);
  final lang = argResults['lang'] as String;

  ///  准备目录（自动写入 pubspec.yaml & pub get）
  final jsonDir = await prepareTranslationsDir();

  /// 生成翻译文件
  await generateLocales(lang: lang, jsonDir: jsonDir);
}