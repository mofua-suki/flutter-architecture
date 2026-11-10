import "dart:io";

import "package:path/path.dart" as path;

Future<void> main() async {
  final root = Directory.current;
  final workspace = await Directory.systemTemp.createTemp("architecture-mason-");
  Future<void> run(String executable, List<String> args, {String? directory}) async {
    final process = await Process.start(executable, args, workingDirectory: directory ?? workspace.path, mode: ProcessStartMode.inheritStdio);
    final code = await process.exitCode;
    if (code != 0) throw ProcessException(executable, args, "Template verification failed", code);
  }

  try {
    final listed = await Process.run("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], workingDirectory: root.path);
    if (listed.exitCode != 0) throw StateError("Cannot enumerate source files");
    for (final relative in (listed.stdout as String).split("\u0000").where((value) => value.isNotEmpty)) {
      final source = File(path.join(root.path, relative));
      if (!source.existsSync()) continue;
      final target = File(path.join(workspace.path, relative));
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }
    await run("flutter", ["pub", "get", "--enforce-lockfile"]);
    await run("dart", ["pub", "get", "--enforce-lockfile"], directory: path.join(workspace.path, "tool", "lint"));
    await run("dart", ["run", "tool/mason/generate_bloc.dart", "TemplateCheck", "template_check"]);
    await run("dart", ["run", "tool/mason/generate_use_case.dart", "FetchTemplateCheck", "query", "template_check"]);
    await run("dart", ["run", "tool/mason/generate_use_case.dart", "SaveTemplateCheck", "command", "template_check"]);
    await run("flutter", [
      "analyze",
      "--no-pub",
      "lib/presentation/bloc/template_check",
      "lib/application/template_check",
      "test/presentation/bloc/template_check",
      "test/application/template_check",
    ]);
    await run("flutter", ["test", "--no-pub", "test/presentation/bloc/template_check", "test/application/template_check"]);
  } finally {
    await workspace.delete(recursive: true);
  }
}
