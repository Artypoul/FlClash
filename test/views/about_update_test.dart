import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flashco/common/constant.dart';
import 'package:flashco/common/preferences.dart';
import 'package:flashco/common/request.dart';
import 'package:flashco/l10n/l10n.dart';
import 'package:flashco/manager/app_manager.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/app.dart';
import 'package:flashco/providers/action.dart';
import 'package:flashco/providers/config.dart';
import 'package:flashco/providers/database.dart';
import 'package:flashco/state.dart';
import 'package:flashco/views/about.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../helpers/test_app.dart';

const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
const _installedVersion = '1.2.2';

class _UpdateAdapter implements HttpClientAdapter {
  _UpdateAdapter(this.respond);

  final Future<ResponseBody> Function(RequestOptions options) respond;
  final requests = <RequestOptions>[];
  final dispatched = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    if (!dispatched.isCompleted) dispatched.complete();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late HttpClientAdapter originalRequestAdapter;
  late String? launchedUrl;

  setUpAll(() {
    globalState.packageInfo = PackageInfo(
      appName: 'Flashco',
      packageName: 'com.follow.flashco',
      version: _installedVersion,
      buildNumber: '1',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(overrides: _isolatedOverrides());
    globalState.container = container;
    container.listen(configProvider, (_, _) {});
    originalRequestAdapter = request.dio.httpClientAdapter;
    launchedUrl = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launcherChannel, (call) async {
          if (call.method == 'launch') {
            launchedUrl =
                (call.arguments as Map<Object?, Object?>)['url'] as String;
            return true;
          }
          return false;
        });
  });

  tearDown(() {
    container.dispose();
    request.dio.httpClientAdapter = originalRequestAdapter;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launcherChannel, null);
  });

  Future<void> pumpAbout(WidgetTester tester) async {
    const size = Size(1200, 1000);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container.read(viewSizeProvider.notifier).update((_) => size);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: const Locale('ru'),
          homeBuilder: (child) => AppStateManager(child: child),
          child: const AboutView(),
        ),
      ),
    );
  }

  Future<void> tapCheck(WidgetTester tester) async {
    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows an update and opens this project latest releases page', (
    tester,
  ) async {
    final adapter = _UpdateAdapter(
      (_) async => _releaseResponse('v1.2.3', '- Added manual release notes'),
    );
    request.dio.httpClientAdapter = adapter;
    await pumpAbout(tester);
    final localizations = AppLocalizations.of(
      tester.element(find.byType(AboutView)),
    );

    await tapCheck(tester);

    expect(find.text(localizations.discoverNewVersion), findsOneWidget);
    expect(find.textContaining('v1.2.3'), findsOneWidget);
    expect(find.textContaining('Added manual release notes'), findsOneWidget);
    expect(find.text(localizations.goDownload), findsOneWidget);
    expect(adapter.requests, hasLength(1));

    await tester.tap(find.text(localizations.goDownload));
    await tester.pumpAndSettle();

    expect(launchedUrl, 'https://github.com/$repository/releases/latest');
  });

  testWidgets('manual checks report current and older releases as up to date', (
    tester,
  ) async {
    var tag = 'v$_installedVersion';
    final adapter = _UpdateAdapter((options) async {
      return _releaseResponse(tag, null);
    });
    request.dio.httpClientAdapter = adapter;
    await pumpAbout(tester);
    final localizations = AppLocalizations.of(
      tester.element(find.byType(AboutView)),
    );

    for (final releaseTag in ['v$_installedVersion', 'v1.2.1']) {
      tag = releaseTag;
      await tapCheck(tester);
      expect(find.text(localizations.checkUpdateError), findsOneWidget);
      await tester.tap(find.text(localizations.confirm));
      await tester.pumpAndSettle();
      expect(find.text(localizations.discoverNewVersion), findsNothing);
    }
  });

  testWidgets(
    'no longer remind disables auto checks but manual checks remain available',
    (tester) async {
      var tag = 'v1.2.3';
      final adapter = _UpdateAdapter(
        (_) async => _releaseResponse(tag, '- Keep settings'),
      );
      request.dio.httpClientAdapter = adapter;
      await pumpAbout(tester);
      final localizations = AppLocalizations.of(
        tester.element(find.byType(AboutView)),
      );
      final action = container.read(commonActionProvider.notifier);

      final automaticCheck = action.autoCheckUpdate();
      await tester.pumpAndSettle();
      expect(find.text(localizations.noLongerRemind), findsOneWidget);
      await tester.tap(find.text(localizations.noLongerRemind));
      await tester.pumpAndSettle();
      await automaticCheck;

      expect(container.read(appSettingProvider).autoCheckUpdate, isFalse);
      await tester.pump(const Duration(milliseconds: 700));
      final savedConfig = await preferences.getConfig();
      expect(savedConfig?.appSettingProps.autoCheckUpdate, isFalse);

      final previousContainer = container;
      container = ProviderContainer(
        overrides: [
          ..._isolatedOverrides(),
          ...buildConfigOverrides(savedConfig!),
        ],
      );
      globalState.container = container;
      container.listen(configProvider, (_, _) {});
      await pumpAbout(tester);
      previousContainer.dispose();
      tag = 'v1.2.4';
      await tapCheck(tester);

      expect(adapter.requests, hasLength(2));
      expect(find.text(localizations.discoverNewVersion), findsOneWidget);
      expect(find.text(localizations.noLongerRemind), findsNothing);
    },
  );

  testWidgets('a slow check produces one update dialog when it completes', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final adapter = _UpdateAdapter((_) => response.future);
    request.dio.httpClientAdapter = adapter;
    await pumpAbout(tester);

    final button = find.text('Проверить обновления');
    await tester.tap(button);
    await tester.pump();
    for (var i = 0; i < 5 && adapter.requests.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(adapter.requests, hasLength(1));

    await tester.tap(button);
    await tester.pump();
    expect(adapter.requests, hasLength(1));

    response.complete(_releaseResponse('v1.2.3', '- Delayed update notes'));
    await tester.pumpAndSettle();

    final localizations = AppLocalizations.of(
      tester.element(find.byType(AboutView)),
    );
    expect(find.text(localizations.discoverNewVersion), findsOneWidget);
    expect(adapter.requests, hasLength(1));
  });

  testWidgets('a failed manual request does not claim the app is up to date', (
    tester,
  ) async {
    final adapter = _UpdateAdapter((options) async {
      if (options.uri.host == 'api.github.com') {
        return ResponseBody.fromString('{}', 403);
      }
      return ResponseBody.fromString('', 503);
    });
    request.dio.httpClientAdapter = adapter;
    await pumpAbout(tester);
    final localizations = AppLocalizations.of(
      tester.element(find.byType(AboutView)),
    );

    await tapCheck(tester);

    expect(adapter.requests, hasLength(2));
    expect(find.text(localizations.checkUpdateError), findsNothing);
    expect(find.text(localizations.discoverNewVersion), findsNothing);
  });
}

Future<ResponseBody> _releaseResponse(String tag, String? body) async =>
    ResponseBody.fromString(
      jsonEncode(<String, Object?>{'tag_name': tag, 'body': body}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

List<Override> _isolatedOverrides() => [
  iconSetsProvider.overrideWith(_EmptyIconSets.new),
];

class _EmptyIconSets extends IconSets {
  @override
  Stream<List<IconSet>> build() => Stream.value(const <IconSet>[]);
}
