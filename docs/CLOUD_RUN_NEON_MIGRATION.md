# Preparação de migração: Cloud Run + Neon

Status: preparação técnica, sem deploy e sem alteração no ambiente de produção.

## Objetivo
Preparar uma implantação paralela da API NovelPlay no Google Cloud Run com PostgreSQL gerenciado no Neon, mantendo Render intacto até que a nova versão seja testada e aprovada.

## Inspeção inicial
- API Node.js 20 em `novelplay_api/`.
- Inicialização do PostgreSQL e criação/atualização de tabelas ocorrem no boot (`initializeDatabase`).
- O servidor escuta em `0.0.0.0` e usa `process.env.PORT`, compatível com o contrato HTTP do Cloud Run.
- FFmpeg é chamado pelo backend para operações de vídeo.
- Há tarefas assíncronas iniciadas com `setImmediate` depois de responder às requisições: processamento de uploads e recuperação de vídeos do Google Drive.

## Bloqueio técnico que precisa ser resolvido antes do deploy
O processamento de upload/recuperação não pode depender de tarefas em segundo plano iniciadas após a resposta HTTP se o Cloud Run estiver no modo padrão de CPU por requisição. A documentação do Cloud Run alerta que a CPU fora da requisição não fica disponível nesse modo. Precisamos migrar esses trabalhos para uma execução confiável (por exemplo, Cloud Tasks chamando um endpoint worker por tarefa, com retries e idempotência) ou escolher uma configuração de instância com CPU contínua e contabilizar o custo. Não habilitar CPU contínua nem instâncias mínimas sem aprovação de custo.

## Preservação de dados e credenciais
- Não apontar o aplicativo para a nova API antes de copiar e validar os dados.
- Exportar/importar o PostgreSQL somente quando o banco Render estiver acessível; não apagar nem modificar a origem.
- O segredo `JWT_SECRET` é usado também para derivar a chave que cifra o refresh token do Google Drive no banco. Para manter a conexão atual do Drive, a migração deve preservar exatamente o mesmo `JWT_SECRET`. Não gerar um novo segredo durante a migração.
- Manter secretos fora do Git: `DATABASE_URL`, `JWT_SECRET`, `ADMIN_PASSWORD`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` e demais variáveis OAuth necessárias.
- Validar login, catálogo, conexão Google Drive e upload de um episódio de teste antes de qualquer troca de URL no app.

## Custos e segurança
- Nenhum serviço Cloud Run, tarefa, banco pago ou recurso faturável foi criado.
- O free tier não é garantia de custo zero; excedentes e recursos auxiliares podem gerar cobrança.
- Configurar orçamento/alertas e revisar a estimativa antes de habilitar faturamento ou deploy.
- Manter Render como rollback até aprovação explícita.

## Próximas etapas
1. Conectar o Neon para criar e inspecionar o banco de destino.
2. Obter acesso autorizado ao projeto Google Cloud e confirmar o faturamento/limites sem ativar recursos pagos.
3. Implementar o worker confiável para uploads e recuperação.
4. Preparar imagem Docker e configuração Cloud Run.
5. Fazer backup e cópia de dados quando a origem estiver acessível.
6. Testar em paralelo; só então propor a troca da URL do aplicativo.
