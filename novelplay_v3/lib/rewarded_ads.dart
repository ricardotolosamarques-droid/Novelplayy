import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Acesso sem anúncios concedido por anúncios recompensados.
class NovelRewardedAds {
  static const Duration accessDuration = Duration(minutes: 30);
  static const String _accessUntilKey = 'novelplay_ad_free_until';
  static const String _testRewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';

  static Future<void>? _initialization;

  static Future<void> _initialize() {
    return _initialization ??= MobileAds.instance.initialize().then((_) {});
  }

  /// Assiste voluntariamente a outro anúncio e soma mais 30 minutos,
  /// mesmo que já exista tempo disponível.
  static Future<bool> watchAdForMoreAccess() async {
    final earnedReward = await _showRewardedAd();
    if (!earnedReward) return false;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final savedUntil = prefs.getInt(_accessUntilKey) ?? 0;
    final baseTime = savedUntil > now ? savedUntil : now;
    await prefs.setInt(
      _accessUntilKey,
      baseTime + accessDuration.inMilliseconds,
    );
    return true;
  }

  /// Retorna true se o usuário já tem tempo ativo ou concluiu um anúncio.
  /// O horário é salvo como timestamp absoluto e continua válido após fechar
  /// ou reiniciar o aplicativo.
  static Future<bool> ensureAdFreeAccess() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final savedUntil = prefs.getInt(_accessUntilKey) ?? 0;

    if (savedUntil > now) return true;

    final earnedReward = await _showRewardedAd();
    if (!earnedReward) return false;

    final baseTime = savedUntil > now ? savedUntil : now;
    final newUntil = baseTime + accessDuration.inMilliseconds;
    await prefs.setInt(_accessUntilKey, newUntil);
    return true;
  }

  static Future<Duration> remainingAccess() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_accessUntilKey) ?? 0;
    final remaining = until - DateTime.now().millisecondsSinceEpoch;
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }

  static Future<bool> _showRewardedAd() async {
    try {
      await _initialize().timeout(const Duration(seconds: 30));
      final result = Completer<bool>();

      RewardedAd.load(
        adUnitId: _testRewardedAdUnitId,
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

      return await result.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }
}
