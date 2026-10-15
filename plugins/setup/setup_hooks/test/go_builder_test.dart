import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/setup_hooks.dart';
import 'package:setup_hooks/src/build_cache.dart';
import 'package:setup_hooks/src/go_builder.dart';
import 'package:setup_hooks/src/options.dart';
import 'package:test/test.dart';

void main() {
  final ndk = Platform.environment['FLCLASH_TEST_ANDROID_NDK'];

  for (final target in Target.forPlatform('android')) {
    test(
      'Windows builds and caches an Android ${target.abi} CGO library',
      () async {
        final root = Directory.systemTemp.createTempSync('go android test ');
        addTearDown(() => root.deleteSync(recursive: true));
        final core = Directory(p.join(root.path, 'core'))..createSync();
        File(
          p.join(core.path, 'go.mod'),
        ).writeAsStringSync('module android_build_test\n\ngo 1.24\n');
        File(p.join(core.path, 'main.go')).writeAsStringSync('''
package main

/*
#include <stdbool.h>
static bool enabled(void) { return true; }
*/
import "C"

//export Enabled
func Enabled() C.bool { return C.enabled() }

func main() {}
''');
        final builder = GoBuilder(
          rootDir: root.path,
          config: BuildConfig.load(rootDir: root.path),
          cache: BuildCache(rootDir: root.path),
          notice: BuildNotice(),
          androidToolchain: AndroidToolchain(
            clangDirectory: p.join(
              ndk!,
              'toolchains',
              'llvm',
              'prebuilt',
              'windows-x86_64',
              'bin',
            ),
            apiLevel: 24,
          ),
        );

        final first = await builder.build(target);
        expect(first.rebuilt, isTrue);
        final bytes = File(first.primaryOutput).readAsBytesSync();
        expect(bytes.take(4), [0x7f, 0x45, 0x4c, 0x46]);
        final machine = ByteData.sublistView(
          bytes,
        ).getUint16(18, Endian.little);
        expect(machine, switch (target.goarch) {
          'arm' => 40,
          'arm64' => 183,
          'amd64' => 62,
          _ => throw StateError('Unexpected Android architecture'),
        });
        expect(
          File(
            p.join(
              root.path,
              'android',
              'core',
              'src',
              'main',
              'jniLibs',
              target.abi!,
              'libclash.so',
            ),
          ).readAsBytesSync(),
          bytes,
        );
        expect((await builder.build(target)).rebuilt, isFalse);
      },
      skip: !Platform.isWindows || ndk == null
          ? 'Requires Windows, Go and FLCLASH_TEST_ANDROID_NDK'
          : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
