# NOVELIX Android

Projeto Android nativo em Kotlin + Jetpack Compose.

## Build
O workflow `.github/workflows/build-novelix-apk.yml` compila o APK debug no GitHub Actions quando arquivos em `NOVELIX/**` mudam ou quando executado manualmente.

No GitHub, abra **Actions → Build NOVELIX APK**, selecione a execução concluída e baixe o artifact **NOVELIX-debug-apk**.

## Configuração necessária antes do uso real
O endereço em `app/src/main/java/com/codenexus/novelix/Api.kt` é um placeholder: `https://YOUR-AUTHORIZED-API.example/`. Sem configurar uma API própria/autorizada com os endpoints definidos em `NovelixApi`, o app permanece em modo demonstração e o catálogo real, episódios e reprodução não funcionarão.

O app mantém a verificação de autorização do provedor para episódios que exigem assinatura. Não há remoção ou contorno de bloqueios de conteúdo pago no cliente.

## Observações
- applicationId: `com.codenexus.novelix`
- minSdk: 24
- compileSdk/targetSdk: 35
- O APK debug gerado pelo workflow ainda precisa ser instalado e testado em um aparelho Android.
