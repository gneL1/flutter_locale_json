/// flutter_locale_json.dart
///
/// 1. 扫描 lib/**.dart (LocaleBase 家族) 的 String 字段
/// 2. 同步 assets/translations/<lang>.json
/// 3. 把源码字面量改成 "类名_字段名" 并格式化
///
/// 适配 analyzer ≥ 6.2 (NamedType.name2)

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;

import 'constants.dart';

/// ---------------- 全局常量 --------------------------------------------------
final _encoder = const JsonEncoder.withIndent('  ');
final _formatter = DartFormatter();

/// ---------------- 入口函数 --------------------------------------------------
Future<void> generateLocales({
  required String lang,
  required String jsonDir,
}) async {
  final jsonPath = p.join(jsonDir, '$lang.json');
  final projectDir = Directory.current;
  final libDir = Directory(p.join(projectDir.path, 'lib'));
  final jsonFile = File(p.join(projectDir.path, jsonPath));

  /// ① 扫描源码
  final scan = _scanSource(libDir);
  final keys = scan.$1;
  final initials = scan.$2;
  final edits = scan.$3;

  /// ② 读取 / 创建 JSON
  late final Map<String, String> translations;
  if (jsonFile.existsSync()) {
    translations = Map<String, String>.from(jsonDecode(jsonFile.readAsStringSync()));
  } else {
    translations = <String, String>{};
  }
  final firstRun = translations.isEmpty;

  /// ③ 同步 key（支持覆盖空串）
  for (final k in keys) {
    /// 从源码拿到原始中文
    final init = initials[k] ?? k;
    translations.update(
        k,
        /// value 为空 → 用 init
        (v) => v.isEmpty ? init : v,
        /// key 不在 → 也用 init
        ifAbsent: () => init);
  }

  translations.removeWhere((k, _) => !keys.contains(k));

  /// ④ value == key 时清空
  translations.updateAll((k, v) => v == k ? '' : v);

  /// ⑤ 保存 JSON
  jsonFile
    ..createSync(recursive: true)
    ..writeAsStringSync(_encoder.convert(translations));

  /// ⑥ 重写源码
  _rewriteSource(edits, translations);

  stdout.writeln(
      '✅ 生成完成：${jsonFile.path}（${translations.length} 条）${firstRun ? " - 首次初始化" : ""}');
}

/// ---------------- 扫描源码 --------------------------------------------------
(Set<String>, Map<String, String>, List<_Edit>) _scanSource(Directory libDir) {
  /// ---------- Pass1：继承图 & AST 缓存 -----------------------------------
  final parentMap = <String, List<String>>{};
  final units = <_ParsedUnit>[];

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;

    final unit =
        parseString(content: entity.readAsStringSync(), throwIfDiagnostics: false)
            .unit;
    units.add(_ParsedUnit(entity.path, unit));

    for (final cls in unit.declarations.whereType<ClassDeclaration>()) {
      parentMap[cls.name.lexeme] = [
        if (cls.extendsClause case final e?) e.superclass.name2.lexeme,
        ...?cls.withClause?.mixinTypes.map((t) => t.name2.lexeme),
        ...?cls.implementsClause?.interfaces.map((t) => t.name2.lexeme),
      ];
    }
    for (final mx in unit.declarations.whereType<MixinDeclaration>()) {
      parentMap[mx.name.lexeme] = [
        ...?mx.onClause?.superclassConstraints.map((t) => t.name2.lexeme),
        ...?mx.implementsClause?.interfaces.map((t) => t.name2.lexeme),
      ];
    }
  }

  /// ---------- 计算 LocaleBase 家族 --------------------------------------
  final localeFamily = {baseClassName};
  bool inherits(String name) {
    if (localeFamily.contains(name)) return true;
    final parents = parentMap[name];
    if (parents == null) return false;
    for (final p in parents) {
      if (inherits(p)) {
        localeFamily.add(name);
        return true;
      }
    }
    return false;
  }

  for (final n in parentMap.keys) inherits(n);

  /// ---------- Pass2：收集字段 -------------------------------------------
  final keys = <String>{};
  final initials = <String, String>{};
  final edits = <_Edit>[];

  for (final parsed in units) {
    final unit = parsed.unit;
    final filePath = parsed.path;

    void collect(String owner, Iterable<ClassMember> members) {
      for (final field in members.whereType<FieldDeclaration>()) {
        if (field.isStatic) continue;
        final typ = field.fields.type;
        if (typ is! NamedType || typ.name2.lexeme != 'String') continue;

        for (final v in field.fields.variables) {
          final init = v.initializer;
          if (init is! StringLiteral) continue;

          final key = '${owner}_${v.name.lexeme}';
          keys.add(key);
          initials[key] = init.stringValue ?? '';

          /// ✅ 这里改成 field.offset
          edits.add(_Edit(
            filePath,
            init.offset,
            init.length,
            key,
            /// FieldDeclaration.offset 指向的是「整个声明节点的起始位置」，
            fieldOffset: field.offset,
          ));
        }
      }
    }

    for (final cls in unit.declarations.whereType<ClassDeclaration>()) {
      final owner = cls.name.lexeme;
      if (owner != baseClassName && localeFamily.contains(owner)) {
        collect(owner, cls.members);
      }
    }
    for (final mx in unit.declarations.whereType<MixinDeclaration>()) {
      final owner = mx.name.lexeme;
      if (localeFamily.contains(owner)) {
        collect(owner, mx.members);
      }
    }
  }

  return (keys, initials, edits);
}

/// ---------------- 重写源码（字符串 & 注释） -------------------------------
void _rewriteSource(List<_Edit> edits, Map<String, String> translations) {
  final byFile = <String, List<_Edit>>{};
  for (final e in edits) {
    byFile.putIfAbsent(e.path, () => []).add(e);
  }

  for (final entry in byFile.entries) {
    final file = File(entry.key);
    var src = file.readAsStringSync();
    final textEdits = <_TextEdit>[];

    /// 1️⃣ 替换字符串字面量
    final strEdits = entry.value..sort((a, b) => b.offset.compareTo(a.offset));
    for (final e in strEdits) {
      final quote = _detectQuote(src, e.offset);
      textEdits.add(_TextEdit(
        e.offset,
        e.length,
        '$quote${e.replacement}$quote',
      ));
    }

    /// 2️⃣ 注释增删改
    for (final e in entry.value) {
      final value = translations[e.replacement] ?? '';

      /// 用字符串字面量的位置代替 fieldOffset
      /// 因为 e.offset 一定位于 = "xxx" 这一行，
      /// 所以 _lineStart 得到的就是字段行的行首，判断就不会失误了。
      final lineStart = _lineStart(src, e.offset);          // ✨ 改这里
      // final lineStart = _lineStart(src, e.fieldOffset);

      final indent = _leadingSpaces(src, lineStart);
      final comment = _matchDocCommentBlock(src, lineStart, indent);

      /// 若项目在 Windows 上开发，源文件多为 \r\n，
      final eol = src.contains('\r\n') ? '\r\n' : '\n';

      if (value.isEmpty) {
        if (comment != null) {
          textEdits.add(_TextEdit(comment.start, comment.end - comment.start, ''));
        }
      } else {
        /// 在文件加载后探测 EOL 并统一处理
        final newComment = '$indent/// $value$eol';

        if (comment != null) {
          if (src.substring(comment.start, comment.end) != newComment) {
            textEdits.add(_TextEdit(
                comment.start, comment.end - comment.start, newComment));
          }
        } else {
          textEdits.add(_TextEdit(lineStart, 0, newComment));
        }
      }
    }

    /// 3️⃣ 应用编辑
    textEdits.sort((a, b) => b.offset.compareTo(a.offset));
    for (final t in textEdits) {
      src = src.replaceRange(t.offset, t.offset + t.length, t.replacement);
    }
    file.writeAsStringSync(_formatter.format(src));
  }
}

/// ---------------- 辅助函数 --------------------------------------------------
/// 根据字符串字面量起始偏移检测其引号类型（支持 r'' r""" ''' """）。
String _detectQuote(String src, int offset) {
  int s = offset;
  /// 检测原始字符串前缀 r/
  final hasR = s > 0 && (src[s - 1] == 'r' || src[s - 1] == 'R');
  if (hasR) s--;

  /// 统计连续的相同引号数量
  final quoteChar = src[offset]; // ' 或 "
  int cnt = 0;
  while (offset + cnt < src.length && src[offset + cnt] == quoteChar) cnt++;
  final quotes = quoteChar * cnt;
  return hasR ? 'r$quotes' : quotes;
}

int _lineStart(String src, int offset) {
  while (offset > 0 && src[offset - 1] != '\n') offset--;
  return offset;
}

String _leadingSpaces(String src, int lineStart) {
  int i = lineStart;
  while (i < src.length && src[i] == ' ') i++;
  return src.substring(lineStart, i);
}

_RegMatch? _matchDocCommentBlock(String src, int lineStart, String indent) {
  int i = lineStart - 1;
  while (i >= 0 && src[i] != '\n') i--;
  if (i < 0) return null;
  int blockEnd = i + 1;

  while (true) {
    int j = i - 1;
    while (j >= 0 && src[j] != '\n') j--;
    final line = src.substring(j + 1, i).trimRight();
    if (!line.startsWith('$indent///')) break;
    i = j;
  }
  if (blockEnd == i + 1) return null;
  return _RegMatch(i + 1, blockEnd);
}

/// ---------------- 数据结构 --------------------------------------------------
class _Edit {
  final String path;

  /// 字符串字面量的偏移
  final int offset;

  /// 字符串字面量的长度
  final int length;

  /// 用来替换字面量的键
  final String replacement;

  /// 所属字段声明的偏移（用于注释）
  final int fieldOffset;
  _Edit(this.path, this.offset, this.length, this.replacement,
      {required this.fieldOffset});
}

class _TextEdit {
  final int offset, length;
  final String replacement;
  _TextEdit(this.offset, this.length, this.replacement);
}

class _RegMatch {
  final int start, end;
  _RegMatch(this.start, this.end);
}

class _ParsedUnit {
  final String path;
  final CompilationUnit unit;
  _ParsedUnit(this.path, this.unit);
}
