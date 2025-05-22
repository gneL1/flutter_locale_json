# flutter_locale_json — 代码驱动的 i18n 生成器

自动扫描继承 `LocaleBase` 的类 / mixin，  
把所有 `String` 常量替换为 **类名_字段名** 形式的 key，  
并同步生成 `assets/translations/<lang>.json`。

---

## 目录

1. [主要特性](#主要特性)
2. [快速开始](#快速开始)
3. [在 CI / 团队中使用](#在-ci--团队中使用)
4. [运行时加载翻译文件](#运行时加载翻译文件)
5. [命令行参数](#命令行参数)
6. [工作流程与原理](#工作流程与原理)
7. [常见问题](#常见问题)

---

## 主要特性

| 功能         | 说明                                                        |
|------------|-----------------------------------------------------------|
| **零配置**    | 只要你的类继承（或 mixin/on）自 `LocaleBase` 并声明 `String` 字段，即可被自动识别 |
| **双向同步**   | 新增字段 → 自动加入 JSON；删除字段 → JSON 自动清理                         |
| **源码重写**   | 把硬编码中文（或其它语言）字面量替换为 key，消除重复文本                            |
| **多语言**    | `--lang=en_US / zh_CN / …` 一行命令生成任意语言包                    |
| **跨平台**    | Windows、macOS、Linux、Flutter Web / 移动端均可使用                 |
| **可脚本化**   | 标准 `dart run` / `dart pub global` 可直接调用，易于集成 CI           |
| **自动声明**   | 运行命令后，会自动生成资源目录                                           |
| **自动生成注释** | 运行命令后，会根据翻译文件的`value`，为`Dart`类自动生成注释                      |

---

## 快速开始

### 1. 安装

```yaml
dev_dependencies:
  flutter_locale_json:
    git:
      url: https://github.com/gneL1/flutter_locale_json.git   # 或发布后换成 ^版本号
```

发布到 `pub.dev` 后可改为：

```yaml
dev_dependencies:
  flutter_locale_json: ^0.0.x
```

### 2. 定义本地化类

```dart
mixin Common on LocaleBase {
  final String ok = "确定";
}

class HomePageLocale extends LocaleBase with Common {
  final String title = "主页标题";
}
```

### 3. 生成

```bash
# 默认生成 zh_CN.json
dart run flutter_locale_json:generate

# 指定语言
dart run flutter_locale_json:generate -l en_US
```

生成的`Json`文件：

```json
{
  "Common_ok": "确定",
  "HomePageLocale_title": "主页标题"
}
```

`Dart`源码被自动替换：

```dart
/// 确定
final String ok = "Common_ok";

/// 主页标题
final String title = "HomePageLocale_title";
```

### 4. 自定义翻译文件目录

运行命令后，会自动生成`locale_gen.yaml`文件，在文件中可以配置翻译文件的目录地址：

```yaml
translations_dir: assets/translations/
```

### 5. 再次运行（增量维护）

* 新增 / 删除字段 → JSON 同步更新
* 如果把 value 改成与 key 相同 → 下次运行会自动置空 `""`，提示待翻译

---

## 在 CI / 团队中使用

```yaml
name: i18n-check

on: [pull_request]

jobs:
  locale:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
      - run: dart run flutter_locale_json:generate -l zh_CN
      - run: git diff --exit-code      # 同步不一致时 PR 失败
```

---

## 运行时加载翻译文件

`flutter_locale_json` 已内置两个方便的读取方法，你无需手动解析 `AssetManifest` 或遍历目录。

### 1. `loadLocalesFromAssets()`
适用于翻译文件被打包进应用的场景。

```dart
import 'package:flutter_locale_json/flutter_locale_json.dart';

final Map<String, Map<String, String>> locales =
    await FlutterLocaleLoader.loadLocalesFromAssets();

print(locales['zh_CN']?['Common_ok']); // => 确定
```

### 2. `loadLocalesFromDirectory(Directory dir)`
适用于从外部文件夹读取翻译文件的场景。

```dart
import 'dart:io';
import 'package:flutter_locale_json/flutter_locale_json.dart';

final directory = Directory('test/translations');
final locales =
    await FlutterLocaleLoader.loadLocalesFromDirectory(directory);

print(locales['en_US']?['HomePageLocale_title']); // => Home Page Title
```

两种方法都返回相同的数据结构：

```text
Map<String, Map<String, String>>
```

---

## 命令行参数

| 参数             | 默认值     | 说明           |
|----------------|---------|--------------|
| `-l`, `--lang` | `zh_CN` | 生成的语言码 / 文件名 |

多语言示例：

```bash
dart run flutter_locale_json:generate -l en_US
dart run flutter_locale_json:generate -l ja_JP
```

---

## 工作流程与原理

1. **AST 扫描**：`analyzer` 解析 `lib/` 下源码，识别 `LocaleBase` 子类 & 字段
2. **键名生成**：`<类名>_<字段名>`
3. **JSON 同步**：新增字段写入、删除字段移除、`value==key` 置空
4. **源码重写**：`replaceRange` + `dart_style`，支持 `'`, `"`, `'''`, `"""`, `r''`
5. **跨平台路径**：`package:path` 组合，兼容 Windows \\

---

## 常见问题

| 问题             | 解决方案                                            |
|----------------|-------------------------------------------------|
| 找不到 `analyzer` | 确保放在 `dependencies:` 而非 `dev_dependencies:`     |
| 命令不识别          | 用 `dart run flutter_locale_json:generate` 或全局激活 |
| JSON 值丢失       | 首次生成只会用源码字面量；如果被置空说明未翻译                         |
| 目录调整           | 修改项目根目录下的`locale_gen.yaml`文件                    |

---

> 本包处于测试阶段  
> Apache License
