import "package:analyzer/analysis_rule/rule_context.dart";
import "package:analyzer/analysis_rule/rule_visitor_registry.dart";
import "package:analyzer/dart/ast/ast.dart";
import "package:analyzer/dart/element/element.dart";
import "package:analyzer/error/error.dart";
import "package:meta/meta.dart";

import "project_ast_visitor.dart";
import "project_dart_lint_rule.dart";

/// レイヤ依存方向違反回避ルール
///
/// レイヤ依存方向の違反を回避するためのルールです。
/// 依存方向が逆転している場合にはエラーとします。
class AvoidReverseLayerDependencyRule extends ProjectDartLintRule {
  AvoidReverseLayerDependencyRule()
    : super(
        name: "avoid_reverse_layer_dependency",
        description: "Import or export violates the allowed direction of layer dependencies.",
      );

  @override
  LintCode get diagnosticCode => const LintCode(
    "avoid_reverse_layer_dependency",
    "Import or export violates the allowed direction of layer dependencies.",
    correctionMessage: "Check the layer dependency rules and fix the import or export.",
  );

  @override
  void registerProjectNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(this, context);
    registry.addImportDirective(this, visitor);
    registry.addExportDirective(this, visitor);
  }
}

class _Visitor extends ProjectAstVisitor {
  _Visitor(super.rule, this.context);
  final RuleContext context;

  static final _allowed = <_Layer>{
    _Presentation(),
    _Application(),
    _Domain(),
    _Infrastructure(),
    _Common(),
  };

  static _Layer? _findLayer(_LayerEnum self) {
    for (final layer in _allowed) {
      if (layer.self == self) return layer;
    }
    return null;
  }

  @override
  void visitImportDirective(ImportDirective node) {
    _checkDirective(
      node,
      node.libraryImport?.importedLibrary,
      node.libraryImport?.namespace.definedNames2 ?? {},
    );
  }

  @override
  void visitExportDirective(ExportDirective node) {
    final library = node.libraryExport?.exportedLibrary;
    _checkDirective(
      node,
      library,
      library?.exportNamespace.definedNames2 ?? {},
    );
  }

  void _checkDirective(
    NamespaceDirective node,
    LibraryElement? library,
    Map<String, Element> names,
  ) {
    if (!shouldLint(node)) return;
    final path = getFilePath(node);
    final packageRoot = rule.packageRoot;
    if (path == null || packageRoot == null) return;

    final libraryUri = context.libraryElement?.uri;
    final packageName = libraryUri != null && libraryUri.isScheme("package") ? libraryUri.pathSegments.firstOrNull : null;

    bool isForbidden(String uri) => !isAllowedLayerImport(
      currentPath: path,
      importUri: uri,
      packageRoot: packageRoot,
      packageName: packageName,
    );

    bool isForbiddenLibrary(LibraryElement? target) {
      final targetPath = target?.firstFragment.source.fullName;
      return targetPath != null && isProjectLibPath(targetPath, packageRoot) && isForbidden(targetPath);
    }

    // Check every explicitly named branch, including inactive configurations.
    for (final uri in [node.uri, ...node.configurations.map((c) => c.uri)]) {
      if (isForbidden(uri.stringValue ?? "")) {
        rule.reportAtNode(uri);
        return;
      }
    }
    if (isForbiddenLibrary(library)) {
      rule.reportAtNode(node.uri);
      return;
    }

    // The analyzer has already followed transitive exports and export cycles.
    // Apply this directive's combinators before checking declaration origins.
    for (final entry in names.entries) {
      final name = entry.key.endsWith("=") ? entry.key.substring(0, entry.key.length - 1) : entry.key;
      if (!_isVisible(name, node.combinators)) continue;
      if (isForbiddenLibrary(entry.value.library)) {
        rule.reportAtNode(node.uri);
        return;
      }
    }
  }

  bool _isVisible(String name, Iterable<Combinator> combinators) {
    for (final combinator in combinators) {
      if (combinator is ShowCombinator && !combinator.shownNames.any((identifier) => identifier.name == name)) {
        return false;
      }
      if (combinator is HideCombinator && combinator.hiddenNames.any((identifier) => identifier.name == name)) {
        return false;
      }
    }
    return true;
  }
}

String? _libRelative(String path, String packageRoot) {
  if (!isProjectLibPath(path, packageRoot)) return null;
  final root = packageRoot.replaceAll(r"\", "/").replaceFirst(RegExp(r"/$"), "");
  return path.replaceAll(r"\", "/").substring(root.length + 5);
}

String? _importRelative(String current, String imported, String packageRoot, String? packageName) {
  final direct = _libRelative(imported, packageRoot);
  if (direct != null) return direct;
  final uri = Uri.tryParse(imported.replaceAll(r"\", "/"));
  if (uri == null) return null;
  if (uri.isScheme("package")) {
    if (uri.pathSegments.firstOrNull != packageName) return null;
    return uri.pathSegments.skip(1).join("/");
  }
  if (uri.hasScheme || uri.hasAuthority) return null;
  if (uri.path.startsWith("/")) return uri.normalizePath().path.substring(1);
  final resolved = Uri(path: "/lib/$current").resolveUri(uri).path;
  return resolved.startsWith("/lib/") ? resolved.substring(5) : null;
}

@visibleForTesting
bool isAllowedLayerImport({
  required String currentPath,
  required String importUri,
  required String packageRoot,
  String? packageName,
}) {
  final current = _libRelative(currentPath, packageRoot);
  if (current == null) return true;
  final imported = _importRelative(current, importUri, packageRoot, packageName);
  final currentLayer = _LayerEnum.fromRelativePath(current);
  final importedLayer = imported == null ? null : _LayerEnum.fromRelativePath(imported);
  if (currentLayer == null || importedLayer == null) return true;

  if (currentLayer == _LayerEnum.infrastructure && imported?.startsWith("application/outbound_port/") == true) {
    return true;
  }

  return _Visitor._findLayer(currentLayer)?.isReferenceable(importedLayer) ?? true;
}

enum _LayerEnum {
  presentation,
  application,
  domain,
  infrastructure,
  common;

  static _LayerEnum? fromRelativePath(String path) {
    final first = path.split("/").first;
    for (final layer in _LayerEnum.values) {
      if (first == layer.name) return layer;
    }
    return null;
  }
}

sealed class _Layer {
  _LayerEnum get self;
  Set<_LayerEnum> get _referenceable;

  bool isReferenceable(_LayerEnum layer) => layer == self || _referenceable.contains(layer);
}

class _Presentation extends _Layer {
  @override
  _LayerEnum get self => _LayerEnum.presentation;
  @override
  Set<_LayerEnum> get _referenceable => {
    _LayerEnum.application,
    _LayerEnum.domain,
    _LayerEnum.common,
  };
}

class _Application extends _Layer {
  @override
  _LayerEnum get self => _LayerEnum.application;
  @override
  Set<_LayerEnum> get _referenceable => {_LayerEnum.domain, _LayerEnum.common};
}

class _Domain extends _Layer {
  @override
  _LayerEnum get self => _LayerEnum.domain;
  @override
  Set<_LayerEnum> get _referenceable => {_LayerEnum.common};
}

class _Infrastructure extends _Layer {
  @override
  _LayerEnum get self => _LayerEnum.infrastructure;
  @override
  Set<_LayerEnum> get _referenceable => {_LayerEnum.domain, _LayerEnum.common};
}

class _Common extends _Layer {
  @override
  _LayerEnum get self => _LayerEnum.common;
  @override
  Set<_LayerEnum> get _referenceable => {_LayerEnum.common};
}
