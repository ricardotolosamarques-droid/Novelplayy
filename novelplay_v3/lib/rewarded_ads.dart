import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Anúncio recompensado. Durante o desenvolvimento, usa o ID oficial de teste
/// do Google. Troque pelo ID da unidade Rewarded do AdMob antes de publicar.
class NovelRewardedAds {
  static const String _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
  static RewardedAd? _loadedAd;
  static bool _loading = false;
  static bool _initialized = false;

  // O SDK só é inicializado quando o usuário realmente solicita um anúncio.
  // Assim, uma falha do serviço de anúncios não impede o app de abrir.
  static Future<void> initialize() async {
    if (_initialized) return;
    await MobileAds.instance.initialize();
    _initialized = true;
    _preload();
  }

  static void _preload() {
    if (_loading || _loadedAd != null) return;
    _loading = true;
    RewardedAd.load(
      adUnitId: _testRewardedAndroid,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _loadedAd = ad;
          _loading = false;
        },
        onAdFailedToLoad: (_) {
          _loading = false;
          _loadedAd = null;
        },
      ),
    );
  }

  /// Retorna true somente quando o SDK informa que o usuário ganhou a recompensa.
  static Future<bool> showForSeriesUnlock() async {
    try {
      await initialize();
    } catch (_) {
      return false;
    }
    final completer = Completer<bool>();
    final ad = _loadedAd;
    _loadedAd = null;
    if (ad == null) {
      _preload();
      return false;
    }
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!completer.isCompleted) completer.complete(earned);
        _preload();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        if (!completer.isCompleted) completer.complete(false);
        _preload();
      },
    );
    ad.show(onUserEarnedReward: (_, reward) {
      earned = true;
    });
    return completer.future;
  }
}
