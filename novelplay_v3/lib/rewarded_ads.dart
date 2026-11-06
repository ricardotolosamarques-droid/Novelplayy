import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Carrega o SDK somente quando o usuário pede para desbloquear uma série.
/// Assim o SDK não participa da inicialização da tela inicial.
class NovelRewardedAds {
  static const String _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
  static Future<bool>? _activeRequest;

  static Future<bool> showForSeriesUnlock() {
    // Evita duas solicitações simultâneas de anúncio.
    return _activeRequest ??= _show().whenComplete(() => _activeRequest = null);
  }

  static Future<bool> _show() async {
    RewardedAd? ad;
    var earnedReward = false;
    try {
      await MobileAds.instance.initialize().timeout(const Duration(seconds: 15));
      final loaded = Completer<RewardedAd>();
      await RewardedAd.load(
        adUnitId: _testRewardedAndroid,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (value) {
            if (!loaded.isCompleted) loaded.complete(value);
          },
          onAdFailedToLoad: (error) {
            if (!loaded.isCompleted) loaded.completeError(error);
          },
        ),
      );
      ad = await loaded.future.timeout(const Duration(seconds: 30));
      final finished = Completer<bool>();
      ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
        onAdDismissedFullScreenContent: (value) {
          value.dispose();
          if (!finished.isCompleted) finished.complete(earnedReward);
        },
        onAdFailedToShowFullScreenContent: (value, error) {
          value.dispose();
          if (!finished.isCompleted) finished.complete(false);
        },
      );
      ad.show(onUserEarnedReward: (value, reward) {
        earnedReward = true;
      });
      return await finished.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          ad?.dispose();
          return false;
        },
      );
    } catch (_) {
      ad?.dispose();
      return false;
    }
  }
}
