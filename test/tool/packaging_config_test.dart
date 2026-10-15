import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Flashco packaging retains existing installation identities', () {
    final distribution =
        loadYaml(File('distribute_options.yaml').readAsStringSync()) as YamlMap;
    expect(distribution['app_name'], 'FlClash');
    expect(
      distribution['artifact_name'],
      startsWith('Flashco-{{build_name}}-{{platform}}'),
    );

    for (final format in ['deb', 'rpm', 'appimage']) {
      final config =
          loadYaml(
                File(
                  'linux/packaging/$format/make_config.yaml',
                ).readAsStringSync(),
              )
              as YamlMap;
      expect(config['display_name'], 'Flashco');
      expect(config['generic_name'], 'Flashco');
      if (format != 'appimage') {
        expect(config['package_name'], 'FlClash');
      }
      expect(
        config['supported_mime_type'],
        contains('x-scheme-handler/flclash'),
      );
    }

    final windows =
        loadYaml(
              File('windows/packaging/exe/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    expect(windows['display_name'], 'Flashco');
    expect(windows['app_name'], 'FlClash');
    expect(windows['app_id'], '728B3532-C74B-4870-9068-BE70FE12A3E6');
    expect(windows['executable_name'], 'FlClash.exe');
    final locales = (windows['locales'] as YamlList).cast<YamlMap>();
    expect(
      locales.map((locale) => locale['lang']),
      containsAll(['en', 'ru', 'zh']),
    );
    expect(
      locales.singleWhere((locale) => locale['lang'] == 'zh')['file'],
      r'..\windows\packaging\exe\ChineseSimplified.isl',
    );
  });

  test('Windows upgrades remove only the obsolete branding shortcuts', () {
    final script = File(
      'windows/packaging/exe/inno_setup.iss',
    ).readAsStringSync();
    final section = RegExp(
      r'\[InstallDelete\]\r?\n([\s\S]*?)(?=\r?\n\[|$)',
    ).firstMatch(script);
    expect(section, isNotNull);
    final entries = section!
        .group(1)!
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    expect(
      entries,
      unorderedEquals([
        for (final folder in ['autoprograms', 'autodesktop'])
          for (final name in ['FlClash', 'Flasho'])
            'Type: files; Name: "{$folder}\\\\$name.lnk"',
      ]),
    );
  });

  group('Linux packaging teardown', () {
    for (final format in ['deb', 'rpm']) {
      test('$format removes the Helper unit only on a real uninstall', () {
        final config =
            loadYaml(
                  File(
                    'linux/packaging/$format/make_config.yaml',
                  ).readAsStringSync(),
                )
                as YamlMap;
        final scripts = (config['postuninstall_scripts'] as YamlList)
            .cast<String>();

        expect(scripts.first, contains('exit 0'));
        expect(
          scripts,
          contains('rm -f /etc/systemd/system/flclash-helper.service'),
        );
        expect(
          scripts.any((script) => script.contains('systemctl daemon-reload')),
          isTrue,
        );
      });
    }
  });

  test('rpm keeps the Core bytes the Helper was built against', () {
    final config =
        loadYaml(
              File('linux/packaging/rpm/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    final macros = (config['spec_macros'] as YamlList).cast<String>();

    expect(macros, contains('%global debug_package %{nil}'));
    expect(macros, contains('%global __os_install_post %{nil}'));
  });
}
