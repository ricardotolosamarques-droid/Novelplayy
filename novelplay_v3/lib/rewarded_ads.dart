import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Anúncio recompensado usando o identificador oficial de teste do Google.
/// Trocar pelo bloco de anúncios real do AdMob após validar o fluxo no aparelho.
class NovelRewardedAds {
  static Future<void>? _initialization;

  static Future<void> _initialize() {
    return _initialization ??= MobileAds.instance.initialize().then((_) {});
  }

  static Future<bool> showForSeriesUnlock() async {
    await _initialize();

    final result = Completer<bool>();
    RewardedAd.load(
      adUnitId: 'ca-app-pub-3940256099942544/5224354917',
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          var earnedReward = false;
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              if (!result.isCompleted) result.complete(earnedReward);
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              if (!result.isCompleted) result.complete(false);
            },
          );

          try {
            ad.show(
              onUserEarnedReward: (ad, reward) {
                earnedReward = true;
              },
            );
          } catch (_) {
            ad.dispose();
            if (!result.isCompleted) result.complete(false);
          }
        },
        onAdFailedToLoad: (error) {
          if (!result.isCompleted) result.complete(false);
        },
      ),
    );

    return result.future;
  }
}
