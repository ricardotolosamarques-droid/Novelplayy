/// Implementação temporária de diagnóstico: o plugin nativo do AdMob foi
/// removido para verificar se ele causa o encerramento na inicialização.
/// A reprodução e as demais funções do app permanecem independentes disso.
class NovelRewardedAds {
  static Future<void> initialize() async {}
  static Future<bool> showForSeriesUnlock() async => false;
}
