import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final ndk = Platform.environment['FLASHCO_TEST_ANDROID_NDK'];
  final javaHome = Platform.environment['JAVA_HOME'];

  test(
    'Windows builds and caches the Android arm64 gomobile library',
    () async {
      final repository = p.normalize(
        p.join(Directory.current.path, '../../..'),
      );
      final android = p.join(repository, 'android');
      final temporary = Directory.systemTemp.createTempSync('gomobile test ');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final jar = p.join(javaHome!, 'bin', 'jar.exe');

      Future<ProcessResult> gradle() => Process.run(
        p.join(android, 'gradlew.bat'),
        [
          ':core:bindCore',
          '-Ptarget-platform=android-arm64',
          '--console=plain',
        ],
        workingDirectory: android,
        environment: {'ANDROID_NDK_HOME': ndk!},
        runInShell: true,
      );

      final first = await gradle();
      expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
      final output = p.join(repository, 'build', 'core', 'gomobile');
      final coreArchive = p.join(output, 'core.aar');
      final classes = await Process.run(jar, [
        'tf',
        p.join(output, 'classes.jar'),
      ]);
      expect(classes.exitCode, 0, reason: '${classes.stderr}');
      expect(
        classes.stdout,
        contains('com/follow/flashco/core/mobile/Mobile.class'),
      );

      final extracted = await Process.run(jar, [
        'xf',
        coreArchive,
        'jni/arm64-v8a/libgojni.so',
      ], workingDirectory: temporary.path);
      expect(extracted.exitCode, 0, reason: '${extracted.stderr}');
      final bytes = File(
        p.join(temporary.path, 'jni', 'arm64-v8a', 'libgojni.so'),
      ).readAsBytesSync();
      expect(bytes.take(4), [0x7f, 0x45, 0x4c, 0x46]);
      expect(ByteData.sublistView(bytes).getUint16(18, Endian.little), 183);

      final second = await gradle();
      expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
      expect(second.stdout, contains(':core:bindCore UP-TO-DATE'));
    },
    skip: !Platform.isWindows || ndk == null || javaHome == null
        ? 'Requires Windows, Go, JAVA_HOME and FLASHCO_TEST_ANDROID_NDK'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
