# NovelPlay — integração com catálogos autorizados

Projeto Android Flutter que permite catálogo, busca, episódios e reprodução MP4/HLS.

## Pesquisa do Vanta Surf — 30/10/2026

O APK fornecido contém referências a `/api/playlet/index_recommend`, `/api/playlet/info`,
`/api/playlet/channel_list` e `/api/playlet/topic_video_list`. Também inclui o
domínio `vantasurf.7nkznc.com`, mas **não há confirmação de que esse host
hospede tais rotas** nem de API pública autorizada para terceiros.

**Não há integração funcional com os vídeos do Vanta Surf.** O aplicativo mostra
um aviso explícito e um catálogo de demonstração quando não existe fonte autorizada.

## Como conectar uma fonte autorizada

No GitHub, vá em Settings > Secrets and variables > Actions > Variables:
- `CATALOG_URL`: endereço HTTPS de um arquivo JSON contendo lista de novelinhas com episódios.
- OU `API_BASE_URL`: endereço HTTPS de um servidor com API liberada para terceiros.
- Opcionalmente `API_INDEX_PATH`, `API_INFO_PATH`, `API_INFO_ID_PARAM`.

O adaptador atual espera JSON via GET sem autenticação. Será necessário adaptar
ao contrato real fornecido pelo operador; rotas estáticas encontradas em APK
não comprovam método ou parâmetros. Nunca use credenciais extraídas de outro aplicativo,
nem contorne controles de acesso ou proteção dos vídeos.

## Build

Abra a aba Actions e execute **Gerar NovelPlay v3 (APK)**. Após sucesso,
baixe o artefato `NovelPlay-v3-APK` e extraia `app-release.apk`.

## Catálogo ReelShort (fonte comunitária opcional)

Referência: https://github.com/wanglinsaputra/Rest-Api-ReelShort (MIT).
O proxy expõe `/recommended` e `/episodes/{book_id}` sob
`/api/v1/reelshort`. Este adaptador lê somente títulos, capas e a
numeração dos episódios. **Não consulta `/video` nem incorpora links HLS de
conteúdo protegido.** É preciso obter autorização da plataforma/detentores dos
direitos para disponibilizar os vídeos em outro aplicativo.

Configure `REELSHORT_API_URL` como variável do GitHub Actions com a URL
completa do prefixo do proxy, por exemplo `https://SEU-SERVIDOR/api/v1/reelshort`.
O serviço de metadados do NovelPlay foi criado no plano gratuito do Render em
https://novelplay-api.onrender.com. O aplicativo usa por padrão
https://novelplay-api.onrender.com/api/v1/reelshort, sem exigir configuração
manual. A API continua **não oficial** e pode parar de funcionar se a
estrutura interna do site mudar; não oferece reprodução dos vídeos.
Para apontar a outro servidor, altere o endereço no botão de conexão.

## Assistir na página oficial (integrado ao aplicativo)

O catálogo e os números de episódios vêm do formato de metadados do
[Rest-Api-ReelShort](https://github.com/wanglinsaputra/Rest-Api-ReelShort).
O botão **Assistir no ReelShort** abre a página oficial
`https://www.reelshort.com/id/movie/{slug}-{book_id}` numa WebView do
NovelPlay. O usuário pode escolher o episódio pelo site oficial, que aplica
suas próprias regras de acesso e assinatura.

A implementação não usa o endpoint de HLS do scraper, não injeta
credenciais, não remove DRM e não desbloqueia episódios premium.
O player próprio continua disponível para catálogos com vídeos autorizados.
Caso a WebView não reproduza vídeo ou solicite uma ação incompatível com a
WebView, use **Copiar link oficial** e abra no navegador.


## Episódios dentro do NovelPlay

A partir da versão 0.4, o app exibe a lista completa de episódios consultados
na API comunitária, sem redirecionar para o site. Episódios que a própria página
pública identifica como gratuitos podem solicitar um link HLS usando
`GET /api/v1/reelshort/video/{book_id}/{numero}?filtered_title=...&chapter_id=...`
e reproduzi-lo no player Flutter. Episódios pagos permanecem bloqueados e nunca
são requisitados. A disponibilidade pode mudar; a plataforma não garante
reprodução ou autorização para uso por terceiros.


## DramaBos (versão 0.5)

A tela principal usa a API `https://dramabos.live` diretamente no celular,
com os 42 provedores anunciados no diretório público. Inclui seleção
de plataforma, pesquisa, listagem de dramas e episódios e player Flutter
para os episódios explicitamente marcados como gratuitos (`locked:false`).
Episódios bloqueados nunca solicitam URL de vídeo. Não abre sites externos.

De acordo com a documentação pública, o acesso gratuito da DramaBos
não exige chave. O serviço pode responder HTTP 403 (Cloudflare 1010)
dependendo da origem; o app informa esse erro, sem contorná-lo.
Não foi possível verificar a reprodução real na infraestrutura
do GitHub/Render porque as consultas foram bloqueadas pelo provedor.


## Integração com a pasta Google Drive

A aba **Meu Drive** consulta a pasta pública configurada no app e ordena os vídeos pelo número no nome. A pasta precisa continuar compartilhada como **Qualquer pessoa com o link — Leitor**.

Pasta configurada: `1O28a3-3bmKkVj_3dS9HlWX0Owyn3eFts`.

### Configurar a chave sem publicá-la

1. No GitHub, abra **Settings → Secrets and variables → Actions → New repository secret**.
2. Nome do secret: `DRIVE_API_KEY`.
3. Cole o valor da chave da Google Drive API e salve. Não coloque a chave em arquivos do projeto nem em mensagens públicas.
4. Abra **Actions**, execute novamente o workflow **Preparar Android e obter SHA-1 do Novelinha** e aguarde a compilação.
5. Baixe o artefato `novelinha-debug-apk` quando a execução terminar com sucesso.

O workflow injeta a chave no build usando `--dart-define`; a chave não é gravada no código-fonte. Como toda chave incluída em um APK pode ser extraída do aplicativo, restrinja-a no Google Cloud Console à Drive API e acompanhe as cotas.

**Limitação que precisa ser testada:** a listagem de arquivos públicos usa a API oficial do Drive. A reprodução também tenta obter o conteúdo pela API, mas o Google pode exigir autorização adicional ou limitar downloads/requisições. O Drive não é uma CDN de streaming; não há garantia de reprodução contínua nem de tráfego ilimitado. Se o vídeo não tocar, a tela mostrará o erro retornado pelo Google.


## Estado da autenticação Google Drive — 05/11/2026

A tela **Meu Drive** ainda usa a chave `DRIVE_API_KEY` e consulta uma pasta compartilhada publicamente. Isso **não é ainda a integração OAuth Google com escopo somente leitura** definida para a versão final. A migração para login Google e token OAuth `drive.readonly` permanece pendente; não considere a integração autenticada concluída.

O workflow **Preparar Android e obter SHA-1 do Novelinha** foi corrigido para criar um keystore de depuração antes de executar `signingReport` e falhar caso o SHA-1 não apareça. O SHA-1 produzido por essa chave temporária corresponde somente ao APK gerado naquela mesma execução. Antes de distribuir builds futuras com OAuth, será necessário configurar uma chave de assinatura persistente e reutilizá-la em todos os builds.
