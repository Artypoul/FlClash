import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'Helper selects the pinned Rust without a shell toolchain override',
    () async {
      final repository = p.normalize(
        p.join(Directory.current.path, '../../..'),
      );
      final nativePin = File(
        p.join(repository, 'plugins/rust_api/rust/rust-toolchain.toml'),
      ).readAsStringSync();
      final channel = RegExp(
        r'^channel\s*=\s*"([^"]+)"',
        multiLine: true,
      ).firstMatch(nativePin)!.group(1)!;
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('RUSTUP_TOOLCHAIN')
        ..remove('CARGO_HOME')
        ..remove('RUSTUP_HOME');
      final result = await Process.run(
        'rustc',
        ['--version'],
        workingDirectory: p.join(repository, 'services/helper'),
        environment: environment,
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, startsWith('rustc $channel '));
    },
    skip: Platform.environment['FLASHCO_TEST_TOOLCHAINS'] != 'true'
        ? 'Requires the pinned Rust toolchain installed'
        : false,
  );
}
