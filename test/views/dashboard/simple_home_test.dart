import 'package:flashco/common/common.dart';
import 'package:flashco/core/controller.dart';
import 'package:flashco/core/interface.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/icons/icons.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/providers.dart';
import 'package:flashco/state.dart';
import 'package:flashco/views/dashboard/simple_home.dart';
import 'package:flashco/widgets/widgets.dart';
import 'package:flashco/views/navigation.dart';
import 'package:flashco/views/profiles/add.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/glyph_finders.dart';
import '../../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

class _RecordingSetup extends SetupAction {
  final requests = <bool>[];

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    requests.add(running);
    ref.read(runTimeProvider.notifier).value = running ? 1000 : null;
    return true;
  }
}

const _nodeA = Proxy(name: 'Node A', type: 'Vless');
const _nodeB = Proxy(name: 'Node B', type: 'Vless');
const _groups = [
  Group(
    name: 'PROXY',
    type: GroupType.Selector,
    hidden: false,
    now: 'Node A',
    all: [
      Proxy(name: 'Fastest', type: 'URLTest'),
      _nodeA,
      _nodeB,
    ],
  ),
  Group(
    name: 'Fastest',
    type: GroupType.URLTest,
    now: 'Node B',
    all: [_nodeA, _nodeB],
  ),
];

void main() {
  late ProviderContainer container;
  late _MockCore core;
  var excludedWifi = false;

  setUpAll(() {
    registerFallbackValue(
      const ChangeProxyParams(groupName: '', proxyName: ''),
    );
  });

  setUp(() {
    excludedWifi = false;
    navigationPort = navigation;
    addTearDown(() => navigationPort = null);
    core = _MockCore();
    when(
      () => core.changeProxy(any()),
    ).thenAnswer((_) async => const ChangeProxyResult());
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(_RecordingSetup.new),
        suspendProvider.overrideWith((_) => excludedWifi),
        profilesProvider.overrideWith(
          () => TestProfiles([
            const Profile(
              id: 1,
              label: 'My config',
              autoUpdateDuration: Duration.zero,
            ),
          ]),
        ),
      ],
    );
    globalState.container = container;
    container.listen(currentProfileIdProvider, (_, _) {});
    container.read(currentProfileIdProvider.notifier).value = 1;
    container.read(groupsProvider.notifier).value = _groups;
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    addTearDown(container.dispose);
  });

  Future<void> pumpHome(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: const Locale('en'),
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: Consumer(
              builder: (_, ref, _) => Theme(
                data: ThemeData(
                  colorScheme: ref.watch(
                    genColorSchemeProvider(
                      ref.watch(currentBrightnessProvider),
                    ),
                  ),
                ).withAppShapes,
                child: Builder(builder: navigation.getItems().first.builder),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('home provides one prominent launch and configuration import', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.byType(SimpleHomeView), findsOneWidget);
    expect(find.byTooltip('Launch'), findsOneWidget);
    expect(find.text('Launch'), findsNothing);
    expect(find.text('Add configuration'), findsOneWidget);
    expect(find.text('My config'), findsOneWidget);
    final power = find.byTooltip('Launch');
    expect(tester.getSize(power).width, tester.getSize(power).height);
    expect(tester.getSize(power).width, greaterThanOrEqualTo(112));
    expect(find.byType(CommonCheckBox), findsNothing);
    expect(find.byType(TextButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('power button starts and stops through the existing action', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Launch'));
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    expect(find.text('Disconnected'), findsOneWidget);
    final setup =
        container.read(setupActionProvider.notifier) as _RecordingSetup;
    expect(setup.requests, [true, false]);
  });

  testWidgets('keyboard activates the focused power button', (tester) async {
    await pumpHome(tester);
    Focus.of(tester.element(find.byGlyph(AppGlyphs.power))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    final setup =
        container.read(setupActionProvider.notifier) as _RecordingSetup;
    expect(setup.requests, [true]);
  });

  testWidgets('opening home preserves the saved server selection', (
    tester,
  ) async {
    container
        .read(profilesProvider.notifier)
        .put(
          const Profile(
            id: 1,
            label: 'My config',
            autoUpdateDuration: Duration.zero,
            selectedMap: {'PROXY': 'Fastest'},
          ),
        );
    await pumpHome(tester);
    expect(find.byType(CommonCheckBox), findsNothing);
    expect(container.read(currentProfileProvider)!.selectedMap, {
      'PROXY': 'Fastest',
    });
    verifyNever(() => core.changeProxy(any()));
  });

  testWidgets('empty configuration keeps import and disables launch', (
    tester,
  ) async {
    (container.read(profilesProvider.notifier) as TestProfiles).replace([]);
    await pumpHome(tester);
    expect(
      tester
          .widget<IconButton>(find.widgetWithGlyph(IconButton, AppGlyphs.power))
          .onPressed,
      isNull,
    );
    expect(find.text('Add configuration'), findsOneWidget);
    expect(find.byType(CommonCheckBox), findsNothing);
  });

  testWidgets('small screen with large text scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHome(tester, scale: 2);
    await tester.ensureVisible(find.text('Add configuration'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Core failure cannot leave the home status connected', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1000;
    await pumpHome(tester);
    expect(find.text('Connected'), findsOneWidget);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await tester.pump();
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Disconnected'), findsWidgets);
    expect(find.byTooltip('Stop'), findsOneWidget);
  });

  testWidgets('configuration action opens the existing import screen', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Add configuration'));
    await tester.pumpAndSettle();
    expect(find.byType(AddProfileView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all controls inherit the application theme in light and dark', (
    tester,
  ) async {
    final buttonColors = <Color?>[];
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      container
          .read(themeSettingProvider.notifier)
          .update(
            (settings) =>
                settings.copyWith(themeMode: mode, primaryColor: 0xff267b52),
          );
      await pumpHome(tester);
      await tester.pumpAndSettle();
      final context = tester.element(
        find.widgetWithGlyph(IconButton, AppGlyphs.power),
      );
      final scheme = container.read(
        genColorSchemeProvider(
          mode == ThemeMode.light ? Brightness.light : Brightness.dark,
        ),
      );
      expect(Theme.of(context).colorScheme, scheme);
      final surface = tester.widget<Material>(
        find
            .descendant(
              of: find.widgetWithGlyph(IconButton, AppGlyphs.power),
              matching: find.byType(Material),
            )
            .first,
      );
      buttonColors.add(surface.color);
      expect(surface.shape, AppShape.xxl);
      expect(find.byType(CommonCheckBox), findsNothing);
      expect(find.byType(ListItem<dynamic>), findsNothing);
      expect(tester.takeException(), isNull);
    }
    expect(buttonColors.first, isNot(buttonColors.last));
  });

  testWidgets('stopped launch keeps its power button on excluded Wi-Fi', (
    tester,
  ) async {
    excludedWifi = true;
    await pumpHome(tester);
    expect(find.byTooltip('Launch'), findsOneWidget);
    expect(find.byGlyph(AppGlyphs.wifiOff), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu preserves advanced navigation and the control panel', (
    tester,
  ) async {
    container.listen(currentPageLabelProvider, (_, _) {});
    await pumpHome(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Control panel'), findsOneWidget);
    expect(find.text(PageLabel.profiles.label), findsOneWidget);
    expect(find.text(PageLabel.proxies.label), findsOneWidget);
    await tester.tap(find.text(PageLabel.tools.label));
    await tester.pumpAndSettle();
    expect(container.read(currentPageLabelProvider), PageLabel.tools);
    expect(tester.takeException(), isNull);
  });
}
