import "package:analyzer_testing/analysis_rule/analysis_rule.dart";
import "package:test/test.dart";
import "package:flutter_architecture_lint/rules/avoid_reverse_layer_dependency_rule.dart";

void main() {
  group("[UnitTest] レイヤー依存のディレクティブ検査", () {
    late _DirectiveTest helper;
    setUp(() {
      helper = _DirectiveTest();
      helper.setUp();
    });

    for (final directive in ["import", "export"]) {
      test("[Negative] $directive の直接逆依存を拒否する", () async {
        await helper.check(
          directive,
          "../application/forbidden.dart",
          violates: true,
        );
      });
      test("[Negative] $directive の多段再公開経由の逆依存を拒否する", () async {
        await helper.check(directive, "../bridge.dart", violates: true);
      });
      test("[Positive] $directive の show で禁止型を除外できる", () async {
        await helper.check(
          directive,
          "../bridge.dart",
          combinator: "show Allowed",
        );
      });
      test("[Positive] $directive の hide で禁止型を除外できる", () async {
        await helper.check(
          directive,
          "../bridge.dart",
          combinator: "hide Forbidden",
        );
      });
      test("[Negative] $directive の show で選択した禁止型を拒否する", () async {
        await helper.check(
          directive,
          "../bridge.dart",
          combinator: "show Forbidden",
          violates: true,
        );
      });
      test("[Positive] $directive の再公開元の show を尊重する", () async {
        helper.newFile(
          "${helper.testPackageLibPath}/filtered.dart",
          'export "bridge.dart" show Allowed;',
        );
        await helper.check(directive, "../filtered.dart");
      });
      test("[Negative] $directive の循環する再公開でも禁止型を検出する", () async {
        helper.newFile(
          "${helper.testPackageLibPath}/cycle.dart",
          'export "bridge.dart";',
        );
        helper.newFile(
          "${helper.testPackageLibPath}/bridge.dart",
          'export "cycle.dart"; export "application/forbidden.dart";',
        );
        await helper.check(directive, "../cycle.dart", violates: true);
      });
      test("[Positive] $directive の出力側ポートの再公開を許可する", () async {
        helper.location = "infrastructure/adapter.dart";
        helper.newFile(
          "${helper.testPackageLibPath}/ports.dart",
          'export "application/outbound_port/port.dart";',
        );
        await helper.check(directive, "../ports.dart");
      });
      test("[Negative] $directive の出力側ポート経由の通常Application型を拒否する", () async {
        helper.location = "infrastructure/adapter.dart";
        helper.newFile(
          "${helper.testPackageLibPath}/application/outbound_port/barrel.dart",
          'export "../forbidden.dart";',
        );
        await helper.check(
          directive,
          "../application/outbound_port/barrel.dart",
          violates: true,
        );
      });
      test("[Negative] $directive の非選択条件分岐の直接逆依存を拒否する", () async {
        final code = '$directive "../domain/allowed.dart" if (dart.library.html) "../application/forbidden.dart";';
        await helper.assertDiagnostics("// ignore: unused_import\n$code", [
          helper.lint(25 + code.lastIndexOf('"../'), 31),
        ]);
      });
      test("[Positive] $directive のsetterをhideで除外できる", () async {
        helper.newFile(
          "${helper.testPackageLibPath}/application/forbidden.dart",
          "set forbidden(int value) {}",
        );
        await helper.check(
          directive,
          "../bridge.dart",
          combinator: "hide forbidden",
        );
      });
      test("[Negative] $directive のsetterをshowで公開すると拒否する", () async {
        helper.newFile(
          "${helper.testPackageLibPath}/application/forbidden.dart",
          "set forbidden(int value) {}",
        );
        await helper.check(
          directive,
          "../bridge.dart",
          combinator: "show forbidden",
          violates: true,
        );
      });
      test("[Positive] $directive の生成ファイルを除外する", () async {
        helper.location = "common/injector.config.dart";
        await helper.check(directive, "../application/forbidden.dart");
      });
    }
    test("[Negative] prefix付きimportの再公開型を検出する", () async {
      await helper.check(
        "import",
        "../bridge.dart",
        combinator: "as bridge",
        violates: true,
      );
    });
  });
  group("AvoidReverseLayerDependencyRule", () {
    test("プロジェクトより外の層名とパス区切りは依存判定に影響しない", () {
      for (final packageRoot in ["/work/presentation/project", r"C:\work\presentation\project"]) {
        final separator = packageRoot.contains(r"\") ? r"\" : "/";
        final path = [packageRoot, "lib", "domain", "model.dart"].join(separator);
        expect(isAllowedLayerImport(currentPath: path, importUri: "../application/use_case.dart", packageRoot: packageRoot), isFalse);
        expect(isAllowedLayerImport(currentPath: path, importUri: "model.dart", packageRoot: packageRoot), isTrue);
      }
    });

    test("[Positive] Infrastructureから通常のApplication実装への依存を拒否する", () {
      final result = isAllowedLayerImport(
        packageRoot: "/project",
        currentPath: "/project/lib/infrastructure/event/adapter.dart",
        importUri: "package:waiter/application/use_case.dart",
      );

      expect(result, isFalse);
    });

    test("[Negative] InfrastructureからApplicationの出力側ポートへの依存を許可する", () {
      final result = isAllowedLayerImport(
        packageRoot: "/project",
        currentPath: "/project/lib/infrastructure/event/adapter.dart",
        importUri: "package:waiter/application/outbound_port/domain_event_publisher.dart",
      );

      expect(result, isTrue);
    });

    test("[Negative] Applicationの結果通知用OutputPortは例外に含めない", () {
      final result = isAllowedLayerImport(
        packageRoot: "/project",
        currentPath: "/project/lib/infrastructure/event/adapter.dart",
        importUri: "package:waiter/application/output_port.dart",
      );

      expect(result, isFalse);
    });

    test("[Negative] 通常の依存方向を維持する", () {
      expect(
        isAllowedLayerImport(
          packageRoot: "/project",
          currentPath: "/project/lib/application/use_case.dart",
          importUri: "package:waiter/domain/model.dart",
        ),
        isTrue,
      );
      expect(
        isAllowedLayerImport(
          packageRoot: "/project",
          currentPath: "/project/lib/domain/model.dart",
          importUri: "package:waiter/application/use_case.dart",
        ),
        isFalse,
      );
    });
  });
}

class _DirectiveTest extends AnalysisRuleTest {
  String location = "domain/consumer.dart";

  @override
  String get testPackageRootPath => "$workspaceRootPath/project";

  @override
  String get testFileName => location;

  @override
  void setUp() {
    rule = AvoidReverseLayerDependencyRule();
    super.setUp();
    newFile(
      "$testPackageLibPath/application/forbidden.dart",
      "class Forbidden {}",
    );
    newFile("$testPackageLibPath/domain/allowed.dart", "class Allowed {}");
    newFile(
      "$testPackageLibPath/application/outbound_port/port.dart",
      "class Port {}",
    );
    newFile(
      "$testPackageLibPath/intermediate.dart",
      'export "application/forbidden.dart"; export "domain/allowed.dart";',
    );
    newFile("$testPackageLibPath/bridge.dart", 'export "intermediate.dart";');
  }

  Future<void> check(
    String directive,
    String uri, {
    String combinator = "",
    bool violates = false,
  }) async {
    final code = '// ignore: unused_import\n$directive "$uri" $combinator;';
    await assertDiagnostics(code, [
      if (violates) lint(code.indexOf('"'), uri.length + 2),
    ]);
  }
}
