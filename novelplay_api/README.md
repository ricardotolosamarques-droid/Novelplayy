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


## Google Drive OAuth e upload de episódios

O backend usa um cliente OAuth do tipo **Aplicativo da Web**. No Google Cloud Console, deixe **Origens JavaScript autorizadas** vazio e cadastre esta URI exata em **URIs de redirecionamento autorizados**:

`https://novelplay-api-ee5f.onrender.com/google-drive/callback`

Configure no serviço Render, em Environment:

| Variável | Valor |
| --- | --- |
| `GOOGLE_CLIENT_ID` | ID do cliente OAuth do tipo Aplicativo da Web |
| `GOOGLE_CLIENT_SECRET` | Segredo do mesmo cliente OAuth |
| `GOOGLE_REDIRECT_URI` | `https://novelplay-api-ee5f.onrender.com/google-drive/callback` |
| `GOOGLE_DRIVE_FOLDER_ID` | Opcional; pasta principal já usada pela aba Meu Drive |

Se `GOOGLE_DRIVE_FOLDER_ID` não for definida, o backend usa a pasta configurada no aplicativo (`1O28a3-3bmKkVj_3dS9HlWX0Owyn3eFts`). Cada importação cria/localiza a subpasta da novelinha dentro dela e envia os episódios nessa pasta.

A conexão é iniciada pelo painel administrativo do app em `GET /admin/google-drive/connect`; o retorno é tratado por `GET /google-drive/callback`. O refresh token é armazenado cifrado no PostgreSQL. Mantenha `JWT_SECRET` estável: ele também protege a chave usada para cifrar esse token.

**Permissões:** a implementação atual solicita `https://www.googleapis.com/auth/drive`, com leitura e escrita, porque precisa criar pastas, enviar vídeos, listar arquivos e substituir arquivos antigos durante a recuperação. Portanto, a integração OAuth atual **não é somente leitura**. Um escopo somente leitura impediria os uploads. A redução para `drive.file` exigiria ajustar a seleção/acesso à pasta existente e validar a recuperação de arquivos; não troque o escopo sem revisar esses fluxos.

Nunca envie o Client Secret ou tokens em mensagens, commits ou APKs. Eles pertencem somente às variáveis protegidas do Render.
