import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Flashco packaging uses an independent installation identity', () {
    final distribution =
        loadYaml(File('distribute_options.yaml').readAsStringSync()) as YamlMap;
    expect(distribution['app_name'], 'Flashco');
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
        expect(config['package_name'], 'Flashco');
      }
      expect(
        config['supported_mime_type'],
        contains('x-scheme-handler/flashco'),
      );
    }

    final windows =
        loadYaml(
              File('windows/packaging/exe/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    expect(windows['display_name'], 'Flashco');
    expect(windows['app_name'], 'Flashco');
    expect(windows['app_id'], '2E1E050C-79CA-52FB-82C4-52FDC3F5D780');
    expect(windows['executable_name'], 'Flashco.exe');
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

  test('Flashco installation leaves other clients shortcuts intact', () {
    final script = File(
      'windows/packaging/exe/inno_setup.iss',
    ).readAsStringSync();
    expect(script, isNot(contains('[InstallDelete]')));
    expect(script, isNot(contains('FlClash.lnk')));
    expect(script, isNot(contains('Flasho.lnk')));
    expect(script, isNot(contains('FlClashHelperService')));
  });

  group('Windows installer process and Helper guards', () {
    late String script;

    setUp(() {
      script = File('windows/packaging/exe/inno_setup.iss').readAsStringSync();
    });

    test('keeps the Windows identity and prevents automatic app closing', () {
      final windows =
          loadYaml(
                File(
                  'windows/packaging/exe/make_config.yaml',
                ).readAsStringSync(),
              )
              as YamlMap;
      final runner = File('windows/runner/Runner.rc').readAsStringSync();

      expect(windows['app_id'], '2E1E050C-79CA-52FB-82C4-52FDC3F5D780');
      expect(runner, contains('VALUE "CompanyName", "com.follow"'));
      expect(runner, contains('VALUE "ProductName", "Flashco"'));
      expect(script, contains('CloseApplications=no'));
    });

    test('does not terminate processes globally by executable name', () {
      expect(script.toLowerCase(), isNot(contains('taskkill')));
      expect(script.toLowerCase(), isNot(contains('/f /im')));
      expect(script, contains('function HasRunningInstalledApp(): Boolean;'));
    });

    test(
      'guards install and uninstall with process and Helper ownership checks',
      () {
        expect(
          script,
          contains('function HelperOwnershipConflict(): Boolean;'),
        );
        expect(
          script,
          contains(
            'function StopInstalledHelper(var FailureMessage: String): Boolean;',
          ),
        );
        expect(
          script,
          contains(
            'function PrepareToInstall(var NeedsRestart: Boolean): String;',
          ),
        );
        expect(script, contains('function InitializeUninstall(): Boolean;'));
        expect(script, contains('ConnectServer'));
        expect(script, contains('Win32_Process'));
        expect(script, contains('Win32_Service'));
        expect(script, contains('PathName'));
        expect(script, contains('SameText'));
        expect(script, contains('ExpandFileName'));
        expect(script, contains('Exec('));
        expect(script, contains('ResultCode'));
      },
    );

    test('reports stale proxy cleanup failures after file installation', () {
      expect(script, contains('CurStep = ssPostInstall'));
      expect(script, contains('--clear-stale-proxy'));
      expect(script, contains('Log('));
      expect(script, contains('mbError'));
      expect(script, contains('SetupLogging=yes'));
      expect(script, contains('PartialPostInstallFailure'));
      expect(script, contains('GetCustomSetupExitCode'));
      expect(script, contains('Result := 9;'));
      expect(script, contains('WizardForm.FinishedHeadingLabel.Caption'));
      expect(script, contains('WizardForm.FinishedLabel.Caption'));
      expect(script, contains('ShouldLaunchAfterInstall'));

      final runSection = script.substring(script.indexOf('[Run]'));
      expect(runSection, contains('Check: ShouldLaunchAfterInstall'));
      final postInstallHandler = script.substring(
        script.indexOf('procedure CurStepChanged(CurStep: TSetupStep);'),
        script.indexOf('procedure CurPageChanged(CurPageID: Integer);'),
      );
      expect(postInstallHandler, contains('PartialPostInstallFailure := True'));
      expect(postInstallHandler, isNot(contains('MsgBox(')));
    });

    test('preserves user data during install and uninstall', () {
      expect(script, isNot(contains('[InstallDelete]')));
      expect(script, isNot(contains('[UninstallDelete]')));
      expect(script.toLowerCase(), isNot(contains('deletefile')));
    });
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
          contains('rm -f /etc/systemd/system/flashco-helper.service'),
        );
        expect(
          scripts.any((script) => script.contains('systemctl daemon-reload')),
          isTrue,
        );
      });
    }
  });

  test('every Linux package names the GTK application id as its window '
      'class', () {
    final applicationId = RegExp(
      r'set\(APPLICATION_ID "([^"]+)"\)',
    ).firstMatch(File('linux/CMakeLists.txt').readAsStringSync())!.group(1);

    for (final format in ['deb', 'rpm', 'appimage']) {
      final config =
          loadYaml(
                File(
                  'linux/packaging/$format/make_config.yaml',
                ).readAsStringSync(),
              )
              as YamlMap;
      expect(config['startup_wm_class'], applicationId, reason: format);
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
