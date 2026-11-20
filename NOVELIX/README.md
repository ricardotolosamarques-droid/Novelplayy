# NOVELIX

Projeto Android nativo Kotlin/Jetpack Compose, mantido isolado do aplicativo NovelPlay.

## Fonte
O arquivo `NOVELIX-Android.zip` contém o projeto original completo. O workflow `.github/workflows/build-novelix-apk.yml` extrai esse arquivo em um runner Linux, instala JDK 17, Android SDK 35 e Gradle 8.9 e tenta gerar o APK debug.

## Obter o APK
1. Abra a aba Actions do repositório.
2. Selecione **Build NOVELIX APK**.
3. Aguarde a execução terminar.
4. Em Artifacts, baixe **NOVELIX-debug-apk** e extraia o `app-debug.apk`.

## Limitações conhecidas
- O endpoint de catálogo está como placeholder em `Api.kt`; a interface abre em modo demonstração até configurar um backend HTTPS autorizado.
- A compilação automatizada não substitui testes de instalação e reprodução em aparelho físico.
- O projeto respeita as permissões de conteúdo fornecidas pelo backend; não remove bloqueios de assinatura ou entitlement.
