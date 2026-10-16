import 'package:flashco/common/common.dart';
import 'package:flashco/core/core.dart';
import 'package:flashco/enum/enum.dart';
import 'package:flashco/icons/icons.dart';
import 'package:flashco/models/models.dart';
import 'package:flashco/providers/providers.dart';
import 'package:flashco/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'dashboard.dart';
import 'widgets/core_status_button.dart';
import '../profiles/add.dart';

class SimpleHomeView extends ConsumerStatefulWidget {
  const SimpleHomeView({super.key});

  @override
  ConsumerState<SimpleHomeView> createState() => _SimpleHomeViewState();
}

class _SimpleHomeViewState extends ConsumerState<SimpleHomeView> {
  final _manualSelections = <(int, String), String>{};
  bool _changing = false;

  String? _manualProxy(FastestChoice choice, int profileId) {
    final previous = _manualSelections[(profileId, choice.selector.name)];
    if (previous != choice.automatic.name &&
        choice.selector.all.any((proxy) => proxy.name == previous)) {
      return previous;
    }
    final candidates = choice.selector.all.where(
      (proxy) => choice.automatic.all.any((node) => node.name == proxy.name),
    );
    if (candidates.any((proxy) => proxy.name == choice.automatic.now)) {
      return choice.automatic.now;
    }
    return candidates.firstOrNull?.name;
  }

  Future<void> _changeFastest(bool enabled, FastestChoice choice) async {
    final profile = ref.read(currentProfileProvider);
    if (_changing || profile == null) return;
    final selection = choice.selector.getCurrentSelectedName(
      profile.selectedMap[choice.selector.name] ?? '',
    );
    final target = enabled
        ? choice.automatic.name
        : _manualProxy(choice, profile.id);
    if (target == null) return;
    if (enabled && selection != choice.automatic.name) {
      _manualSelections[(profile.id, choice.selector.name)] = selection;
    }
    setState(() => _changing = true);
    try {
      await ref
          .read(proxiesActionProvider.notifier)
          .changeProxy(groupName: choice.selector.name, proxyName: target);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  List<CommonPopupMenuItem> _menuItems() {
    final currentItems = ref.read(currentNavigationItemsStateProvider).value;
    return [
      CommonPopupMenuItem(
        label: context.appLocalizations.controlPanel,
        glyph: AppGlyphs.dashboard,
        onPressed: () =>
            showExtend(context, builder: (_) => const DashboardView()),
      ),
      for (final item in ref.watch(navigationItemsStateProvider).value)
        if (item.label != PageLabel.dashboard && item.modes.isNotEmpty)
          CommonPopupMenuItem(
            label: item.label.label,
            glyph: item.glyph,
            onPressed: () {
              if (currentItems.any((current) => current.label == item.label)) {
                ref.read(currentPageLabelProvider.notifier).toPage(item.label);
              } else {
                showExtend(
                  context,
                  props: ExtendProps(
                    forceFull: item.modes.contains(NavigationItemMode.moreFull),
                  ),
                  builder: item.builder,
                );
              }
            },
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final profile = ref.watch(currentProfileProvider);
    final choice = fastestChoice(
      ref.watch(groupsProvider),
      ref.watch(patchClashConfigProvider.select((config) => config.mode)),
    );
    final selection = choice == null
        ? null
        : ref.watch(selectedProxyNameProvider(choice.selector.name));
    final fastest = choice != null && selection == choice.automatic.name;
    final coreStatus = ref.watch(coreStatusProvider);
    final available =
        profile != null &&
        choice != null &&
        coreStatus == CoreStatus.connected &&
        !_changing &&
        (!fastest || _manualProxy(choice, profile.id) != null);
    final running = ref.watch(isStartProvider);
    final hasProfiles = ref.watch(
      profilesProvider.select((profiles) => profiles.isNotEmpty),
    );
    final suspended = ref.watch(suspendProvider);
    return CommonScaffold(
      title: appName,
      actions: [
        if (coreLib == null && coreStatus != CoreStatus.connected)
          const CoreStatusButton(),
      ],
      menuItems: _menuItems(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final padding = EdgeInsets.fromLTRB(
            24,
            context.contentTopPadding,
            24,
            24 + BottomInsetScope.of(context),
          );
          return SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - padding.vertical).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        switch (coreStatus) {
                          CoreStatus.connecting => labels.connecting,
                          CoreStatus.disconnected => labels.disconnected,
                          CoreStatus.connected =>
                            running
                                ? (suspended
                                      ? labels.suspended
                                      : labels.connected)
                                : labels.disconnected,
                        },
                        textAlign: TextAlign.center,
                        style: context.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 112,
                        child: CommonFloatingActionButton(
                          onPressed: hasProfiles || running
                              ? ref
                                    .read(commonActionProvider.notifier)
                                    .toggleRunning
                              : null,
                          icon: GlyphIcon(
                            running && suspended
                                ? AppGlyphs.wifiOff
                                : AppGlyphs.playPause(running ? 1 : 0),
                            fill: 1,
                          ),
                          label: running ? labels.stop : labels.launch,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (profile != null) ...[
                        Text(
                          profile.realLabel,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                      ],
                      generateSectionV3(
                        items: [
                          ListItem(
                            onTap: () => showAddProfilePage(context),
                            leading: const GlyphIcon(AppGlyphs.add),
                            title: Text(labels.addConfiguration),
                          ),
                          ListItem.checkbox(
                            value: fastest,
                            onChanged: available
                                ? (value) => _changeFastest(value!, choice)
                                : null,
                            title: Text(labels.fastestServer),
                            subtitle: profile != null && choice == null
                                ? Text(labels.fastestServerUnavailable)
                                : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
