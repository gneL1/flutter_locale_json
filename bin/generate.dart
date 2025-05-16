import 'package:args/args.dart';
import 'package:flutter_locale_json/generate_locales.dart';

/// ------------------------------------------------------------
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('lang', abbr: 'l', defaultsTo: 'zh_CN',help: 'Language code, e.g. zh_CN / en_US');

  final argResults = parser.parse(arguments);
  final lang = argResults['lang'] as String;

  await generateLocales(lang: lang);   // 调用核心
}