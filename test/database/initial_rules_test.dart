import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flashco/common/default_rules.dart';
import 'package:flashco/database/database.dart';
import 'package:flashco/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _FailingInitialDatabase extends Database {
  _FailingInitialDatabase(super.executor);

  @override
  Future<void> batch(FutureOr<void> Function(Batch batch) runInBatch) {
    return super.batch((batch) async {
      await runInBatch(batch);
      batch.customStatement('INSERT INTO rules (rule_action) VALUES (NULL)');
    });
  }
}

void main() {
  late sqlite.Database raw;
  final connections = <Database>[];
  const initialRules = [
    'DOMAIN-SUFFIX,first.example,DIRECT',
    'DOMAIN-SUFFIX,second.example,DIRECT',
  ];

  Future<Database> open([List<String> rules = const []]) async {
    final database = Database(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    connections.add(database);
    await database.initializeNewInstallationRules(rules);
    return database;
  }

  Future<void> close(Database database) async {
    connections.remove(database);
    await database.close();
  }

  setUp(() {
    raw = sqlite.sqlite3.openInMemory();
  });

  tearDown(() async {
    for (final database in connections.reversed) {
      await database.close();
    }
    connections.clear();
    raw.close();
  });

  test('a new database stores ordered global rules', () async {
    final database = await open(initialRules);
    final rules = await database.rulesDao.queryGlobalRules().get();

    expect(rules.map((rule) => rule.rawValue), initialRules);
    expect(rules.map((rule) => rule.id).toSet(), hasLength(2));
    final orders = rules.map((rule) => rule.order!).toList();
    expect(orders, orderedEquals([...orders]..sort()));
    expect(orders.toSet(), hasLength(2));
    final storedRules = await database.select(database.rules).get();
    expect(storedRules, hasLength(2));
    expect(storedRules.every((rule) => rule.profileId == null), isTrue);
    expect(
      await database.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
    expect(database.schemaVersion, 20);
  });

  test('new installations include the editable ru bypass rule', () async {
    final database = await open(russianServiceDirectRules);
    final rules = await database.rulesDao.queryGlobalRules().get();
    expect(rules.map((rule) => rule.rawValue), russianServiceDirectRules);
    final ruBypass = rules.singleWhere(
      (rule) => rule.rawValue == 'DOMAIN-SUFFIX,ru,DIRECT',
    );
    final edited = ruBypass.copyWith(ruleTarget: 'REJECT');
    await database.rulesDao.putRule(edited);

    expect(
      (await database.rulesDao.queryGlobalRules().get()).singleWhere(
        (rule) => rule.id == ruBypass.id,
      ),
      edited,
    );
  });

  test('a failed initial insert rolls back and can be retried', () async {
    final failing = _FailingInitialDatabase(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    connections.add(failing);

    await expectLater(
      failing.initializeNewInstallationRules(initialRules),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(raw.select('PRAGMA user_version').single['user_version'], 0);
    expect(
      raw.select("SELECT name FROM sqlite_master WHERE name = 'rules'"),
      isEmpty,
    );
    await close(failing);

    final database = await open(initialRules);
    final rules = await database.rulesDao.queryGlobalRules().get();
    expect(rules.map((rule) => rule.rawValue), initialRules);
  });

  test('opening again preserves edits and deletions', () async {
    var database = await open(initialRules);
    final rules = await database.rulesDao.queryGlobalRules().get();
    final edited = rules.first.copyWith(content: 'edited.example');
    await database.rulesDao.putRule(edited);
    await database.rulesDao.delRules([rules.last.id]);
    await close(database);

    database = await open(initialRules);
    expect(await database.rulesDao.queryGlobalRules().get(), [edited]);
  });

  test('an existing database never receives the initial catalogue', () async {
    var database = await open();
    const userRule = Rule(id: 1, content: 'user.example', ruleTarget: 'DIRECT');
    await database.rulesDao.putRule(userRule);
    await close(database);

    database = await open(initialRules);
    expect(await database.rulesDao.queryGlobalRules().get(), [userRule]);
  });

  test('an existing empty database is not seeded', () async {
    var database = await open();
    await database.customSelect('SELECT 1').get();
    await close(database);

    database = await open(initialRules);
    expect(await database.rulesDao.queryGlobalRules().get(), isEmpty);
  });

  test('an upgrade does not insert initial rules', () async {
    var database = await open();
    await database.customSelect('SELECT 1').get();
    await close(database);
    raw.execute('PRAGMA user_version = 19');

    database = await open(initialRules);
    expect(await database.rulesDao.queryGlobalRules().get(), isEmpty);
    expect(raw.select('PRAGMA user_version').single['user_version'], 20);
  });

  test(
    'initial rules use the existing per-profile disable mechanism',
    () async {
      final database = await open(initialRules);
      const profile = Profile(id: 1, autoUpdateDuration: Duration.zero);
      await database.profilesDao.putAll([profile.toCompanion()]);
      final rules = await database.rulesDao.queryGlobalRules().get();
      await database.rulesDao.putDisabled(profile.id, rules.first.id);

      expect(await database.rulesDao.queryAddedRules(profile.id).get(), [
        rules.last,
      ]);
      expect(await database.rulesDao.queryGlobalRules().get(), rules);
    },
  );

  test('the catalogue is captured before the database opens', () async {
    final input = [...initialRules];
    final opening = open(input);
    input.clear();
    final database = await opening;

    final rules = await database.rulesDao.queryGlobalRules().get();
    expect(rules.map((rule) => rule.rawValue), initialRules);
  });
}
