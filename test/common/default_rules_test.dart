import 'package:fl_clash/common/default_rules.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/clash_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the approved catalogue has 20 services and 74 unique domains', () {
    expect(russianServiceDomains, hasLength(20));
    final domains = russianServiceDomains.values.expand((domains) => domains);
    expect(domains, hasLength(74));
    expect(domains.toSet(), hasLength(74));
    expect(
      russianServiceDomains.values.every((domains) => domains.isNotEmpty),
      isTrue,
    );
  });

  test('every preset rule is a direct domain suffix without extra options', () {
    for (final raw in russianServiceDirectRules) {
      final rule = Rule.parse(raw);
      expect(rule.ruleAction, RuleAction.DOMAIN_SUFFIX);
      expect(rule.ruleTarget, 'DIRECT');
      expect(rule.rawValue, raw);
      expect(rule.noResolve, isFalse);
      expect(rule.src, isFalse);
      expect(rule.ruleProvider, isNull);
      expect(rule.subRule, isNull);
    }
  });

  test('the catalogue avoids broad country exclusions', () {
    final domainPattern = RegExp(
      r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$',
    );
    final domains = russianServiceDomains.values.expand((domains) => domains);
    for (final domain in domains) {
      expect(domainPattern.hasMatch(domain), isTrue, reason: domain);
      expect(domain, isNot(anyOf('ru', 'su', 'com', 'net', 'yandex')));
    }
  });
}
