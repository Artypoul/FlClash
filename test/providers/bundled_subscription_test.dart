import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flashco/common/common.dart';
import 'package:flashco/core/controller.dart';
import 'package:flashco/core/interface.dart';
import 'package:flashco/database/database.dart' as db;
import 'package:flashco/enum/enum.dart';
import 'package:flashco/l10n/l10n.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/providers.dart';
import 'package:flashco/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Core extends Mock implements CoreHandlerInterface {}

class _Preferences extends Mock implements SharedPreferences {}

class _RealHttp extends HttpOverrides {}

class _Setup extends SetupAction {
  final started = <int?>[];
  Object? _token;
  @override
  Object? get runRequestToken => _token;
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    _token = Object();
    if (running) started.add(ref.read(currentProfileIdProvider));
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late Directory home;
  late HttpServer server;
  late db.Database database;
  late ProviderContainer container;
  late _Core core;
  late _Setup setup;
  late String url;
  var requests = 0;
  var status = HttpStatus.ok;
  var safeMode = false;
  Completer<void>? held;
  late Completer<void> downloadStarted;

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    home = await Directory.systemTemp.createTemp('flashco-bundled-');
    AppPath.supportDirectory = () async => home;
    AppPath.temporaryDirectory = () async => home;
    AppPath.cacheDirectory = () async => home;
    globalState.packageInfo = PackageInfo(
      appName: 'Flashco',
      packageName: 'com.follow.flashco',
      version: '0.9.0',
      buildNumber: '1',
    );
    HttpOverrides.global = _RealHttp();
  });
  tearDownAll(() async => home.delete(recursive: true));

  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    database = db.Database(NativeDatabase.memory());
    db.database = database;
    requests = 0;
    status = HttpStatus.ok;
    safeMode = false;
    held = null;
    downloadStarted = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/subscription';
    server.listen((request) async {
      requests++;
      if (!downloadStarted.isCompleted) downloadStarted.complete();
      await held?.future;
      request.response.statusCode = status;
      request.response.write('proxies: []\n');
      await request.response.close();
    });
    core = _Core();
    when(() => core.validateConfig(any())).thenAnswer((_) async => '');
    when(() => core.clearEffect(any())).thenAnswer((_) async => '');
    when(
      () => core.getProfileGroupReferences(any()),
    ).thenAnswer((_) async => []);
    setup = _Setup();
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(() => setup),
        safeModeProvider.overrideWith((_) => safeMode),
      ],
    );
    globalState.container = container;
    container.listen(initProvider, (_, _) {});
    container.listen(coreStatusProvider, (_, _) {});
    container.listen(currentProfileIdProvider, (_, _) {});
    container.listen(profilesProvider, (_, _) {});
    container.read(initProvider.notifier).value = true;
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await pumpEventQueue();
  });
  tearDown(() async {
    container.dispose();
    await server.close(force: true);
    await database.close();
  });

  ProfilesAction action() => container.read(profilesActionProvider.notifier);

  test(
    'first launch saves a normal URL profile, selects it and starts it',
    () async {
      final page = container.read(currentPageLabelProvider);
      await action().importBundledSubscription(url);

      final profile = (await database.profilesDao.query().get()).single;
      expect(profile.url, url);
      expect(profile.type, ProfileType.url);
      expect(profile.autoUpdate, isTrue);
      expect(container.read(currentProfileIdProvider), profile.id);
      expect(setup.started, [profile.id]);
      expect(container.read(currentPageLabelProvider), page);
      expect(await preferences.wasBundledSubscriptionImported(url), isTrue);
    },
  );

  test('later launches and deletion do not reimport or reconnect', () async {
    await action().importBundledSubscription(url);
    final profile = container.read(profilesProvider).single;
    await (database.delete(
      database.profiles,
    )..where((row) => row.id.equals(profile.id))).go();
    await pumpEventQueue();
    await action().importBundledSubscription(url);

    expect(requests, 1);
    expect(setup.started, hasLength(1));
    expect(await database.profilesDao.query().get(), isEmpty);
  });

  test('a matching saved subscription is not duplicated or started', () async {
    final existing = Profile.normal(url: url);
    container.read(profilesProvider.notifier).put(existing);
    await pumpEventQueue();
    await action().importBundledSubscription(url);

    expect(requests, 0);
    expect((await database.profilesDao.query().get()).single.id, existing.id);
    expect(setup.started, isEmpty);
    expect(await preferences.wasBundledSubscriptionImported(url), isTrue);
  });

  test('a failed download can be retried on the next launch', () async {
    status = HttpStatus.serviceUnavailable;
    await action().importBundledSubscription(url);
    expect(await preferences.wasBundledSubscriptionImported(url), isFalse);
    expect(await database.profilesDao.query().get(), isEmpty);
    status = HttpStatus.ok;
    await action().importBundledSubscription(url);
    expect(requests, 2);
    expect(await database.profilesDao.query().get(), hasLength(1));
    expect(setup.started, hasLength(1));
  });

  test('concurrent first-launch calls share one import', () async {
    held = Completer<void>();
    final first = action().importBundledSubscription(url);
    final second = action().importBundledSubscription(url);
    await pumpEventQueue();
    held!.complete();
    await Future.wait([first, second]);
    expect(requests, 1);
    expect(await database.profilesDao.query().get(), hasLength(1));
    expect(setup.started, hasLength(1));
  });

  test('uninitialized and disconnected startup never imports', () async {
    container.read(initProvider.notifier).value = false;
    await action().importBundledSubscription(url);
    container.read(initProvider.notifier).value = true;
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await action().importBundledSubscription(url);
    expect(requests, 0);
    expect(setup.started, isEmpty);
  });

  test('safe mode never imports or records a completed subscription', () async {
    safeMode = true;
    await action().importBundledSubscription(url);
    expect(requests, 0);
    expect(await preferences.wasBundledSubscriptionImported(url), isFalse);
  });

  test('generic builds and invalid build inputs do not add profiles', () async {
    await action().importBundledSubscription('');
    await action().importBundledSubscription('not a subscription URL');
    expect(requests, 0);
    expect(await database.profilesDao.query().get(), isEmpty);
  });

  test('an unavailable preferences store does not import repeatedly', () async {
    final previous = preferences.sharedPreferencesCompleter;
    preferences.sharedPreferencesCompleter = Completer()..complete(null);
    try {
      await action().importBundledSubscription(url);
      expect(requests, 0);
    } finally {
      preferences.sharedPreferencesCompleter = previous;
    }
  });

  test(
    'a stop during preference loading prevents the initial automatic import',
    () async {
      final previous = preferences.sharedPreferencesCompleter;
      final pending = Completer<SharedPreferences?>();
      preferences.sharedPreferencesCompleter = pending;
      try {
        final importing = action().importBundledSubscription(url);
        await container.read(setupActionProvider.notifier).setRunning(false);
        pending.complete(await SharedPreferences.getInstance());
        await importing;
        expect(requests, 0);
        expect(setup.started, isEmpty);
      } finally {
        preferences.sharedPreferencesCompleter = previous;
      }
    },
  );

  test(
    'a later stop preserves the profile without automatically connecting',
    () async {
      held = Completer<void>();
      final importing = action().importBundledSubscription(url);
      await downloadStarted.future;
      await container.read(setupActionProvider.notifier).setRunning(false);
      held!.complete();
      await importing;
      expect(await database.profilesDao.query().get(), hasLength(1));
      expect(await preferences.wasBundledSubscriptionImported(url), isTrue);
      expect(setup.started, isEmpty);
    },
  );

  test(
    'a failed database save is not marked complete and can be retried',
    () async {
      await database.customStatement(
        "CREATE TRIGGER fail_profile BEFORE INSERT ON profiles BEGIN SELECT RAISE(FAIL, 'write failed'); END",
      );
      await action().importBundledSubscription(url);
      expect(await preferences.wasBundledSubscriptionImported(url), isFalse);
      expect(await database.profilesDao.query().get(), isEmpty);
      expect(setup.started, isEmpty);
      await database.customStatement('DROP TRIGGER fail_profile');
      await action().importBundledSubscription(url);
      expect(await database.profilesDao.query().get(), hasLength(1));
      expect(setup.started, hasLength(1));
    },
  );

  test('a failed manual import save does not start a missing profile', () async {
    await database.customStatement(
      "CREATE TRIGGER fail_profile BEFORE INSERT ON profiles BEGIN SELECT RAISE(FAIL, 'write failed'); END",
    );

    await action().addProfileFromLink(url);
    await container.read(profilesProvider.notifier).settledWrites;
    await pumpEventQueue();

    expect(await database.profilesDao.query().get(), isEmpty);
    expect(setup.started, isEmpty);
  });

  test('deletion during the marker save prevents activation', () async {
    final existing = Profile.normal(url: 'https://example.invalid/existing');
    action().putProfile(existing);
    await container.read(profilesProvider.notifier).settledWrites;
    final store = _Preferences();
    final saving = Completer<void>();
    final release = Completer<void>();
    when(() => store.getBool(any())).thenReturn(false);
    when(() => store.setBool(any(), true)).thenAnswer((_) async {
      saving.complete();
      await release.future;
      return true;
    });
    final previous = preferences.sharedPreferencesCompleter;
    preferences.sharedPreferencesCompleter = Completer()..complete(store);
    try {
      final importing = action().importBundledSubscription(url);
      await saving.future;
      final imported = container
          .read(profilesProvider)
          .singleWhere((profile) => profile.url == url);
      await action().deleteProfile(imported.id);
      release.complete();
      await importing;
      expect(container.read(currentProfileIdProvider), existing.id);
      expect(setup.started, isEmpty);
    } finally {
      preferences.sharedPreferencesCompleter = previous;
    }
  });

  test(
    'other profiles keep their data when the bundled subscription is added',
    () async {
      final existing = Profile.normal(
        url: 'https://example.invalid/existing',
      ).copyWith(selectedMap: {'PROXY': 'Manual'});
      container.read(profilesProvider.notifier).put(existing);
      await container.read(profilesProvider.notifier).settledWrites;
      await action().importBundledSubscription(url);
      final profiles = await database.profilesDao.query().get();
      expect(profiles, hasLength(2));
      expect(profiles.getProfile(existing.id)!.selectedMap, {
        'PROXY': 'Manual',
      });
      expect(setup.started.single, isNot(existing.id));
    },
  );
}
