# DramaBos — integração opcional do NovelPlay

A nova seção do aplicativo mostra os 42 provedores registrados pela DramaBos.
As buscas e listas de episódios usam apenas nossa API do Render.

- GET /api/dramabos/providers: diretório público das 42 plataformas.
- GET /api/dramabos/search/{provider}?keyword=...: busca metadados.
- GET /api/dramabos/episodes/{provider}/{drama_id}: lista episódios.

As duas últimas rotas exigem configurar DRAMABOS_API_KEY como segredo
no serviço novelplay-api do Render. A chave não deve ser publicada em
GitHub nem embutida no APK. O plano gratuito anunciado pela DramaBos
permite 1.000 requisições/mês (sujeito a alterações).

A DramaBos não prova nas condições públicas que pode sublicenciar
a reprodução de filmes e séries de terceiros. Por isso, a nova seção
exibe apenas metadados, não vídeos, até confirmação de autorização.
O ReelShort integrado anteriormente permanece disponível separadamente.
