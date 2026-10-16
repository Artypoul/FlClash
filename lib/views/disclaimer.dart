import 'package:flashco/common/common.dart';
import 'package:flashco/icons/icons.dart';
import 'package:flashco/l10n/l10n.dart';
import 'package:flashco/providers/app.dart';
import 'package:flashco/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<bool> requestDisclaimerConsent() async {
  return await BaseNavigator.push<bool>(
        rootNavigatorKey.currentContext!,
        const DisclaimerView(requireConsent: true),
      ) ??
      false;
}

class DisclaimerView extends StatelessWidget {
  final bool requireConsent;

  const DisclaimerView({super.key, this.requireConsent = false});

  static const _maxContentWidth = 720.0;

  List<({String title, String content})> _leadingTerms(AppLocalizations l) => [
    (
      title: l.disclaimerSoftwareTitle,
      content:
          '${l.disclaimerSoftwareContent}\n\n${l.disclaimerNoServiceStatement}',
    ),
    (title: l.disclaimerUsageTitle, content: l.disclaimerUsageContent),
    (
      title: l.disclaimerResponsibilityTitle,
      content: l.disclaimerResponsibilityContent,
    ),
    (
      title: l.disclaimerThirdPartyTitle,
      content: l.disclaimerThirdPartyContent,
    ),
    (title: l.disclaimerWarrantyTitle, content: l.disclaimerWarrantyContent),
    (title: l.disclaimerLiabilityTitle, content: l.disclaimerLiabilityContent),
  ];

  List<({String title, String content})> _trailingTerms(AppLocalizations l) => [
    (title: l.disclaimerLicenseTitle, content: l.disclaimerLicenseContent),
    (title: l.disclaimerChangesTitle, content: l.disclaimerChangesContent),
    (title: l.disclaimerAcceptTitle, content: l.disclaimerAcceptContent),
  ];

  static const _mobileGutter = 16.0;
  static const _desktopGutter = 24.0;
  static const _desktopTopPadding = 48.0;

  ListView _buildBody({
    required EdgeInsets padding,
    required List<Widget> children,
  }) {
    return ListView(
      padding: padding,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final terms = _buildTerms(appLocalizations);
    final body = _buildBody(
      padding: const EdgeInsets.symmetric(
        horizontal: _mobileGutter,
      ).copyWith(top: context.contentTopPadding, bottom: 32),
      children: terms,
    );
    if (!requireConsent) {
      return CommonScaffold(title: appLocalizations.disclaimer, body: body);
    }
    return Consumer(
      builder: (context, ref, _) {
        if (ref.watch(isMobileViewProvider)) {
          return CommonScaffold(
            title: appLocalizations.disclaimer,
            body: _ConsentLayout(
              maxWidth: _maxContentWidth,
              gutter: _mobileGutter,
              compact: true,
              child: body,
            ),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: _ConsentLayout(
              maxWidth: _maxContentWidth,
              gutter: _desktopGutter,
              compact: false,
              child: _buildBody(
                padding: const EdgeInsets.fromLTRB(
                  _desktopGutter,
                  _desktopTopPadding,
                  _desktopGutter,
                  32,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      appLocalizations.disclaimer,
                      style: context.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ...terms,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildTerms(AppLocalizations appLocalizations) {
    final leadingTerms = _leadingTerms(appLocalizations);
    final trailingTerms = _trailingTerms(appLocalizations);
    final privacyIndex = leadingTerms.length + 1;
    return [
      _DisclaimerIntro(text: appLocalizations.disclaimerDesc),
      for (final (index, term) in leadingTerms.indexed)
        _DisclaimerTerm(
          index: index + 1,
          title: term.title,
          content: term.content,
        ),
      _DisclaimerTerm(
        index: privacyIndex,
        title: appLocalizations.disclaimerPrivacyTitle,
        content: appLocalizations.disclaimerPrivacyContent,
      ),
      for (final (index, term) in trailingTerms.indexed)
        _DisclaimerTerm(
          index: privacyIndex + index + 1,
          title: term.title,
          content: term.content,
        ),
    ];
  }
}

class _DisclaimerIntro extends StatelessWidget {
  final String text;

  const _DisclaimerIntro({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colorScheme.primaryContainer,
        shape: AppShape.xl,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlyphIcon(
              AppGlyphs.gavel,
              size: 28,
              color: colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                text,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisclaimerTerm extends StatelessWidget {
  final int index;
  final String title;
  final String content;

  const _DisclaimerTerm({
    required this.index,
    required this.title,
    required this.content,
  });

  static const _badgeSize = 28.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final textTheme = context.textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: colorScheme.secondaryContainer,
                  shape: AppShape.full,
                ),
                child: SizedBox.square(
                  dimension: _badgeSize,
                  child: Center(
                    child: Text(
                      '$index',
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _TermParagraphs(content),
        ],
      ),
    );
  }
}

class _TermParagraphs extends StatelessWidget {
  final String text;

  const _TermParagraphs(this.text);

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodyMedium?.copyWith(
      color: context.colorScheme.onSurfaceVariant,
      height: 1.6,
    );
    final paragraphs = text.split('\n\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, paragraph) in paragraphs.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
            child: Text(paragraph, style: style),
          ),
      ],
    );
  }
}

class _ConsentLayout extends StatelessWidget {
  final double maxWidth;
  final double gutter;
  final bool compact;
  final Widget child;

  const _ConsentLayout({
    required this.maxWidth,
    required this.gutter,
    required this.compact,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        _ConsentBar(maxWidth: maxWidth, gutter: gutter, compact: compact),
      ],
    );
  }
}

class _ConsentBar extends StatelessWidget {
  final double maxWidth;
  final double gutter;
  final bool compact;

  const _ConsentBar({
    required this.maxWidth,
    required this.gutter,
    required this.compact,
  });

  Widget _buildExitButton(BuildContext context) {
    return ElasticButton(
      child: OutlinedButton(
        onPressed: () {
          Navigator.of(context).pop(false);
        },
        child: Text(context.appLocalizations.exit),
      ),
    );
  }

  Widget _buildAgreeButton(BuildContext context, {required String label}) {
    return ElasticButton(
      child: FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(label),
      ),
    );
  }

  Widget _buildCompactActions(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return Row(
      children: [
        Expanded(child: _buildExitButton(context)),
        const SizedBox(width: 12),
        Expanded(
          child: _buildAgreeButton(context, label: appLocalizations.agree),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return Row(
      children: [
        const Spacer(),
        const SizedBox(width: 12),
        _buildExitButton(context),
        const SizedBox(width: 12),
        _buildAgreeButton(context, label: appLocalizations.agree),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colorScheme.surface,
        border: Border(
          top: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth + gutter * 2),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 12),
              child: compact
                  ? _buildCompactActions(context)
                  : _buildActions(context),
            ),
          ),
        ),
      ),
    );
  }
}
