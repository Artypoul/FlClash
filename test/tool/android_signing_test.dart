import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _environmentNames = <String>[
  'ANDROID_KEYSTORE_BASE64',
  'ANDROID_STORE_PASSWORD',
  'ANDROID_KEY_ALIAS',
  'ANDROID_KEY_PASSWORD',
];

void main() {
  late Directory temporaryDirectory;
  late Directory androidDirectory;
  late Directory appDirectory;
  late File localProperties;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'android-signing-test-',
    );
    temporaryTestDirectory = temporaryDirectory;
    androidDirectory = Directory('${temporaryDirectory.path}/android');
    appDirectory = Directory('${androidDirectory.path}/app');
    await appDirectory.create(recursive: true);
    localProperties = File('${androidDirectory.path}/local.properties');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('requires every signing value and leaves no partial files', () async {
    for (final missingName in _environmentNames) {
      final values = <String, String>{
        for (final name in _environmentNames) name: 'dummy value',
      }..[missingName] = '';
      final result = await _runPreparer(values);

      expect(result.exitCode, isNot(0), reason: missingName);
      expect(_stdout(result), isEmpty, reason: missingName);
      expect(
        _stderr(result),
        'Missing required Android signing environment variables.\n',
      );
      expect(await File('${appDirectory.path}/keystore.jks').exists(), isFalse);
      expect(await localProperties.exists(), isFalse);
    }
  });

  test(
    'writes the keystore and Java-escaped properties while preserving SDK paths',
    () async {
      await localProperties.writeAsString(
        'sdk.dir=D:\\\\Android SDK\\\\platform\\\\sdk\n'
        'flutter.sdk=D:\\\\Flutter\n',
      );
      const password = 'space \\=:\u03bb\nnext line';
      const keyPassword = 'another \\=:\u03b2\nline';
      final values = <String, String>{
        'ANDROID_KEYSTORE_BASE64': base64Encode(<int>[1, 2, 3, 4]),
        'ANDROID_STORE_PASSWORD': password,
        'ANDROID_KEY_ALIAS': 'release alias',
        'ANDROID_KEY_PASSWORD': keyPassword,
      };

      final result = await _runPreparer(values);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(_stdout(result), 'Android signing material prepared.\n');
      expect(
        await File('${appDirectory.path}/keystore.jks').readAsBytes(),
        <int>[1, 2, 3, 4],
      );
      expect(await _readProperties(localProperties), <String, String>{
        'sdk.dir': r'D:\Android SDK\platform\sdk',
        'flutter.sdk': r'D:\Flutter',
        'storePassword': password,
        'keyAlias': 'release alias',
        'keyPassword': keyPassword,
      });
    },
  );

  test('rejects malformed base64 without creating signing files', () async {
    final result = await _runPreparer(<String, String>{
      'ANDROID_KEYSTORE_BASE64': '!invalid!',
      'ANDROID_STORE_PASSWORD': 'dummy password',
      'ANDROID_KEY_ALIAS': 'dummy alias',
      'ANDROID_KEY_PASSWORD': 'dummy password',
    });

    expect(result.exitCode, isNot(0));
    expect(_stdout(result), isEmpty);
    expect(_stderr(result), 'Invalid Android keystore data.\n');
    expect(await File('${appDirectory.path}/keystore.jks').exists(), isFalse);
    expect(await localProperties.exists(), isFalse);
  });

  test('does not overwrite an existing keystore', () async {
    final keystore = File('${appDirectory.path}/keystore.jks');
    await keystore.writeAsBytes(<int>[9, 8, 7]);
    await localProperties.writeAsString('sdk.dir=existing\n');

    final result = await _runPreparer(<String, String>{
      'ANDROID_KEYSTORE_BASE64': base64Encode(<int>[1, 2, 3]),
      'ANDROID_STORE_PASSWORD': 'dummy password',
      'ANDROID_KEY_ALIAS': 'dummy alias',
      'ANDROID_KEY_PASSWORD': 'dummy password',
    });

    expect(result.exitCode, isNot(0));
    expect(_stdout(result), isEmpty);
    expect(_stderr(result), 'Android keystore already exists.\n');
    expect(await keystore.readAsBytes(), <int>[9, 8, 7]);
    expect(await localProperties.readAsString(), 'sdk.dir=existing\n');
  });

  test(
    'does not leave a keystore when existing properties cannot be loaded',
    () async {
      await localProperties.writeAsString('broken=\\uZZZZ\n');

      final result = await _runPreparer(<String, String>{
        'ANDROID_KEYSTORE_BASE64': base64Encode(<int>[1, 2, 3]),
        'ANDROID_STORE_PASSWORD': 'dummy password',
        'ANDROID_KEY_ALIAS': 'dummy alias',
        'ANDROID_KEY_PASSWORD': 'dummy password',
      });

      expect(result.exitCode, isNot(0));
      expect(_stdout(result), isEmpty);
      expect(_stderr(result), 'Unable to prepare Android signing material.\n');
      expect(await File('${appDirectory.path}/keystore.jks').exists(), isFalse);
      expect(await localProperties.readAsString(), 'broken=\\uZZZZ\n');
    },
  );

  test('does not expose supplied values in diagnostics', () async {
    const dummySecret = 'dummy-only-secret-do-not-print';
    final result = await _runPreparer(<String, String>{
      'ANDROID_KEYSTORE_BASE64': '!invalid!',
      'ANDROID_STORE_PASSWORD': dummySecret,
      'ANDROID_KEY_ALIAS': 'dummy alias',
      'ANDROID_KEY_PASSWORD': dummySecret,
    });

    expect(_stdout(result), isEmpty);
    expect(_stderr(result), isNot(contains(dummySecret)));
  });
}

Future<ProcessResult> _runPreparer(Map<String, String> values) {
  final source = File(
    '${Directory.current.path}/tool/PrepareAndroidSigning.java',
  );
  return () async {
    if (await source.exists()) {
      await source.copy(
        '${temporaryTestDirectory.path}/PrepareAndroidSigning.java',
      );
    }
    return Process.run(
      'java',
      const <String>['PrepareAndroidSigning.java'],
      workingDirectory: temporaryTestDirectory.path,
      environment: values,
    );
  }();
}

late Directory temporaryTestDirectory;

String _stdout(ProcessResult result) =>
    (result.stdout as String).replaceAll('\r\n', '\n');

String _stderr(ProcessResult result) =>
    (result.stderr as String).replaceAll('\r\n', '\n');

Future<Map<String, String>> _readProperties(File propertiesFile) async {
  final sourceFile = File('${temporaryTestDirectory.path}/ReadProperties.java');
  await sourceFile.writeAsString('''
import java.io.FileInputStream;
import java.util.Base64;
import java.util.Properties;

class ReadProperties {
  public static void main(String[] args) throws Exception {
    Properties properties = new Properties();
    try (FileInputStream input = new FileInputStream(args[0])) {
      properties.load(input);
    }
    for (String key : new String[] {"sdk.dir", "flutter.sdk", "storePassword", "keyAlias", "keyPassword"}) {
      String value = properties.getProperty(key, "");
      System.out.println(key + "=" + Base64.getEncoder().encodeToString(value.getBytes("UTF-8")));
    }
  }
}
''');
  final result = await Process.run('java', <String>[
    'ReadProperties.java',
    propertiesFile.path,
  ], workingDirectory: temporaryTestDirectory.path);
  expect(result.exitCode, 0, reason: result.stderr as String);
  return Map<String, String>.fromEntries(
    (result.stdout as String).replaceAll('\r', '').trim().split('\n').map((
      line,
    ) {
      final separator = line.indexOf('=');
      return MapEntry(
        line.substring(0, separator),
        utf8.decode(base64Decode(line.substring(separator + 1))),
      );
    }),
  );
}
