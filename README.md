# Automação de Provisionamento Pós-Imagem — Windows

Script PowerShell para automatizar o pipeline de provisionamento pós-imagem
de estações Windows em ambiente corporativo, com foco em idempotência,
retomada após reboot e logging estruturado.

## Problema

O provisionamento pós-imagem manual exigia 8 etapas sequenciais
(BIOS, hostname, patrimônio, atualização de apps, ingresso em domínio,
BitLocker, relatório, Windows Update), todas suscetíveis a erro humano
e variáveis entre técnicos. Sem padronização, o retrabalho era alto
e o tempo de entrega, imprevisível.

## Solução

Script PowerShell idempotente que verifica o estado antes de cada ação,
retoma automaticamente após reboot e registra tudo em log estruturado.

### Etapas cobertas

1. **BIOS Dell** — via Dell Command Configure (CCTK): senha admin,
   USB boot, Secure Boot e NIC boot, com fallback multi-modelo
2. **Hostname padronizado** — gerado por tipo (notebook/desktop) + serial
3. **Patrimônio** — descrição do computador no registro
4. **Winget** — atualização automática de apps instalados
5. **Ingresso em domínio** — Active Directory
6. **BitLocker** — TPM e/ou PIN, com exportação da recovery key (local + rede)
7. **Relatório consolidado** — status de cada etapa por máquina
8. **Windows Update** — via PSWindowsUpdate ou usoclient (fallback)

## Arquitetura

- **Idempotência:** cada etapa verifica estado atual antes de agir
- **Retomada pós-reboot:** arquivo sentinela + tarefa agendada (`AtLogon`)
- **Lock file:** validação de PID para evitar execução dupla
- **Logging estruturado:** `Write-Log` com timestamp, nível e arquivo por execução
- **BitLocker assíncrono:** salva recovery key imediatamente, não bloqueia operador
- **Sanitização:** credenciais não são armazenadas em código; lidas via
  variável de ambiente, parâmetro seguro ou prompt

## Stack

PowerShell 5.1 · Dell Command Configure (CCTK) · BitLocker · TPM ·
winget · Windows Update · Active Directory · Registry · Agendador de Tarefas

## Como usar

```powershell
# Modo padrão (criptografia de disco inteiro, senha BIOS via prompt)
.\Pos-Imagem.ps1

# Senha BIOS via variável de ambiente
$env:BIOS_DEFAULT_PASSWORD = "..."
.\Pos-Imagem.ps1

# Senha BIOS via parâmetro seguro + criptografia apenas do espaço usado
$pwd = Read-Host -AsSecureString "Senha BIOS"
.\Pos-Imagem.ps1 -BiosPassword $pwd -BitLockerUsedSpaceOnly


