# NovelPlay API

API inicial de cadastro, login e permissões para o aplicativo NovelPlay.

## Deploy no Render

1. Crie um PostgreSQL no Render e copie a **Internal Database URL**.
2. Crie um Web Service conectado a este repositório.
3. Em **Root Directory**, informe `novelplay_api`.
4. Build Command: `npm install`
5. Start Command: `npm start`
6. Adicione as variáveis de ambiente abaixo no painel do Render.

| Variável | Valor |
| --- | --- |
| `DATABASE_URL` | Internal Database URL do PostgreSQL |
| `JWT_SECRET` | Segredo aleatório com pelo menos 32 caracteres |
| `ADMIN_USERNAME` | `Admin` |
| `ADMIN_EMAIL` | E-mail real do proprietário |
| `ADMIN_PASSWORD` | Senha forte com pelo menos 12 caracteres |
| `NODE_ENV` | `production` |

O serviço cria a tabela automaticamente e cria/atualiza a conta administradora na inicialização. Nunca coloque essas variáveis no código ou no GitHub.

**Importante:** não use `Admin` como senha em um serviço público. O usuário administrador pode se chamar `Admin`, mas a senha precisa ser forte e privada. A senha administrativa é atualizada a partir da variável do Render em cada inicialização.

## Rotas

- `GET /health` — verificação de saúde.
- `POST /auth/register` — body JSON: `{"username":"...","email":"...","password":"..."}`.
- `POST /auth/login` — body JSON: `{"identity":"usuário ou e-mail","password":"..."}`.
- `GET /auth/me` — requer `Authorization: Bearer TOKEN`.
- `GET /admin/users` — requer token de administrador.

As senhas são armazenadas com bcrypt. Os tokens JWT expiram em 7 dias. O papel de administrador é atribuído exclusivamente pelo servidor; o cadastro público sempre cria usuários comuns.

## Estado

Esta é a primeira etapa da autenticação. O aplicativo Flutter ainda precisa ser conectado à URL pública deste serviço e receber as telas de login/cadastro e a área administrativa. Configure primeiro o Render e teste `/health`.
