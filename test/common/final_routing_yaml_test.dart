import 'package:flashco/common/default_rules.dart';
import 'package:flashco/common/task.dart';
import 'package:flashco/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'generated subscription YAML keeps Russian direct rules before MATCH',
    () async {
      final result = await makeRealProfileTask(
        MakeRealProfileState(
          profilesPath: '/profiles',
          profileId: 1,
          rawConfig: {
            'rules': ['MATCH,PROXY'],
          },
          realPatchConfig: const PatchClashConfig(),
          appendSystemDns: false,
          proxyGroups: const [],
          rules: const [],
          addedRules: [
            for (final raw in russianServiceDirectRules) Rule.parse(raw),
          ],
          defaultUA: 'Flashco-Test',
        ),
      );
      final config = loadYaml(result.yaml) as YamlMap;
      final rules = (config['rules'] as YamlList).cast<String>();

      expect(
        rules.take(russianServiceDirectRules.length),
        russianServiceDirectRules,
      );
      expect(
        rules.indexOf('DOMAIN-SUFFIX,yandex.ru,DIRECT'),
        lessThan(rules.indexOf('MATCH,PROXY')),
      );
      expect(rules.last, 'MATCH,PROXY');
    },
  );
}
