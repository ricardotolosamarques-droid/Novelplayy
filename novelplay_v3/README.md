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
O proxy não é hospedado por este projeto. Não existe URL pública confirmada,
e a fonte pode parar de funcionar com alterações no site ReelShort.
A interface mostra erro e catálogo de demonstração quando não há serviço.
