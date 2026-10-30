# API de catálogo ReelShort para o NovelPlay

Adaptador em Node.js (sem dependências externas) para consultar **metadados**
públicos: títulos, capas, coleções e a numeração de episódios. Desenvolvido
com base no formato de rotas e no estudo do projeto de código aberto
[wanglinsaputra/Rest-Api-ReelShort](https://github.com/wanglinsaputra/Rest-Api-ReelShort)
(MIT). Este serviço **não retorna URLs HLS nem desbloqueia conteúdo**.

## Executar

Requer Node.js 20+:

```bash
cd reelshort_metadata_api
npm test
npm start
```

O serviço usa a porta `PORT` (padrão: 3000). Rotas:

- `GET /health`
- `GET /api/v1/reelshort/recommended`
- `GET /api/v1/reelshort/newrelease`
- `GET /api/v1/reelshort/dramadub`
- `GET /api/v1/reelshort/search?keywords=amor`
- `GET /api/v1/reelshort/episodes/{book_id}?filtered_title={slug}`

## Publicação no Render

Crie um **Web Service gratuito** apontando para este repositório GitHub,
branch `main`, runtime **Node**:

- Build command: `cd reelshort_metadata_api && npm install`
- Start command: `cd reelshort_metadata_api && npm start`

Depois, no NovelPlay, abra o ícone de conexão e cole
`https://seu-servico.onrender.com/api/v1/reelshort`.

Este serviço usa a estrutura interna de páginas do ReelShort, que pode
mudar sem aviso. Ele não é uma API oficial, não possui garantia de
disponibilidade e pode estar sujeito a restrições de uso da plataforma.
Obtenha autorização para usos além de consultar metadados publicamente
exibidos. Para assistir, use a plataforma oficial ou conteúdo autorizado.


## Reprodução de episódios gratuitos

A API expõe `GET /api/v1/reelshort/video/{book_id}/{episode_num}` com os
parâmetros `filtered_title` e `chapter_id`. O endpoint revalida o
identificador, a lista pública e o início dos episódios pagos, liberando
apenas vídeos anteriores ao limite de pagamento (comparação conservadora).
A API não obtém acesso pago, não solicita credenciais e não transmite a
mídia pelo Render; devolve o HTTPS da fonte somente quando o episódio
está publicamente disponível. Status 403 indica episódio pago/bloqueado.
