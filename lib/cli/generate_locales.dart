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
    translations =
    Map<String, String>.from(jsonDecode(jsonFile.readAsStringSync()));
  } else {
    translations = <String, String>{};
  }
  final firstRun = translations.isEmpty;

  /// ③ 同步 key（支持覆盖空串）
  for (final k in keys) {
    final init = initials[k] ?? k;
    translations.update(
      k,
          (v) => v.isEmpty ? init : v,
      ifAbsent: () => init,
    );
  }

  /// 移除无用 key
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
    '✅ 生成完成：${jsonFile.path}（${translations.length} 条）${firstRun ? " - 首次初始化" : ""}',
  );
}

/// ---------------- 扫描源码 --------------------------------------------------
(Set<String>, Map<String, String>, List<_Edit>) _scanSource(Directory libDir) {
  /// ---------- Pass1：继承图 & AST 缓存 -----------------------------------
  final parentMap = <String, List<String>>{};
  final units = <_ParsedUnit>[];

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;

    final unit = parseString(
      content: entity.readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;

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

  for (final n in parentMap.keys) {
    inherits(n);
  }

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

          /// stringValue 会把转义解析成真实字符（例如 "\n" → 换行）
          initials[key] = init.stringValue ?? '';

          edits.add(_Edit(
            filePath,
            init.offset,
            init.length,
            key,

            /// ✅ 关键：这里一定要用 field.fields.offset
            /// - field.offset 可能落在 doc comment 上，容易引起匹配/插入错位
            /// - field.fields.offset 指向声明本体（String/late/final 这一行），不会被 doc comment 干扰
            fieldOffset: field.fields.offset,
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

    /// 探测文件使用的换行符（保留原风格）
    final eol = src.contains('\r\n') ? '\r\n' : '\n';

    /// 1️⃣ 替换字符串字面量（仍然锚定字面量 offset，这是正确的）
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
    ///
    /// 去重：同一条字段声明只处理一次（避免一行声明多个变量时重复插入）
    final processedAnchors = <int>{};

    for (final e in entry.value) {
      final rawValue = translations[e.replacement] ?? '';

      /// 统一换行，避免 \r\n/\r/\u2028/\u2029 干扰
      final normalized = _normalizeDocText(rawValue);

      /// 用规范化后的 trim 判断是否为空（避免 value 只是空白/换行）
      final isEmptyValue = normalized.trim().isEmpty;

      /// ✅ 关键：注释定位必须锚定到字段声明行，而不是字符串字面量行
      final declLineStart = _lineStart(src, e.fieldOffset);
      final indent = _leadingIndent(src, declLineStart);

      /// 如果字段前面有注解（@xxx），doc comment 应该放在注解块上方
      final anchorLineStart =
      _findAnnotationBlockTopLineStart(src, declLineStart, indent);

      if (!processedAnchors.add(anchorLineStart)) continue;

      final comment = _matchDocCommentBlock(src, anchorLineStart, indent);

      if (isEmptyValue) {
        /// value 为空：移除已有注释
        if (comment != null) {
          textEdits.add(_TextEdit(
            comment.start,
            comment.end - comment.start,
            '',
          ));
        }
      } else {
        /// value 非空：构建安全 + 多行 doc comment 块
        final newComment = _buildDocCommentBlock(indent, normalized, eol);

        if (comment != null) {
          if (src.substring(comment.start, comment.end) != newComment) {
            textEdits.add(_TextEdit(
              comment.start,
              comment.end - comment.start,
              newComment,
            ));
          }
        } else {
          /// 插入到“字段声明/注解块”的顶部行之前
          textEdits.add(_TextEdit(anchorLineStart, 0, newComment));
        }
      }
    }

    /// 3️⃣ 应用编辑（从后往前，避免 offset 失效）
    textEdits.sort((a, b) => b.offset.compareTo(a.offset));
    for (final t in textEdits) {
      src = src.replaceRange(t.offset, t.offset + t.length, t.replacement);
    }

    file.writeAsStringSync(_formatter.format(src));
  }
}

/// ---------------- 辅助函数 --------------------------------------------------
/// 根据字符串字面量起始偏移检测其引号类型（支持 r'' r""" ''' """）
///
/// 兼容两种情况：
/// - offset 指向引号
/// - offset 指向 r/R
String _detectQuote(String src, int offset) {
  var i = offset;
  var hasR = false;

  if (i < src.length && (src[i] == 'r' || src[i] == 'R')) {
    hasR = true;
    i++;
  } else if (i > 0 && (src[i - 1] == 'r' || src[i - 1] == 'R')) {
    hasR = true;
  }

  if (i >= src.length) return hasR ? 'r"' : '"';

  final quoteChar = src[i]; // ' 或 "
  var cnt = 0;
  while (i + cnt < src.length && src[i + cnt] == quoteChar) cnt++;

  final quotes = quoteChar * cnt;
  return hasR ? 'r$quotes' : quotes;
}

int _lineStart(String src, int offset) {
  while (offset > 0 && src[offset - 1] != '\n') offset--;
  return offset;
}

/// 兼容 space + tab 的缩进
String _leadingIndent(String src, int lineStart) {
  var i = lineStart;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t') {
      i++;
      continue;
    }
    break;
  }
  return src.substring(lineStart, i);
}

/// 返回上一行的 lineStart；如果没有上一行返回 -1
int _prevLineStart(String src, int lineStart) {
  if (lineStart <= 0) return -1;

  /// 找到上一行的 '\n'
  var i = lineStart - 1;
  if (i >= 0 && src[i] == '\n') i--;
  while (i >= 0 && src[i] != '\n') i--;
  return i + 1;
}

/// 取出 [lineStart] 对应的“行文本”（不包含换行符）
String _lineTextAt(String src, int lineStart) {
  var end = lineStart;
  while (end < src.length && src[end] != '\n') end++;
  var line = src.substring(lineStart, end);

  /// 去掉可能存在的 '\r'
  if (line.endsWith('\r')) {
    line = line.substring(0, line.length - 1);
  }
  return line;
}

/// 如果字段声明上方有注解（@xxx），doc comment 应该插入到注解块上方
///
/// 说明：
/// - 只跨越“紧邻在声明上方、同缩进”的注解行
/// - 不跨越空行（空行会切断 doc comment 关联）
///
/// 这能避免：
///   @xxx
///   String a = ...
/// 被插成：
///   @xxx
///   /// ...
///   String a = ...
int _findAnnotationBlockTopLineStart(
    String src,
    int declLineStart,
    String indent,
    ) {
  var top = declLineStart;

  while (true) {
    final prevStart = _prevLineStart(src, top);
    if (prevStart < 0) break;

    final prevLine = _lineTextAt(src, prevStart).trimRight();

    /// 空行：停止（不跨越空行）
    if (prevLine.trim().isEmpty) break;

    /// 同缩进的注解行：向上吸收
    if (prevLine.startsWith('$indent@')) {
      top = prevStart;
      continue;
    }

    break;
  }

  return top;
}

_RegMatch? _matchDocCommentBlock(String src, int lineStart, String indent) {
  var i = lineStart - 1;
  while (i >= 0 && src[i] != '\n') i--;
  if (i < 0) return null;
  final blockEnd = i + 1;

  while (true) {
    var j = i - 1;
    while (j >= 0 && src[j] != '\n') j--;
    final line = src.substring(j + 1, i).trimRight();
    if (!line.startsWith('$indent///')) break;
    i = j;
  }

  if (blockEnd == i + 1) return null;
  return _RegMatch(i + 1, blockEnd);
}

/// ---------------- 特殊字符支持：注释安全化 ----------------------------------
/// 规范化：把各种换行统一成 '\n'，并处理常见 Unicode 行分隔符
String _normalizeDocText(String input) {
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u2028', '\n') // LINE SEPARATOR
      .replaceAll('\u2029', '\n'); // PARAGRAPH SEPARATOR
}

/// 把注释里不适合直接出现的控制字符变成“可读且安全”的文本
/// - '\n' 保留（用于拆行）
/// - '\t' 转成两个空格（避免缩进错乱）
/// - '\b' '\f' '\v' 转成转义文本
/// - 其它 0x00-0x1F / 0x7F 转成 \u{XX}
String _sanitizeForDocComment(String input) {
  final s = _normalizeDocText(input);
  final buf = StringBuffer();

  for (final rune in s.runes) {
    switch (rune) {
      case 0x0A: // \n
        buf.write('\n');
        break;
      case 0x09: // \t
        buf.write('  ');
        break;
      case 0x08: // \b
        buf.write(r'\b');
        break;
      case 0x0C: // \f
        buf.write(r'\f');
        break;
      case 0x0B: // \v
        buf.write(r'\v');
        break;
      default:
        if (rune < 0x20 || rune == 0x7F) {
          final hex = rune.toRadixString(16).toUpperCase();
          buf.write(r'\u{');
          buf.write(hex);
          buf.write('}');
        } else {
          buf.write(String.fromCharCodes([rune]));
        }
        break;
    }
  }

  return buf.toString();
}

/// 把翻译值构造成连续的 Dart 文档注释块（每行都带 ///）
/// - 支持多行
/// - 支持空行（空行用 "///" 占位，保证仍是连续 doc comment 块）
String _buildDocCommentBlock(String indent, String value, String eol) {
  final safe = _sanitizeForDocComment(value);
  final lines = safe.split('\n');

  final sb = StringBuffer();
  for (final line in lines) {
    if (line.isEmpty) {
      sb.write('$indent///$eol');
    } else {
      sb.write('$indent/// $line$eol');
    }
  }
  return sb.toString();
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

  /// 字段声明（不含 doc comment）的 offset，用于注释定位
  final int fieldOffset;

  _Edit(
      this.path,
      this.offset,
      this.length,
      this.replacement, {
        required this.fieldOffset,
      });
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
