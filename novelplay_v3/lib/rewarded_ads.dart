import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Anúncio recompensado carregado somente quando o usuário solicita.
/// Assim o SDK não participa da inicialização da tela principal.
class NovelRewardedAds {
  static const String _testRewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';

  static Future<void>? _initialization;
  static bool _showing = false;

  static Future<void> _initialize() {
    return _initialization ??= MobileAds.instance.initialize().then((_) {});
  }

  static Future<bool> showForSeriesUnlock() async {
    if (_showing) return false;
    _showing = true;
    try {
      await _initialize();
      final ad = await _loadRewardedAd();
      final completer = Completer<bool>();
      var earnedReward = false;

      ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
        onAdDismissedFullScreenContent: (ad) {
          ad.dispose();
          if (!completer.isCompleted) completer.complete(earnedReward);
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          ad.dispose();
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      ad.show(onUserEarnedReward: (ad, reward) {
        earnedReward = true;
      });

      return await completer.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          ad.dispose();
          return earnedReward;
        },
      );
    } catch (_) {
      return false;
    } finally {
      _showing = false;
    }
  }

  static Future<RewardedAd> _loadRewardedAd() {
    final completer = Completer<RewardedAd>();
    RewardedAd.load(
      adUnitId: _testRewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => completer.complete(ad),
        onAdFailedToLoad: (error) => completer.completeError(error),
      ),
    );
    return completer.future.timeout(const Duration(seconds: 30));
  }
}
