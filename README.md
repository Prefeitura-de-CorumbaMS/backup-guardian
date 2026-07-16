# Backup Guardian

Sistema automatizado de backup incremental para servidores Debian Linux, com detecção inteligente de mudanças por hash SHA256, backup diário sem compressão para acesso rápido, arquivamento mensal automático e notificações detalhadas por e-mail.

## �️ Requisitos e Compatibilidade

**Sistema Operacional:**
- ✅ **Linux (Debian/Ubuntu)** - Totalmente suportado e testado
- ⚠️ **Outras distribuições Linux** - Compatível (ajustar gerenciador de pacotes)
- ⚠️ **macOS** - Requer Docker ou adaptação manual
- ⚠️ **Windows** - Requer WSL2 (Windows Subsystem for Linux)

**Dependências:**
- `bash` 4.0+
- `systemd` (agendamento)
- `jq` (manipulação JSON)
- `zip/unzip` (compressão)
- `msmtp` ou `mailutils` (envio de e-mails)
- GNU coreutils (`df`, `sha256sum`, `find`, `awk`, `sed`)

**Privilégios:**
- Instalação requer `root` (sudo)
- Execução automática via systemd

## �📑 Índice

- [Características Principais](#-características-principais)
- [Como Funciona](#-como-funciona)
- [Estrutura do Repositório](#estrutura-do-repositório)
- [Estrutura Gerada por Aplicação](#estrutura-gerada-por-aplicação)
- [Dependências](#dependências)
- [Guia de Configuração Passo a Passo](#guia-de-configuração-passo-a-passo)
  - [Passo 1: Preparar Grupo no Servidor](#passo-1-preparar-grupo-no-servidor-debian)
  - [Passo 2: Configurar SMTP](#passo-2-configurar-smtp-gmail)
  - [Passo 3: Criar Arquivo .env](#passo-3-criar-arquivo-de-configuração-env)
  - [Passo 4: Transferir para Servidor](#passo-4-transferir-para-o-servidor)
- [Instalação](#instalação)
- [Operação](#operação)
- [Tipos de Notificações](#-tipos-de-notificações-por-e-mail)
- [Segurança e Robustez](#-segurança-e-robustez)
- [FAQ](#-faq---perguntas-frequentes)
- [Desinstalação](#desinstalação)

## 🎯 Características Principais

- ✅ **Backup Diário Inteligente:** Copia apenas quando detecta mudanças reais no conteúdo
- ✅ **Acesso Rápido:** Arquivos descomprimidos em `backup_atual/` para restauração imediata
- ✅ **Arquivamento Mensal:** ZIP automático no início de cada mês com dados do mês anterior
- ✅ **Atomic Swap:** Sempre mantém backup válido, mesmo em caso de falha
- ✅ **Retry Automático:** 3 tentativas com backoff exponencial em falhas temporárias
- ✅ **Notificações Detalhadas:** E-mails formatados com estatísticas e alertas
- ✅ **Gerenciamento de Espaço:** Verifica disco antes de backup e limpa ZIPs antigos (>12 meses)
- ✅ **Idempotência:** Não executa múltiplas vezes no mesmo dia
- ✅ **Multi-Aplicação:** Suporta múltiplos projetos com configurações independentes
- ✅ **Zero Manutenção:** Agendamento via systemd timer, totalmente automatizado

## 📋 Como Funciona

### Pipeline de Execução

O motor principal (`scripts/backup.sh`) é executado diariamente às 00:00 via systemd timer e processa cada aplicação definida em `/etc/backup-guardian/conf.d/*.conf`:

```
1. Aquisição de Lock
   └─> Previne execuções concorrentes (backup.lock)

2. Cálculo de Hash SHA256
   └─> Hash baseado no CONTEÚDO dos arquivos (ignora timestamp/tamanho)

3. Detecção de Mudança
   ├─ SEM MUDANÇA:
   │  └─> Incrementa contador
   │      └─> Após 3 dias: registra "Aguardando alterações" (uma única vez)
   │
   └─ COM MUDANÇA:
      ├─> Verifica idempotência (já rodou hoje?)
      ├─> Verifica espaço em disco (mínimo 1GB)
      ├─> Detecta mudança de mês
      │   └─> Se mudou: cria ZIP do mês anterior ANTES de atualizar
      ├─> Backup diário (Atomic Swap):
      │   ├─> Copia para backup_novo/
      │   ├─> Swap: backup_atual → backup_antigo
      │   ├─> Swap: backup_novo → backup_atual
      │   └─> Remove backup_antigo
      ├─> Atualiza hash e estado
      └─> Envia notificação por e-mail

4. Liberação de Lock
   └─> Sempre executado (via trap), mesmo em caso de erro
```

### Arquitetura Modular

O sistema é composto por scripts modulares independentes, cada um com responsabilidade única.

## Estrutura do repositório

```
install.sh                 Instalador único (executar como root)
uninstall.sh               Remove serviço/timer/scripts (preserva dados e configs)
scripts/
  backup.sh                Orquestrador principal (executado pelo systemd)
  utils.sh                 Funções utilitárias (timestamp, ensure_dir, atomic_move)
  logger.sh                Sistema de logging estruturado (log_info, log_error)
  lock.sh                  Controle de concorrência (acquire_lock, release_lock)
  state.sh                 Gerenciamento de estado JSON via jq
  hash.sh                  Cálculo de hash SHA256 baseado em conteúdo
  mail.sh                  Sistema de notificações por e-mail (sucesso/erro/alerta)
  verify.sh                Lógica de "sem mudanças" / "aguardando alterações"
systemd/
  backup_guardian.service  Unit oneshot que executa scripts/backup.sh
  backup_guardian.timer    Timer diário às 00:00
conf/
  arquivo.conf             Configuração de exemplo (sem dados sensíveis)
  env.example              Modelo dos dados sensíveis (caminhos e e-mail)
  arquivo.env              Dados sensíveis reais (NÃO versionado, veja .gitignore)
  exemplo.conf.dist        Modelo de .conf para novas aplicações
  msmtprc.gmail.example    Modelo de configuração SMTP via Gmail
```

### Dados sensíveis (.env)

Caminhos reais do servidor e o e-mail de destino ficam em `conf/<app_id>.env`, que é
ignorado pelo git (`.gitignore`). O `.conf` correspondente (versionado) apenas faz
`source` desse arquivo. Antes de rodar o `install.sh` pela primeira vez:

```bash
cp conf/env.example conf/arquivo.env
nano conf/arquivo.env   # preencha EMAIL_TO e os caminhos (CAMINHO_1, CAMINHO_2, etc.)
```

O modelo usa variáveis genéricas `CAMINHO_N` (N = 1, 2, 3...), permitindo adicionar
quantos caminhos precisar sem limitações. Cada `CAMINHO_N` pode ser qualquer arquivo
ou diretório que você deseja incluir no backup.

O `install.sh` copia `conf/*.conf` **e** o `.env` correspondente para
`/etc/backup-guardian/conf.d/` (modo `600`), sem sobrescrever arquivos já existentes.

## Estrutura gerada por aplicação

Para cada `.conf`, o motor cria `<BACKUP_ROOT>/<APP_ID>_arquivos/`, por exemplo para `minha_aplicacao`:

```
/backups/minha_aplicacao_arquivos/
    backup_atual/                           ← Backup diário (arquivos descomprimidos)
        app/
            public/
            .env
        frontend/
            public/
            .env
    minha_aplicacao_backup_mensal_2026-06.zip  ← ZIP mensal (criado no início do mês)
    minha_aplicacao_backup_mensal_2026-07.zip  ← ZIP do mês anterior
    hash.sha256
    estado.json
    backup.log
    erro.log
    backup.lock          (existe apenas durante a execução)
```

**Funcionamento:**
- **Backup diário:** Copia arquivos para `backup_atual/` (SEM criar ZIP)
- **ZIP mensal:** No primeiro dia do mês, cria ZIP do mês anterior
- **Vantagem:** Acesso rápido aos arquivos atuais + arquivamento mensal compactado

`estado.json`:

```json
{
  "ultimoHash": "...",
  "ultimoBackup": "2026-07-15 00:00:01",
  "mesBackup": "2026-07",
  "contadorSemMudanca": 0,
  "aguardando": false
}
```

## Início Rápido

### Checklist de Configuração

Antes de instalar no servidor, você precisa:

**No Servidor Debian:**
- [ ] Instalar dependências (zip, unzip, jq, mailutils, msmtp)

**No Seu Computador (Windows):**
- [ ] Gerar senha de app no Gmail
- [ ] Criar arquivo `conf/msmtprc` com credenciais SMTP
- [ ] Criar arquivo `conf/arquivo.env` com TODAS as configurações (APP_NAME, APP_ID, EMAIL_TO, CAMINHO_N, ITEMS)
- [ ] Comprimir e enviar projeto para o servidor

**No Servidor Debian (após transferir):**
- [ ] Copiar msmtprc para /etc/msmtprc
- [ ] Testar envio de e-mail
- [ ] Executar ./install.sh
- [ ] Verificar backup criado e e-mail recebido

---

## Configuração Passo a Passo

Siga estas etapas detalhadamente para configurar o sistema corretamente.

### Passo 1: Instalar dependências no servidor Debian

```bash
sudo apt-get update
sudo apt-get install -y zip unzip jq mailutils msmtp msmtp-mta
```

**Pacotes necessários:**
- `zip/unzip` - criação e validação de arquivos ZIP
- `jq` - manipulação de JSON (estado.json)
- `mailutils` - comando `mail` para notificações
- `msmtp/msmtp-mta` - agente SMTP para envio de e-mails

`bash`, `find`, `sha256sum` e `systemd` já fazem parte do Debian padrão.

### Passo 2: Configurar e-mail (SMTP com Gmail)

#### 2.1 Gerar senha de app no Gmail

1. Acesse: https://myaccount.google.com/apppasswords
2. Ative **verificação em 2 etapas** (se ainda não tiver)
3. Crie uma senha de app para "Mail"
4. **Copie a senha** (16 caracteres) - **IMPORTANTE:** remova todos os espaços!

#### 2.2 Criar arquivo msmtprc

**No seu computador local**, edite `conf/msmtprc` com:

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           SEU_EMAIL@gmail.com
user           SEU_EMAIL@gmail.com
password       SENHA_DE_APP_SEM_ESPACOS

account default : gmail
```

**Substitua:**
- `SEU_EMAIL@gmail.com` - seu e-mail Gmail
- `SENHA_DE_APP_SEM_ESPACOS` - a senha de 16 caracteres **sem espaços**

**Nota:** O Gmail mostra a senha como `abcd efgh ijkl mnop`, mas você deve usar `abcdefghijklmnop`

#### 2.3 Instalar no servidor (após transferir o projeto)

No servidor, navegue até onde você descomprimiu o projeto e execute:

```bash
# Substitua /caminho_do_projeto pelo local onde você descomprimiu
cd /caminho_do_projeto/backup-guardian

sudo cp conf/msmtprc /etc/msmtprc
sudo chmod 644 /etc/msmtprc
sudo chown root:root /etc/msmtprc
sudo touch /var/log/msmtp.log
sudo chmod 666 /var/log/msmtp.log
```

**Exemplo:** Se você descomprimiu em `/tmp`, use `cd /tmp/backup-guardian`

#### 2.4 Testar envio de e-mail

```bash
echo "Teste de configuração" | mail -s "Teste Backup Guardian" seu-email@example.com
```

Se não funcionar, verifique: `tail -f /var/log/msmtp.log`

### Passo 3: Criar arquivo de configuração (.env)

**IMPORTANTE:** Todas as configurações sensíveis ficam no arquivo `.env` (não versionado).
O arquivo `.conf` é apenas um wrapper genérico que carrega o `.env`.

**No seu computador local**, crie `conf/arquivo.env` com:

```bash
# ============================================================================
# CONFIGURAÇÕES DA APLICAÇÃO
# ============================================================================

APP_NAME="Nome da Sua Aplicação"     # Ex: "Portal Corporativo"
APP_ID="minha_aplicacao"              # Ex: "portal_corp" (sem espaços)

# Diretório raiz - o sistema criará ${BACKUP_ROOT}/${APP_ID}_arquivos/
BACKUP_ROOT="/backups"                # Ex: /backups (raiz do HD)
                                      # Ex: /mnt/storage (HD montado)
                                      # Ex: /dados/backups (subpasta)

GROUP="backup-users"                  # Grupo de permissões

# ============================================================================
# NOTIFICAÇÕES
# ============================================================================

EMAIL_TO="seu-email-destino@example.com"

# ============================================================================
# CAMINHOS MONITORADOS
# ============================================================================

# Defina os caminhos absolutos dos arquivos/pastas para backup
CAMINHO_1="/var/www/aplicacao/public"
CAMINHO_2="/var/www/aplicacao/.env"
CAMINHO_3="/var/www/api/uploads"
CAMINHO_4="/etc/nginx/sites-available/app.conf"
# CAMINHO_5="/outro/caminho/se/precisar"
# ... adicione quantos precisar

# ============================================================================
# MAPEAMENTO DE ITENS NO ZIP
# ============================================================================

# ITEMS define como organizar os arquivos DENTRO do ZIP mensal
# Formato: "${CAMINHO_N}|caminho/dentro/do/zip"
#
# Exemplo: Se você definiu CAMINHO_1="/var/www/site/public"
#          E configurou "${CAMINHO_1}|frontend/public"
#          O ZIP terá: frontend/public/ (com conteúdo de /var/www/site/public)
#
ITEMS=(
  "${CAMINHO_1}|app/public"
  "${CAMINHO_2}|app/.env"
  "${CAMINHO_3}|api/uploads"
  "${CAMINHO_4}|config/nginx.conf"
)
```

**Resumo das Configurações:**

| Variável | Descrição | Exemplo |
|----------|-----------|---------|
| `APP_NAME` | Nome descritivo da aplicação | "Portal Corporativo" |
| `APP_ID` | Identificador único (sem espaços) | "portal_corp" |
| `BACKUP_ROOT` | Onde salvar os backups no servidor | "/backups" |
| `GROUP` | Grupo de permissões (deve existir) | "backup-users" |
| `EMAIL_TO` | E-mail para notificações | "admin@example.com" |
| `CAMINHO_N` | Caminhos absolutos para backup | "/var/www/app/public" |
| `ITEMS` | Organização dentro do ZIP | `"${CAMINHO_1}\|app/public"` |

**🔒 Segurança:** 
- `arquivo.conf` é versionado mas NÃO contém dados sensíveis
- `arquivo.env` contém TODAS as configurações e NÃO é versionado (.gitignore)

### Passo 4: Transferir para o servidor

#### 4.1 Comprimir o projeto (Windows PowerShell)

```powershell
# Navegue até o diretório onde está o projeto
cd c:\Users\SEU_USUARIO\Documents

# Comprima o projeto
Compress-Archive -Path backup-guardian -DestinationPath backup-guardian.zip -Force
```

**Ajuste:** Substitua `SEU_USUARIO` pelo seu nome de usuário do Windows

#### 4.2 Enviar para o servidor

Use SCP, WinSCP, FileZilla ou outro método. Escolha um diretório temporário:

```bash
# Exemplo usando /tmp (ou use /home/usuario, /opt, etc.)
scp backup-guardian.zip usuario@IP_DO_SERVIDOR:/tmp/
```

#### 4.3 Descomprimir no servidor

```bash
ssh usuario@IP_DO_SERVIDOR

# Navegue até onde você enviou o arquivo
cd /tmp  # ou o diretório que você escolheu

# Descomprima
unzip backup-guardian.zip

# Agora você tem o projeto em /tmp/backup-guardian (ou outro diretório)
```

**Importante:** Lembre-se do caminho onde descomprimiu, você precisará dele no Passo 2.3 e na instalação.

## Instalação

No servidor Debian, após completar todos os passos de configuração, navegue até o diretório do projeto:

```bash
# Substitua pelo caminho onde você descomprimiu o projeto
cd /caminho/do/projeto/backup-guardian

# Execute o instalador
sudo ./install.sh
```

**Exemplo:** Se descomprimiu em `/tmp`, use `cd /tmp/backup-guardian`

O instalador:

- ✅ Verifica dependências e privilégios de root
- ✅ Cria o grupo configurado (se não existir)
- ✅ Copia os scripts para `/opt/backup-guardian/scripts`
- ✅ Copia os `.conf` e o `.env` para `/etc/backup-guardian/conf.d/` (modo `600`)
- ✅ Instala e habilita `backup_guardian.service`/`.timer` no systemd
- ✅ Executa um backup inicial (gera hash, `estado.json`, ZIP corrente e ZIP mensal)
- ✅ Exibe a próxima execução agendada

### Verificar instalação

```bash
# Status do timer
systemctl status backup_guardian.timer

# Próxima execução
systemctl list-timers backup_guardian.timer

# Verificar estrutura criada (ajuste o APP_ID)
ls -lh /backups/minha_aplicacao_arquivos/

# Deve mostrar:
# - backup_atual/          (backup diário descomprimido)
# - hash.sha256            (hash do conteúdo)
# - estado.json            (estado do sistema)
# - backup.log             (log de operações)
# - erro.log               (log de erros)

# Ver conteúdo do backup atual
tree /backups/minha_aplicacao_arquivos/backup_atual/

# Ver logs
cat /backups/minha_aplicacao_arquivos/backup.log
cat /backups/minha_aplicacao_arquivos/estado.json | jq .

# Se já passou um mês, verá também:
# - minha_aplicacao_backup_mensal_2026-07.zip
```

**✅ Você deve ter recebido um e-mail de notificação do backup.**

## Operação

A partir da instalação, tudo é automático via `systemd timer`, diariamente às 00:00.
Comandos úteis:

```bash
systemctl status backup_guardian.timer
systemctl list-timers backup_guardian.timer
sudo systemctl start backup_guardian.service   # forçar execução manual
journalctl -u backup_guardian.service           # log do systemd
```

Logs de negócio ficam em `backup.log`/`erro.log` dentro de cada diretório
`<BACKUP_ROOT>/<APP_ID>_arquivos/`.

## 📧 Tipos de Notificações por E-mail

O sistema envia e-mails formatados e informativos em diferentes situações:

### ✅ Backup Bem-Sucedido
```
Assunto: ✅ [BACKUP] Nome da Aplicação - Sucesso

Conteúdo:
- Data/Hora da execução
- Nome do servidor
- Estatísticas (itens copiados/total)
- Diretório do backup
- Lembrete para sincronizar com Google Drive
```

### ⚠️ Backup Parcial (com erros)
```
Assunto: ⚠️ [AVISO] Backup Parcial - Nome da Aplicação

Conteúdo:
- Itens copiados vs total
- Número de erros encontrados
- Taxa de sucesso (%)
- Caminho do log de erros
- Ações recomendadas
```

### 🔴 Espaço em Disco Insuficiente
```
Assunto: ⚠️ [ALERTA] Espaço em Disco Insuficiente

Conteúdo:
- Tamanho total do disco
- Espaço usado (MB e %)
- Espaço disponível
- Espaço necessário
- Quanto falta
- Ações urgentes necessárias
```

### ❌ Erro Crítico
```
Assunto: ❌ [ERRO] Backup Guardian - Etapa

Conteúdo:
- Data/Hora do erro
- Etapa onde falhou
- Descrição do erro
- Ação necessária
```

## Adicionando uma nova aplicação (expansão)

1. Copie `conf/exemplo.conf.dist` para `/etc/backup-guardian/conf.d/<nome>.conf`.
2. Crie `<nome>.env` ao lado (mesmo diretório) com:
   - `EMAIL_TO` - destinatário das notificações
   - `CAMINHO_1`, `CAMINHO_2`, `CAMINHO_3`, etc. - caminhos absolutos a monitorar
   - Adicione quantos `CAMINHO_N` precisar (não há limite)
3. No `.conf`, ajuste:
   - `APP_NAME` - nome descritivo da aplicação
   - `APP_ID` - identificador único (usado em nomes de arquivo)
   - `BACKUP_ROOT` - diretório onde os backups serão salvos
   - Array `ITEMS` - mapeie cada `CAMINHO_N` para seu destino no ZIP
4. Nenhuma alteração em `scripts/` é necessária — o próximo ciclo do timer já processa a nova app.

**Exemplo de ITEMS flexível:**
```bash
ITEMS=(
  "${CAMINHO_1}|aplicacao/public"
  "${CAMINHO_2}|aplicacao/.env"
  "${CAMINHO_3}|api/uploads"
  "${CAMINHO_4}|nginx/site.conf"
  "${CAMINHO_5}|scripts/deploy.sh"
)
```

## Permissões

Diretórios de backup são criados com modo `2775` e grupo `seu_grupo`, garantindo herança de grupo
para novos arquivos/subpastas.

## 🔒 Segurança e Robustez

### Mecanismos de Segurança

- **Strict Mode:** Todos os scripts usam `set -euo pipefail` (falha rápida em erros)
- **Trap Handlers:** `trap` garante liberação de lock mesmo em falhas inesperadas
- **Atomic Operations:** Operações críticas usam padrão atomic swap (sempre há backup válido)
- **Validação de ZIP:** Todo ZIP é validado com `zip -T` antes de ser considerado válido
- **Permissões Restritas:** `.env` com modo `600`, apenas root pode ler
- **Separação de Dados:** Configurações sensíveis separadas de código versionado

### Mecanismos de Robustez

- **Retry com Backoff:** 3 tentativas automáticas com espera exponencial (1s, 2s, 4s)
- **Idempotência:** Não executa múltiplas vezes no mesmo dia
- **Verificação de Espaço:** Valida espaço em disco antes de iniciar backup
- **Atomic Swap Pattern:** 
  ```
  backup_atual → backup_antigo (preserva)
  backup_novo → backup_atual (ativa)
  backup_antigo → delete (só após sucesso)
  ```
- **Cleanup Automático:** Remove ZIPs mensais com mais de 12 meses
- **Lock de Concorrência:** Previne execuções simultâneas
- **Logging Estruturado:** Logs separados (backup.log + erro.log)
- **Notificações Proativas:** E-mails em todas as situações (sucesso/erro/alerta)

## Verificação com ShellCheck

```bash
shellcheck install.sh uninstall.sh scripts/*.sh
```

## Desinstalação

```bash
sudo ./uninstall.sh
```

Remove o serviço/timer e os scripts instalados, preservando os dados em `/seu_caminho_para_o_backup` e as
configurações em `/etc/backup-guardian/conf.d`.

---

## ❓ FAQ - Perguntas Frequentes

### Como funciona o backup diário vs mensal?

**Backup Diário:**
- Copia arquivos para `backup_atual/` (SEM compressão)
- Rápido e com acesso imediato aos arquivos
- Substitui o backup anterior (atomic swap)

**ZIP Mensal:**
- Criado automaticamente no 1º dia do mês
- Contém os dados do **mês anterior**
- Mantido por 12 meses (depois é deletado automaticamente)

### Por que não criar ZIP diariamente?

- **Performance:** Copiar arquivos é muito mais rápido que criar ZIP
- **Acesso:** Arquivos descomprimidos permitem restauração imediata
- **Eficiência:** ZIP mensal é suficiente para arquivamento histórico

### Como restaurar um backup?

**Backup Atual (mais recente):**
```bash
# Copiar diretamente de backup_atual/
cp -a /backups/app_arquivos/backup_atual/app/public /var/www/app/
```

**Backup Mensal (histórico):**
```bash
# Extrair ZIP do mês desejado
tar -xzf /backups/app_arquivos/app_backup_mensal_2026-07.tar.gz -C /tmp/restore/
cp -a /tmp/restore/app/public /var/www/app/
```

### O que acontece se o backup falhar?

1. **Lock não liberado:** Sistema detecta e aborta próxima execução
2. **Erro parcial:** Envia e-mail com detalhes dos erros
3. **Erro crítico:** Mantém backup anterior válido (atomic swap)
4. **Disco cheio:** Detecta antes de iniciar e envia alerta

### Como adicionar mais caminhos para backup?

Edite `/etc/backup-guardian/conf.d/arquivo.env`:

```bash
# Adicione novos caminhos
CAMINHO_5="/novo/caminho"
CAMINHO_6="/outro/caminho"

# Atualize o array ITEMS
ITEMS=(
  "${CAMINHO_1}|app/public"
  "${CAMINHO_2}|app/.env"
  "${CAMINHO_3}|api/uploads"
  "${CAMINHO_4}|config/nginx.conf"
  "${CAMINHO_5}|novo/destino"      # NOVO
  "${CAMINHO_6}|outro/destino"     # NOVO
)
```

Próxima execução já incluirá os novos caminhos.

### Como testar o backup manualmente?

```bash
# Forçar execução imediata
sudo systemctl start backup_guardian.service

# Acompanhar em tempo real
sudo journalctl -u backup_guardian.service -f

# Verificar resultado
cat /backups/app_arquivos/backup.log
```

### E-mails não estão sendo enviados, o que fazer?

```bash
# 1. Testar msmtp diretamente
echo "Teste" | mail -s "Teste" seu-email@example.com

# 2. Verificar log do msmtp
tail -f /var/log/msmtp.log

# 3. Verificar configuração
cat /etc/msmtprc

# 4. Problemas comuns:
# - Senha com espaços (remova os espaços)
# - Senha incorreta (gere nova no Google)
# - Verificação em 2 etapas desativada (ative)
# - Permissões incorretas (chmod 644 /etc/msmtprc)
```

### Como mudar o horário de execução?

Edite `/etc/systemd/system/backup_guardian.timer`:

```ini
[Timer]
OnCalendar=*-*-* 02:00:00  # Mude para 02:00
```

Depois:
```bash
sudo systemctl daemon-reload
sudo systemctl restart backup_guardian.timer
systemctl list-timers backup_guardian.timer  # Verificar
```

### Quanto espaço em disco é necessário?

**Mínimo:** 1GB livre (verificação automática)

**Recomendado:** 
- Tamanho dos arquivos monitorados × 2 (backup_atual + margem)
- + 12 ZIPs mensais (depende do tamanho comprimido)

**Exemplo:**
- Arquivos monitorados: 500MB
- backup_atual/: ~500MB
- 12 ZIPs mensais: ~12 × 200MB (comprimido) = 2.4GB
- **Total:** ~3GB

### Como monitorar o sistema?

```bash
# Status geral
systemctl status backup_guardian.timer

# Próximas execuções
systemctl list-timers

# Logs do systemd
journalctl -u backup_guardian.service --since today

# Logs de negócio
tail -f /backups/*/backup.log

# Estado de cada aplicação
find /backups -name "estado.json" -exec jq . {} \;
```

---

## 📝 Licença

Este projeto é de código aberto. Use, modifique e distribua livremente.

## 🤝 Contribuições

Contribuições são bem-vindas! Abra issues ou pull requests no repositório.
