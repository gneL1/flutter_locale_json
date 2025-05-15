// tool/generate_locale_json.dart
//
// 1. 扫描 lib/**.dart (_LocaleBase 家族) 的 String 字段
// 2. 同步 assets/translations/zh_CN.json
// 3. 把源码字面量改成 "类名_字段名" 并格式化
//
// 适配 analyzer ≥6.2 (NamedType.name2)

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:args/args.dart';
import 'package:dart_style/dart_style.dart';

// const _jsonPath = 'assets/translations/zh_CN.json';
final _encoder   = const JsonEncoder.withIndent('  ');
final _formatter = DartFormatter();

/// ------------------------------------------------------------
void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('lang', abbr: 'l', defaultsTo: 'zh_CN');

  final argResults = parser.parse(arguments);
  final lang = argResults['lang'] as String;

  final jsonPath = 'assets/translations/$lang.json';

  final projectDir = Directory.current;
  final libDir     = Directory('${projectDir.path}/lib');
  final jsonFile   = File('${projectDir.path}/$jsonPath');

  // ① 扫描：得到 (keys, initValues, edits)
  final scan   = _scanSource(libDir);
  final keys   = scan.$1;     // Set<String>
  final initials  = scan.$2;     // Map<String,String>
  final edits  = scan.$3;     // List<_Edit>

  // ② 读取 / 创建 JSON
  late final Map<String, String> translations;
  if (jsonFile.existsSync()) {
    final raw = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
    translations = Map<String, String>.from(raw);
  } else {
    translations = <String, String>{};
  }

  final bool firstRun = translations.isEmpty;

  // ③ 同步：新增、删除
  for (final k in keys) {
    translations.putIfAbsent(k, () => initials[k] ?? k);   // 用源码字面量作为默认 value
  }
  translations.removeWhere((k, _) => !keys.contains(k));

  // ④ 只有 value == key 时置空
  translations.updateAll((k, v) => v == k ? '' : v);

  // ⑤ 保存 JSON
  jsonFile
    ..createSync(recursive: true)
    ..writeAsStringSync(_encoder.convert(translations));

  // ⑥ 重写源码
  _rewriteSource(edits);

  stdout.writeln(
      '✅ 生成完成：${jsonFile.path}（${translations.length} 条）'
          '${firstRun ? " - 首次初始化" : ""}');
}

/// ---------- 扫描源码 --------------------------------------------------------
( Set<String>, Map<String,String>, List<_Edit> )
_scanSource(Directory libDir) {
  final Set<String>         keys   = {};
  final Map<String, String> initials  = {};   // key → 原始字面量
  final List<_Edit>         edits  = [];

  bool isLocaleFamily(NamedType? t) =>
      t != null &&
          (t.name2.lexeme == '_LocaleBase' || t.name2.lexeme == 'Locale');

  void collect(String owner, Iterable<ClassMember> members, String filePath) {
    for (final field in members.whereType<FieldDeclaration>()) {
      if (field.isStatic) continue;
      final typ = field.fields.type;
      if (typ is! NamedType || typ.name2.lexeme != 'String') continue;

      for (final varDeclaration in field.fields.variables) {
        final init = varDeclaration.initializer;
        if (init is! StringLiteral) continue;

        final key = '${owner}_${varDeclaration.name.lexeme}';
        final initValue = init.stringValue ?? '';

        keys.add(key);
        initials[key] = initValue;
        edits.add(_Edit(filePath, init.offset, init.length, key));
      }
    }
  }

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;

    final unit = parseString(
        content: entity.readAsStringSync(), throwIfDiagnostics: false)
        .unit;

    // class
    for (final cls in unit.declarations.whereType<ClassDeclaration>()) {
      final owner = cls.name.lexeme;
      if (owner == '_LocaleBase') continue;

      final inherits = isLocaleFamily(cls.extendsClause?.superclass) ||
          cls.withClause?.mixinTypes.any(isLocaleFamily) == true ||
          cls.implementsClause?.interfaces.any(isLocaleFamily) == true;

      if (inherits) collect(owner, cls.members, entity.path);
    }

    // mixin
    for (final mx in unit.declarations.whereType<MixinDeclaration>()) {
      final owner = mx.name.lexeme;
      final onBase =
          mx.onClause?.superclassConstraints.any(isLocaleFamily) == true;
      if (onBase) collect(owner, mx.members, entity.path);
    }
  }

  return (keys, initials, edits);
}

/// ---------- 重写源码 --------------------------------------------------------
void _rewriteSource(List<_Edit> edits) {
  final files = <String, List<_Edit>>{};
  for (final e in edits) {
    files.putIfAbsent(e.path, () => []).add(e);
  }

  for (final entry in files.entries) {
    final file = File(entry.key);
    var src    = file.readAsStringSync();

    // 倒序替换
    final sorted = entry.value..sort((a, b) => b.offset.compareTo(a.offset));
    for (final e in sorted) {
      final quote = src[e.offset] == '\'' ? '\'' : '"';
      src = src.replaceRange(
          e.offset, e.offset + e.length, '$quote${e.replacement}$quote');
    }
    file.writeAsStringSync(_formatter.format(src));
  }
}

/// ---------- Helper ---------------------------------------------------------
class _Edit {
  final String path;
  final int    offset;
  final int    length;
  final String replacement;
  _Edit(this.path, this.offset, this.length, this.replacement);
}
