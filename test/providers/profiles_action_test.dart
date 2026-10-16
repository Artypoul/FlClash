import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flashco/common/common.dart';
import 'package:flashco/core/controller.dart';
import 'package:flashco/core/interface.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/l10n/l10n.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/action.dart';
import 'package:flashco/providers/app.dart';
import 'package:flashco/providers/config.dart';
import 'package:flashco/providers/core.dart';
import 'package:flashco/providers/database.dart';
import 'package:flashco/providers/state.dart';
import 'package:flashco/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yaml/yaml.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

class _RealHttpOverrides extends HttpOverrides {}

List<Group> _fixtureGroupReferences(Map config) {
  final rawGroups = config['proxy-groups'] as List? ?? const [];
  final groups = [
    for (final raw in rawGroups)
      Group(
        name: raw['name'] as String,
        type: GroupType.parse(raw['type'] as String),
        all: [
          for (final member in raw['proxies'] as List? ?? const [])
            if (rawGroups.any((group) => group['name'] == member))
              Proxy(name: member as String, type: 'URLTest'),
        ],
      ),
  ];
  return [
    ...groups,
    Group(
      name: 'GLOBAL',
      type: GroupType.Selector,
      all: [
        for (final group in groups)
          Proxy(name: group.name, type: group.type.value),
      ],
    ),
  ];
}

class _TestFilePicker extends FilePickerPlatform {
  PlatformFile? selected;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => selected;
}

base class _TestPlatformFile extends PlatformFile {
  _TestPlatformFile(this.bytes);

  final Uint8List bytes;

  @override
  String get name => 'config.yaml';
  @override
  Uri get uri => Uri.dataFromBytes(bytes);
  @override
  XFile get xFile => XFile.fromData(bytes, name: name);
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _ImportSetupAction extends SetupAction {
  final requests = <({int? profileId, bool running, bool initialize})>[];
  final selectionsAtStart = <Map<String, String>>[];
  Object? _token;

  @override
  Object? get runRequestToken => _token;

  @override
  void build() {}

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    _token = Object();
    if (running) {
      selectionsAtStart.add(
        ref.read(currentProfileProvider)?.selectedMap ?? {},
      );
    }
    requests.add((
      profileId: ref.read(currentProfileIdProvider),
      running: running,
      initialize: initialize,
    ));
    ref.read(runTimeProvider.notifier).value = running ? 0 : null;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late _MockCoreHandlerInterface core;
  late ProviderContainer container;
  late _ImportSetupAction setup;

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    home = Directory.systemTemp.createTempSync('flashco-profiles-action-');
    AppPath.supportDirectory = () async => home;
    AppPath.temporaryDirectory = () async => home;
    AppPath.cacheDirectory = () async => home;
    AppPath.downloadDirectory = () async => home;
    globalState.packageInfo = PackageInfo(
      appName: 'Flashco',
      packageName: 'com.follow.flashco',
      version: '0.9.0',
      buildNumber: '2026101401',
    );
  });

  tearDownAll(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  setUp(() {
    core = _MockCoreHandlerInterface();
    when(() => core.validateConfig(any())).thenAnswer((_) async => '');
    when(() => core.getProfileGroupReferences(any())).thenAnswer((
      invocation,
    ) async {
      final path = invocation.positionalArguments.single as String;
      return _fixtureGroupReferences(
        loadPlainYaml(await File(path).readAsString()) as Map,
      );
    });
    setup = _ImportSetupAction();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(() => setup),
      ],
    );
    addTearDown(container.dispose);
    container.listen(currentProfileIdProvider, (_, _) {});
    container.listen(initProvider, (_, _) {});
    container.listen(runTimeProvider, (_, _) {});
    globalState.container = container;
  });

  void decodesTo(String link, List<Map<String, dynamic>> proxies) {
    when(
      () => core.decodeShareLinks([link]),
    ).thenAnswer((_) async => [proxies]);
  }

  Future<void> pumpHost(WidgetTester tester) async {
    const size = Size(1200, 1000);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(withStatusManager: true, child: SizedBox()),
      ),
    );
  }

  Future<List<Map>> savedProxies(Profile profile) async {
    final config = loadYaml(await (await profile.file).readAsString()) as Map;
    return [for (final proxy in config['proxies'] as List) proxy as Map];
  }

  const fastestConfig = <String, dynamic>{
    'proxies': [
      {'name': 'Node A', 'type': 'direct'},
      {'name': 'Node B', 'type': 'direct'},
    ],
    'proxy-groups': [
      {
        'name': 'PROXY',
        'type': 'select',
        'proxies': ['Node A', 'Fastest'],
      },
      {
        'name': 'Fastest',
        'type': 'url-test',
        'proxies': ['Node A', 'Node B'],
      },
    ],
  };

  test(
    'a config without an automatic group keeps its normal selection',
    () async {
      final existing = Profile.normal(
        label: 'Existing',
      ).copyWith(selectedMap: {'PROXY': 'Node A'});
      container.read(profilesProvider.notifier).put(existing);
      container.read(currentProfileIdProvider.notifier).value = existing.id;
      const link = 'vless://id@first.example:443#First';
      decodesTo(link, [
        {'name': 'First', 'type': 'vless', 'server': 'first.example'},
      ]);

      await container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(link);

      final profile = container.read(currentProfileProvider)!;
      expect(profile.selectedMap, isEmpty);
      expect(setup.selectionsAtStart.single, profile.selectedMap);
      expect(container.read(profilesProvider).first.selectedMap, {
        'PROXY': 'Node A',
      });
    },
  );

  group('file import', () {
    late FilePickerPlatform previousPicker;
    late _TestFilePicker filePicker;

    setUp(() {
      previousPicker = FilePickerPlatform.instance;
      filePicker = _TestFilePicker();
      FilePickerPlatform.instance = filePicker;
    });

    tearDown(() => FilePickerPlatform.instance = previousPicker);

    test('selects and starts the validated file', () async {
      final config = utf8.encode(await encodeYamlTask(fastestConfig));
      filePicker.selected = _TestPlatformFile(config);
      final action = container.read(profilesActionProvider.notifier);
      final existing = Profile.normal(
        label: 'Existing',
      ).copyWith(selectedMap: {'PROXY': 'Node A'});
      action.putProfile(existing);

      await action.addProfileFormFile();

      final profile = container.read(profilesProvider).last;
      expect(profile.label, 'config.yaml');
      expect(container.read(currentProfileIdProvider), profile.id);
      expect(await (await profile.file).readAsBytes(), config);
      expect(profile.selectedMap, {'PROXY': 'Fastest', 'GLOBAL': 'Fastest'});
      expect(setup.selectionsAtStart.single, profile.selectedMap);
      expect(
        container.read(profilesProvider).first.selectedMap,
        existing.selectedMap,
      );
      expect(setup.requests, [
        (profileId: profile.id, running: true, initialize: true),
      ]);
    });

    test(
      'cancelling the picker leaves selection and connection alone',
      () async {
        final action = container.read(profilesActionProvider.notifier);
        final selected = action.addCustomProfile('Existing');

        await action.addProfileFormFile();

        expect(container.read(currentProfileIdProvider), selected);
        expect(container.read(profilesProvider), hasLength(1));
        expect(setup.requests, isEmpty);
      },
    );
  });

  group('addProfileFromLink with a share link', () {
    test('saves a file profile named after the proxy it holds', () async {
      const link = 'vless://id@hk.example.com:443#HK';
      decodesTo(link, [
        {'name': 'HK', 'type': 'vless', 'server': 'hk.example.com'},
      ]);

      await container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(link);

      final profile = container.read(profilesProvider).single;
      expect(profile.type, ProfileType.file);
      expect(profile.url, isEmpty);
      expect(profile.label, 'HK');
      expect(await savedProxies(profile), [
        {'name': 'HK', 'type': 'vless', 'server': 'hk.example.com'},
      ]);
      verify(() => core.validateConfig(any())).called(1);
      expect(setup.requests, [
        (profileId: profile.id, running: true, initialize: true),
      ]);
    });

    test('names an unnamed proxy after its server', () async {
      const link = 'ss://YWVzLTEyOC1nY206cGFzcw@ss.example.com:8388';
      decodesTo(link, [
        {'name': '', 'type': 'ss', 'server': 'ss.example.com'},
      ]);

      await container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(link, label: 'Mine');

      final profile = container.read(profilesProvider).single;
      expect(profile.label, 'Mine');
      expect((await savedProxies(profile)).single['name'], 'ss.example.com');
    });

    test('moves a proxy off a name mihomo reserves', () async {
      const link = 'trojan://pass@t.example.com:443#DIRECT';
      decodesTo(link, [
        {'name': 'DIRECT', 'type': 'trojan', 'server': 't.example.com'},
      ]);

      await container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(link);

      final profile = container.read(profilesProvider).single;
      expect((await savedProxies(profile)).single['name'], 'DIRECT-01');
    });

    testWidgets('reports a link no proxy can be read from and adds nothing', (
      tester,
    ) async {
      const link = 'vmess://not-base64';
      decodesTo(link, const []);
      await pumpHost(tester);

      await container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(link);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text(currentAppLocalizations.shareLinksInvalid), findsOne);
      expect(container.read(profilesProvider), isEmpty);
      verifyNever(() => core.validateConfig(any()));
      expect(setup.requests, isEmpty);
    });
  });

  group('addProfilesFromLinks with share links', () {
    const links = [
      'vless://id@hk.example.com:443#HK',
      'trojan://pass@hk2.example.com:443#HK',
      'ss://YWVzLTEyOC1nY206cGFzcw@ss.example.com:8388',
    ];

    test('makes one profile of all their proxies', () async {
      when(() => core.decodeShareLinks(links)).thenAnswer(
        (_) async => [
          [
            {'name': 'HK', 'type': 'vless', 'server': 'hk.example.com'},
          ],
          [
            {'name': 'HK', 'type': 'trojan', 'server': 'hk2.example.com'},
          ],
          [
            {'name': '', 'type': 'ss', 'server': 'ss.example.com'},
          ],
        ],
      );

      await container
          .read(profilesActionProvider.notifier)
          .addProfilesFromLinks(links);

      final profile = container.read(profilesProvider).single;
      expect(profile.type, ProfileType.file);
      expect(
        profile.label,
        currentAppLocalizations.proxiesProfileLabel('HK', 3),
      );
      expect(
        [for (final proxy in await savedProxies(profile)) proxy['name']],
        ['HK', 'HK-01', 'ss.example.com'],
      );
      verify(() => core.decodeShareLinks(links)).called(1);
      expect(setup.requests, [
        (profileId: profile.id, running: true, initialize: true),
      ]);
    });

    testWidgets('names the link no proxy can be read from and adds nothing', (
      tester,
    ) async {
      when(() => core.decodeShareLinks(links)).thenAnswer(
        (_) async => [
          [
            {'name': 'HK', 'type': 'vless', 'server': 'hk.example.com'},
          ],
          const [],
          [
            {'name': '', 'type': 'ss', 'server': 'ss.example.com'},
          ],
        ],
      );
      await pumpHost(tester);

      await container
          .read(profilesActionProvider.notifier)
          .addProfilesFromLinks(links);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final l10n = currentAppLocalizations;
      expect(
        find.text(
          l10n.failedItem(links.first, l10n.shareLinkUnreadable(links[1])),
        ),
        findsOne,
      );
      expect(container.read(profilesProvider), isEmpty);
      verifyNever(() => core.validateConfig(any()));
      expect(setup.requests, isEmpty);
    });
  });

  group('import activation', () {
    const first = 'vless://id@first.example:443#First';
    const second = 'vless://id@second.example:443#Second';
    const firstProxy = {
      'name': 'First',
      'type': 'vless',
      'server': 'first.example',
    };
    const secondProxy = {
      'name': 'Second',
      'type': 'vless',
      'server': 'second.example',
    };

    test(
      'each import switches profiles without toggling a running VPN off',
      () async {
        container.read(initProvider.notifier).value = true;
        decodesTo(first, [firstProxy]);
        decodesTo(second, [secondProxy]);
        final action = container.read(profilesActionProvider.notifier);

        await action.addProfileFromLink(first);
        final firstProfile = container.read(currentProfileProvider)!;
        await action.addProfileFromLink(second);
        final secondProfile = container.read(profilesProvider).last;

        expect(container.read(currentProfileIdProvider), secondProfile.id);
        expect(secondProfile.id, isNot(firstProfile.id));
        expect(setup.requests, [
          (profileId: firstProfile.id, running: true, initialize: false),
          (profileId: secondProfile.id, running: true, initialize: false),
        ]);
      },
    );

    test('a slower earlier import does not replace the newer import', () async {
      final pending = Completer<List<List<Map<String, dynamic>>>>();
      when(
        () => core.decodeShareLinks([first]),
      ).thenAnswer((_) => pending.future);
      decodesTo(second, [secondProxy]);
      final action = container.read(profilesActionProvider.notifier);
      final earlier = action.addProfileFromLink(first);
      await action.addProfileFromLink(second);
      final selected = container.read(currentProfileIdProvider);

      pending.complete([
        [firstProxy],
      ]);
      await earlier;

      expect(container.read(profilesProvider), hasLength(2));
      expect(container.read(currentProfileIdProvider), selected);
      expect(setup.requests, hasLength(1));
      expect(setup.requests.single.profileId, selected);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    test(
      'a later stop cancels pending import activation but preserves the import',
      () async {
        final pending = Completer<List<List<Map<String, dynamic>>>>();
        when(
          () => core.decodeShareLinks([first]),
        ).thenAnswer((_) => pending.future);
        final action = container.read(profilesActionProvider.notifier);
        final importing = action.addProfileFromLink(first);
        await container.read(setupActionProvider.notifier).setRunning(false);
        pending.complete([
          [firstProxy],
        ]);
        await importing;

        expect(container.read(profilesProvider), hasLength(1));
        expect(setup.requests.map((request) => request.running), [false]);
      },
    );

    test(
      'a stop during default selection still prevents automatic startup',
      () async {
        final entered = Completer<void>();
        final pending = Completer<List<Group>>();
        decodesTo(first, [firstProxy]);
        when(() => core.getProfileGroupReferences(any())).thenAnswer((_) {
          entered.complete();
          return pending.future;
        });
        final importing = container
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(first);
        await entered.future;
        await container.read(setupActionProvider.notifier).setRunning(false);
        pending.complete(_fixtureGroupReferences(fastestConfig));
        await importing;

        expect(container.read(profilesProvider), hasLength(1));
        expect(setup.requests.map((request) => request.running), [false]);
      },
    );

    test(
      'a default selection error preserves and starts the validated import',
      () async {
        decodesTo(first, [firstProxy]);
        when(
          () => core.getProfileGroupReferences(any()),
        ).thenThrow(StateError('config unavailable'));

        await container
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(first);

        final profile = container.read(profilesProvider).single;
        expect(profile.selectedMap, isEmpty);
        expect(setup.requests.single.profileId, profile.id);
        expect(setup.requests.single.running, isTrue);
      },
    );

    test(
      'native exclusions choose the same available automatic group as the checkbox',
      () async {
        final response =
            json.decode(
                  await File(
                    'test/fixtures/core/profile_group_references.json',
                  ).readAsString(),
                )
                as Map;
        final groups = [
          for (final raw in response['result'] as List)
            Group.fromJson(Map<String, dynamic>.from(raw as Map)),
        ];
        when(
          () => core.getProfileGroupReferences(any()),
        ).thenAnswer((_) async => groups);
        decodesTo(first, [firstProxy]);

        await container
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(first);

        expect(
          container.read(currentProfileProvider)!.selectedMap['PROXY'],
          'Auto',
        );
        expect(setup.selectionsAtStart.single['PROXY'], 'Auto');
      },
    );

    test('creating an empty custom profile does not start VPN', () {
      container.read(profilesActionProvider.notifier).addCustomProfile('Empty');

      expect(container.read(profilesProvider), hasLength(1));
      expect(setup.requests, isEmpty);
    });
  });

  group('subscription import', () {
    late HttpServer server;
    HttpOverrides? previousHttpOverrides;

    setUp(() async {
      previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = previousHttpOverrides;
    });

    String url(String name) => 'http://127.0.0.1:${server.port}/$name';

    test('a subscription download selects and starts its profile', () async {
      final body = await encodeYamlTask(fastestConfig);
      server.listen((request) async {
        request.response.write(body);
        await request.response.close();
      });
      final action = container.read(profilesActionProvider.notifier);
      action.addCustomProfile('Existing');

      await action.addProfileFromLink(url('subscription'));

      final profile = container.read(profilesProvider).last;
      expect(profile.type, ProfileType.url);
      expect(container.read(currentProfileIdProvider), profile.id);
      expect(setup.requests.single.profileId, profile.id);
      expect(setup.requests.single.running, isTrue);
      expect(profile.selectedMap, {'PROXY': 'Fastest', 'GLOBAL': 'Fastest'});
      expect(setup.selectionsAtStart.single, profile.selectedMap);
    });

    test(
      'a batch activates the last successful input once despite reversed completion',
      () async {
        final body = await encodeYamlTask(fastestConfig);
        final firstReceived = Completer<HttpRequest>();
        server.listen((request) async {
          if (request.uri.path == '/first') {
            firstReceived.complete(request);
            return;
          }
          request.response.write(body);
          await request.response.close();
        });
        final action = container.read(profilesActionProvider.notifier);
        final secondSaved = Completer<void>();
        container.listen(profilesProvider, (_, profiles) {
          if (profiles.any((profile) => profile.url == url('second')) &&
              !secondSaved.isCompleted) {
            secondSaved.complete();
          }
        });
        final importing = action.addProfilesFromLinks([
          url('first'),
          url('second'),
        ]);
        final firstRequest = await firstReceived.future;
        await secondSaved.future;
        expect(setup.requests, isEmpty);
        firstRequest.response.write(body);
        await firstRequest.response.close();
        await importing;

        final selected = container.read(currentProfileProvider)!;
        expect(selected.url, url('second'));
        expect(container.read(profilesProvider), hasLength(2));
        for (final profile in container.read(profilesProvider)) {
          expect(profile.selectedMap, {
            'PROXY': 'Fastest',
            'GLOBAL': 'Fastest',
          });
        }
        expect(setup.requests, [
          (profileId: selected.id, running: true, initialize: true),
        ]);
      },
    );

    test(
      'a failed final batch item does not prevent starting the last valid one',
      () async {
        server.listen((request) async {
          if (request.uri.path == '/failed') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.write('proxies: []\n');
          }
          await request.response.close();
        });

        await container
            .read(profilesActionProvider.notifier)
            .addProfilesFromLinks([url('valid'), url('failed')]);

        final profile = container.read(profilesProvider).single;
        expect(profile.url, url('valid'));
        expect(container.read(currentProfileIdProvider), profile.id);
        expect(setup.requests, [
          (profileId: profile.id, running: true, initialize: true),
        ]);
      },
    );
  });
}
