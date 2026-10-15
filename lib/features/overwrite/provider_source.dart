import 'package:flashco/enum/enum.dart';
import 'package:flashco/l10n/l10n.dart';

extension ProviderSourceExt on ProviderSource {
  String label(AppLocalizations appLocalizations) => switch (this) {
    ProviderSource.subscription => appLocalizations.providerSourceSubscription,
    ProviderSource.profile => appLocalizations.profile,
    ProviderSource.app => appLocalizations.app,
  };
}
