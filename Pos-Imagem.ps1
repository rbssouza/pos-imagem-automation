<#
.SYNOPSIS
    Pós-Imagem Windows — Automação de Provisionamento Enterprise
.DESCRIPTION
    Pipeline idempotente de configuração pós-imagem para estações Windows.
    Executa 8 etapas com verificação de estado, retomada pós-reboot,
    logging estruturado e relatório final consolidado.
.PARAMETER BiosPassword
    Senha admin da BIOS como SecureString. Se omitida, lê de
    $env:BIOS_DEFAULT_PASSWORD ou solicita via prompt seguro.
.PARAMETER BitLockerUsedSpaceOnly
    Criptografa apenas o espaço usado (mais rápido em discos grandes).
.NOTES
    Versão    : 33.0 (Portfolio Edition)
    Requisitos: PowerShell 5.1+, admin, Windows 10/11 Pro/Enterprise+
#>
[CmdletBinding()]
param(
    [SecureString]$BiosPassword,
    [switch]$BitLockerUsedSpaceOnly
)

# ============================================================
# CONFIGURAÇÃO — ajuste para o seu ambiente
# ============================================================
$Config = @{
    CompanyName    = "EMPRESA"
    DomainName     = "empresa.local"
    FileServer     = "fileserver01"
    BitLockerShare = "\\fileserver01\Share$\BitLocker"
    WorkDir        = "C:\Provisioning"
    ComputerPrefix = "WS"
    LocationList   = @(
        @{ Codigo = "1"; Nome = "UNIDADE 01" }
        @{ Codigo = "2"; Nome = "UNIDADE 02" }
        @{ Codigo = "3"; Nome = "UNIDADE 03" }
    )
}

# ============================================================
# CODIFICAÇÃO
# ============================================================
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(65001)
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# PASTAS
# ============================================================
$P1 = $Config.WorkDir
$P2 = Join-Path $P1 "EVIDENCIAS"
$P3 = Join-Path $P2 "BitLocker"
$P4 = Join-Path $P2 "BiosPassword"
$P5 = Join-Path $P1 "Logs"
$P1,$P2,$P3,$P4,$P5 | ForEach-Object {
    if(-not (Test-Path $_)){ New-Item -ItemType Directory $_ -Force | Out-Null }
}

$ARQ_REINICIO_HOST = Join-Path $P1 "reiniciando_host.tmp"
$ARQ_LOCK          = Join-Path $P1 ".lock"
$ARQ_LOG           = Join-Path $P5 ("provisionamento_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
$caminhoScript     = Join-Path $P1 "Pos-Imagem.ps1"
$nomeTarefa        = "PosImagemAutoResume"
$credencialDominio = $null
$pulouRede         = $false

# Status para relatório final
$statusBIOS           = "NAO VERIFICADO"
$statusLocalidade     = "NAO CONFIGURADA"
$statusWinget         = "NAO EXECUTADO"
$statusDominio        = "NAO VERIFICADO"
$statusTPM            = "NAO VERIFICADO"
$statusBitLocker      = "NAO EXECUTADO"
$statusWindowsUpdate  = "NAO SOLICITADO"
$caminhoChaveLocal    = ""
$caminhoChaveRede     = ""

# ============================================================
# LOGGING ESTRUTURADO
# ============================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Mensagem,
        [ValidateSet("INFO","WARN","ERROR","OK")][string]$Nivel = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linha = "[$ts] [$Nivel] $Mensagem"
    $cor = switch($Nivel){
        "INFO"  { "Cyan" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
    }
    Write-Host $linha -ForegroundColor $cor
    try { Add-Content -Path $ARQ_LOG -Value $linha -Encoding UTF8 -ErrorAction SilentlyContinue }catch{}
}

# ============================================================
# RECUPERAÇÃO SEGURA DA SENHA DE BIOS
# ============================================================
function Get-BiosPasswordPlain {
    if($BiosPassword){
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($BiosPassword)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if($env:BIOS_DEFAULT_PASSWORD){
        Write-Log "Senha de BIOS lida da variável de ambiente" "INFO"
        return $env:BIOS_DEFAULT_PASSWORD
    }
    Write-Log "Solicitando senha de BIOS via prompt seguro" "INFO"
    $sec = Read-Host "🔒 Senha admin da BIOS" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$veioDeReinicioHost = Test-Path $ARQ_REINICIO_HOST
if($veioDeReinicioHost){ Remove-Item $ARQ_REINICIO_HOST -Force -ErrorAction SilentlyContinue }

# ============================================================
# FUNÇÕES VISUAIS E AUXILIARES
# ============================================================
function Mostrar-Etapa {
    param([int]$Numero,[int]$Total,[string]$Titulo)
    $pct    = [math]::Round($Numero / $Total * 100)
    $blocos = [math]::Round($Numero / $Total * 30)
    if($blocos -lt 0){ $blocos = 0 }; if($blocos -gt 30){ $blocos = 30 }
    $barra = ("█" * $blocos) + ("░" * (30 - $blocos))
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ("  ETAPA [$barra] {0,3}%   {1}/{2}   {3}" -f $pct,$Numero,$Total,$Titulo) -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Log "Etapa $Numero/$Total iniciada: $Titulo" "INFO"
}

function Pausar-OuAuto {
    param([bool]$EtapaOK = $false,[int]$SegundosAuto = 3)
    Write-Host ""
    if($veioDeReinicioHost -and $EtapaOK){
        Write-Host "⏳ Prosseguindo automaticamente em $SegundosAuto segundos..." -ForegroundColor Cyan
        for($s = $SegundosAuto; $s -ge 1; $s--){ Write-Host "   ⏱️ $s..." -ForegroundColor Cyan; Start-Sleep 1 }
        Write-Host "   ▶️ Continuando..." -ForegroundColor Green
    }else{ Read-Host "⏹️ ENTER para prosseguir" }
}

function Detectar-TipoMaquina {
    try {
        $tipos = (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes
        $notb = @(8,9,10,11,12,14,18,21,30,31,32)
        $desk = @(3,4,5,6,7,13,15,16,23,24,35,36)
        foreach($t in $tipos){
            if($notb -contains $t){ return "L" }
            if($desk -contains $t){ return "W" }
        }
        return $null
    }catch{ return $null }
}

function Calcular-NomePadrao {
    param([string]$TipoLetra,[string]$SerialParcial)
    $n = $Config.ComputerPrefix + $TipoLetra.Trim() + $SerialParcial.Trim()
    if($n.Length -gt 15){ $n = $n.Substring(0,15) }
    return $n
}

function Testar-Administrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Mostrar-PreRequisitos {
    param([string]$Fab,[string]$CctkPath)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "          📋 PRE-REQUISITOS DO SISTEMA" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cap = $os.Caption
        if($cap -match "Pro|Enterprise|Education"){
            Write-Host "   ✅ Sistema Operacional : $cap" -ForegroundColor Green
        }else{
            Write-Host "   ⚠️ Sistema Operacional : $cap (recomendado Pro/Enterprise)" -ForegroundColor Yellow
        }
    }catch{ Write-Host "   ⚠️ Sistema Operacional : NAO IDENTIFICADO" -ForegroundColor Yellow }

    Write-Host "   ✅ Executando como     : Administrador" -ForegroundColor Green

    $temRede = $false
    try { $temRede = Test-Connection -ComputerName $Config.FileServer -Count 1 -Quiet -ErrorAction Stop }catch{}
    if($temRede){ Write-Host "   ✅ Rede corporativa   : OK" -ForegroundColor Green }
    else{ Write-Host "   ⚠️ Rede corporativa   : NAO DISPONIVEL" -ForegroundColor Yellow }

    if($Fab -match "Dell"){
        if($CctkPath){ Write-Host "   ✅ Dell Command Config : INSTALADO" -ForegroundColor Green }
        else{ Write-Host "   ⚠️ Dell Command Config : NAO ENCONTRADO (BIOS sera ignorada)" -ForegroundColor Yellow }
    }else{
        Write-Host "   ℹ️ Fabricante         : $Fab (nao-Dell — BIOS sera ignorada)" -ForegroundColor DarkGray
    }

    try {
        $tpmInfo = Get-Tpm -ErrorAction Stop
        if($tpmInfo.TpmPresent -and $tpmInfo.TpmReady){ Write-Host "   ✅ TPM                 : PRONTO" -ForegroundColor Green }
        elseif($tpmInfo.TpmPresent){ Write-Host "   ⚠️ TPM                 : PRESENTE MAS NAO PRONTO" -ForegroundColor Yellow }
        else{ Write-Host "   ❌ TPM                 : NAO PRESENTE" -ForegroundColor Red }
    }catch{ Write-Host "   ⚠️ TPM                 : NAO FOI POSSIVEL VERIFICAR" -ForegroundColor Yellow }

    try {
        $volInfo = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
        $ativo = $volInfo -and ($volInfo.ProtectionStatus -eq "On" -or $volInfo.EncryptionStatus -like "*Encrypted*")
        if($ativo){ Write-Host "   ✅ BitLocker (C:)      : JA ATIVO" -ForegroundColor Green }
        else{ Write-Host "   ℹ️ BitLocker (C:)      : INATIVO (sera configurado)" -ForegroundColor DarkGray }
    }catch{ Write-Host "   ℹ️ BitLocker (C:)      : NAO VERIFICADO" -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Verificar-StatusBIOS {
    param([string]$CaminhoCctk)
    $res = @{
        TudoCerto = $true; Detalhes = @(); SenhaOk = $false
        UsbEmuOk = $false; SecureOk = $false; NicOk = $false
        ItensParaCorrigir = @(); LeituraOK = $false
    }
    $sufixo  = "{0}_{1}" -f $PID, (Get-Date -Format "yyyyMMdd_HHmmss_fff")
    $arqTemp = Join-Path $env:TEMP ("bios_leitura_" + $sufixo + ".ini")
    if(Test-Path $arqTemp){ Remove-Item $arqTemp -Force -ErrorAction SilentlyContinue }
    Get-ChildItem "$env:TEMP\bios_leitura_*.ini" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    try {
        & $CaminhoCctk "-o" $arqTemp 2>&1 | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path $arqTemp) -and $sw.Elapsed.TotalSeconds -lt 5){ Start-Sleep -Milliseconds 100 }
        if(-not (Test-Path $arqTemp)){
            $res.TudoCerto = $false; $res.LeituraOK = $false
            $res.Detalhes += "❌ ERRO: CCTK nao gerou arquivo de leitura"
            return $res
        }
        $conteudoRaw = Get-Content $arqTemp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if([string]::IsNullOrWhiteSpace($conteudoRaw)){
            $res.TudoCerto = $false; $res.LeituraOK = $false
            $res.Detalhes += "❌ ERRO: CCTK gerou arquivo VAZIO"
            Remove-Item $arqTemp -Force -ErrorAction SilentlyContinue
            return $res
        }
        try {
            $arqLog = Join-Path $P5 ("bios_leitura_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".ini")
            Copy-Item $arqTemp $arqLog -Force -ErrorAction SilentlyContinue
        }catch{}
        $linhas = Get-Content $arqTemp -Encoding UTF8
        Remove-Item $arqTemp -Force -ErrorAction SilentlyContinue
        $res.LeituraOK = $true

        $senhaDetectada = $false
        $linhaSenha = $linhas | Where-Object { $_ -match "^(SetupPassword|AdminPassword)\s*=" }
        if($linhaSenha){
            $valor = ($linhaSenha -split "=",2)[1].Trim()
            if($valor -ne "" -and $valor -ne "Clear" -and $valor -ne "NotSet" -and $valor -ne "Disabled" -and $valor -ne "None"){ $senhaDetectada = $true }
            if($valor -match "\*+"){ $senhaDetectada = $true }
        }
        if(-not $senhaDetectada){
            try {
                $outStatus1 = & $CaminhoCctk "--getsetupPwdStatus" 2>&1 | Out-String
                if($outStatus1 -match "SetupPwdStatus\s*=\s*Enabled" -or $outStatus1 -match "AdminPwdStatus\s*=\s*Enabled"){ $senhaDetectada = $true }
                if($outStatus1 -match "SetupPwdStatus\s*=\s*Set" -or $outStatus1 -match "AdminPwdStatus\s*=\s*Set"){ $senhaDetectada = $true }
            }catch{}
        }
        if(-not $senhaDetectada){
            try {
                $outTeste = & $CaminhoCctk "--UsbEmu=Disabled" 2>&1 | Out-String
                if($outTeste -match "password is required|password required|unable to authenticate|authentication failed|failed to authenticate|invalid password|incorrect password|not authorized|access denied|permission denied|senha (?:e )?(?:obrigat|necess|requerid)|autentica|nao autorizado|acesso negado|contraseña"){ $senhaDetectada = $true }
            }catch{}
        }
        if($senhaDetectada){ $res.SenhaOk = $true; $res.Detalhes += "✅ Senha Admin.......: OK" }
        else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "Senha"; $res.Detalhes += "❌ Senha Admin.......: FALTA" }

        $linhasUSB = @($linhas | Where-Object { $_ -match "^(UsbEmu|UsbBoot|UsbBootEnabled|EnableUSB|UsbProvision)\s*=" })
        if($linhasUSB.Count -gt 0){
            $valoresUSB = @()
            foreach($l in $linhasUSB){
                $v = ($l -split "=",2)[1].Trim(); $v = ($v -split "#")[0].Trim()
                if($v -ne ""){ $valoresUSB += $v }
            }
            $algumNaoDisabled = $false
            foreach($v in $valoresUSB){ if($v -ne "Disabled"){ $algumNaoDisabled = $true; break } }
            if($valoresUSB.Count -eq 0){ $res.TudoCerto = $false; $res.ItensParaCorrigir += "USB"; $res.Detalhes += "❌ USB Boot..........: NAO DETECTADO" }
            elseif($algumNaoDisabled){ $res.TudoCerto = $false; $res.ItensParaCorrigir += "USB"; $res.Detalhes += "❌ USB Boot..........: INCORRETO ($($valoresUSB -join ', '))" }
            else{ $res.UsbEmuOk = $true; $res.Detalhes += "✅ USB Boot..........: OK" }
        }else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "USB"; $res.Detalhes += "❌ USB Boot..........: NAO DETECTADO" }

        $valorSecureBoot = $null
        $linhaSecure = @($linhas | Where-Object { $_ -match "^SecureBoot\s*=" })
        if($linhaSecure.Count -gt 0){ $valorSecureBoot = (($linhaSecure[0] -split "=",2)[1]).Trim() }
        if($null -eq $valorSecureBoot){
            $linhaAlt = @($linhas | Where-Object { $_ -match "^UefiSecureBoot\s*=" })
            if($linhaAlt.Count -gt 0){ $valorSecureBoot = (($linhaAlt[0] -split "=",2)[1]).Trim() }
        }
        if($null -eq $valorSecureBoot){
            $linhaModo = @($linhas | Where-Object { $_ -match "^SecureBootMode\s*=" })
            if($linhaModo.Count -gt 0){ $valorSecureBoot = (($linhaModo[0] -split "=",2)[1]).Trim() }
        }
        if($null -ne $valorSecureBoot){
            if($valorSecureBoot -eq "Enabled" -or $valorSecureBoot -eq "DeployedMode"){ $res.SecureOk = $true; $res.Detalhes += "✅ Secure Boot.......: OK" }
            else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "SecureBoot"; $res.Detalhes += "❌ Secure Boot.......: INCORRETO ($valorSecureBoot)" }
        }else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "SecureBoot"; $res.Detalhes += "❌ Secure Boot.......: NAO DETECTADO" }

        $linhaNIC = $linhas | Where-Object { $_ -match "^EmbNic1\s*=" }
        if($linhaNIC){
            $valor = ($linhaNIC -split "=",2)[1].Trim()
            if($valor -eq "Enabled"){ $res.NicOk = $true; $res.Detalhes += "✅ NIC Rede Boot.....: OK" }
            else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "NIC"; $res.Detalhes += "❌ NIC Rede Boot.....: INCORRETO ($valor)" }
        }else{ $res.TudoCerto = $false; $res.ItensParaCorrigir += "NIC"; $res.Detalhes += "❌ NIC Rede Boot.....: NAO DETECTADO" }

    }catch{
        $res.TudoCerto = $false; $res.LeituraOK = $false
        $res.Detalhes += "❌ Erro na leitura: $_"
        if(Test-Path $arqTemp){ Remove-Item $arqTemp -Force -ErrorAction SilentlyContinue }
    }
    return $res
}

function Definir-LocalidadePatrimonio {
    $listaLocalidades = $Config.LocationList
    Write-Host "📍 Qual a localidade do equipamento?" -ForegroundColor Cyan
    Write-Host ""
    foreach($item in $listaLocalidades){ Write-Host "   $($item.Codigo) - $($item.Nome)" }
    Write-Host ""
    $localidade = $null
    while($null -eq $localidade){
        $digito = Read-Host "Digite o numero correspondente"
        foreach($item in $listaLocalidades){ if($digito.Trim() -eq $item.Codigo){ $localidade = $item.Nome; break } }
        if($null -eq $localidade){ Write-Host "   ❌ Numero invalido!`n" -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "✅ Localidade: $localidade" -ForegroundColor Green
    Write-Host ""
    $patrimonioConfirmado = $false; $patrimonio = ""
    while(-not $patrimonioConfirmado){
        $patrimonio = Read-Host "🔢 Patrimonio"
        if([string]::IsNullOrWhiteSpace($patrimonio)){ Write-Host "   ❌ Nao pode ser vazio!`n" -ForegroundColor Red; continue }
        if((Read-Host "📝 Confirmar '$patrimonio'? (S/N)").ToUpper().Trim() -eq "S"){ $patrimonioConfirmado = $true }
        else{ Write-Host "   🔄 Digite novamente...`n" -ForegroundColor Yellow }
    }
    $descricaoCompleta = "$localidade - PATRIMONIO: $patrimonio"
    Write-Host ""
    Write-Host "📝 Descricao: $descricaoCompleta" -ForegroundColor Yellow
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
            -Name "srvcomment" -Value $descricaoCompleta -Type String -Force -ErrorAction Stop
        Write-Log "Descricao do computador definida: $descricaoCompleta" "OK"
        return $descricaoCompleta
    }catch{
        Write-Log "Falha ao definir descricao: $_" "ERROR"
        return $null
    }
}

function Instalar-WindowsUpdateCompleto {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "          🔄 ATUALIZACOES DO WINDOWS" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Log "Iniciando instalacao de Windows Update" "INFO"
    $moduloDisponivel = $false
    try {
        if(-not (Get-Module -Name PSWindowsUpdate -ListAvailable -ErrorAction SilentlyContinue)){
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            Install-Module -Name PSWindowsUpdate -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        $moduloDisponivel = $true
        Write-Log "Modulo PSWindowsUpdate pronto" "OK"
    }catch{
        Write-Log "PSWindowsUpdate indisponivel — usando usoclient" "WARN"
    }
    if($moduloDisponivel){
        try {
            $atualizacoes = Get-WindowsUpdate -NotCategory "Drivers" -NotTitle "Preview" -ErrorAction Stop
            if(-not $atualizacoes -or $atualizacoes.Count -eq 0){
                Write-Host "✅ Nenhuma atualizacao pendente!" -ForegroundColor Green
                $script:statusWindowsUpdate = "OK - JA ATUALIZADO"
                return
            }
            Write-Host "📋 $($atualizacoes.Count) atualizacoes encontradas" -ForegroundColor Yellow
            $resultado = Install-WindowsUpdate -AcceptAll -IgnoreReboot -NotCategory "Drivers" -NotTitle "Preview" -ErrorAction Stop -Verbose
            $instaladas = ($resultado | Where-Object { $_.Result -eq "Installed" -or $_.Result -eq "Succeeded" }).Count
            $falhas = ($resultado | Where-Object { $_.Result -like "*Failed*" -or $_.Result -like "*Error*" }).Count
            if($falhas -eq 0){ Write-Host "✅ $instaladas atualizacoes instaladas!" -ForegroundColor Green; $script:statusWindowsUpdate = "OK - $instaladas INSTALADAS" }
            else{ Write-Host "⚠️ $instaladas OK | $falhas falhas" -ForegroundColor Yellow; $script:statusWindowsUpdate = "PARCIAL - $instaladas OK / $falhas FALHA" }
            Write-Log "Windows Update: $($script:statusWindowsUpdate)" "INFO"
        }catch{
            Write-Log "Erro no PSWindowsUpdate: $_ — tentando usoclient" "WARN"
            $moduloDisponivel = $false
        }
    }
    if(-not $moduloDisponivel){
        try {
            Start-Process -FilePath "usoclient.exe" -ArgumentList "StartInteractiveScan" -Wait -NoNewWindow -ErrorAction Stop
            Start-Process -FilePath "usoclient.exe" -ArgumentList "StartInstall" -Wait -NoNewWindow -ErrorAction Stop
            $script:statusWindowsUpdate = "OK - METODO ALTERNATIVO"
            Write-Log "Windows Update via usoclient concluido" "OK"
        }catch{
            Write-Log "Falha no Windows Update: $_" "ERROR"
            $script:statusWindowsUpdate = "FALHA"
        }
    }
    Write-Host ""
}

function Conectar-Dominio {
    Write-Host ""
    Write-Host "📋 Credenciais — $($Config.DomainName)" -ForegroundColor Yellow
    $u = Read-Host "👤 Usuario"
    $s = Read-Host "🔒 Senha" -AsSecureString
    $c = New-Object System.Management.Automation.PSCredential($u,$s)
    $script:credencialDominio = $c
    Write-Host ""
    Write-Host "⏳ Conectando..." -ForegroundColor Cyan
    try {
        Add-Computer -DomainName $Config.DomainName -Credential $c -Force -ErrorAction Stop
        Write-Host "✅ Dominio conectado! Efeito apos reinicio." -ForegroundColor Green
        Write-Log "Ingresso no dominio $($Config.DomainName) OK" "OK"
        return "SUCESSO"
    }catch{
        $e = $_.Exception.Message
        Write-Host "❌ Falha: $e" -ForegroundColor Red
        Write-Log "Falha no ingresso de dominio: $e" "ERROR"
        if($e -match "usuário|senha|credencial|incorreto|password|user"){ return "CREDENCIAL" }
        elseif($e -match "não existe|não pôde ser contatado|DNS|rede|servidor|domain|network"){ return "REDE" }
        else{ return "OUTRO" }
    }
}

function Pedir-CredenciaisRede {
    Write-Host ""
    Write-Host "🔐 Salvar chave BitLocker na rede?" -ForegroundColor Cyan
    Write-Host "   Local: $($Config.BitLockerShare)" -ForegroundColor Gray
    if((Read-Host "S=SIM / N=PULAR").ToUpper().Trim() -eq "N"){
        Write-Host "⏭️ Salvo apenas localmente." -ForegroundColor Yellow
        $script:pulouRede = $true; $script:credencialDominio = $null; return
    }
    $u = Read-Host "👤 Usuario rede"
    if($u.ToUpper().Trim() -eq "PULAR" -or [string]::IsNullOrWhiteSpace($u)){
        Write-Host "⏭️ Salvo apenas localmente." -ForegroundColor Yellow
        $script:pulouRede = $true; return
    }
    $s = Read-Host "🔒 Senha rede" -AsSecureString
    $script:credencialDominio = New-Object System.Management.Automation.PSCredential($u,$s)
    $script:pulouRede = $false
    Write-Host "✅ Credenciais registradas." -ForegroundColor Green
}

function Salvar-ChaveBitLockerRede {
    param([string]$Conteudo,[string]$NomeArquivo)
    if($script:pulouRede -or $null -eq $script:credencialDominio){ return $false }
    try {
        $null = New-PSDrive -Name "REDE_BL" -PSProvider FileSystem -Root $Config.BitLockerShare -Credential $script:credencialDominio -ErrorAction Stop
        $caminhoCompleto = Join-Path "REDE_BL:\" $NomeArquivo
        $Conteudo | Out-File $caminhoCompleto -Encoding UTF8 -Force -ErrorAction Stop
        Remove-PSDrive -Name "REDE_BL" -Force -ErrorAction SilentlyContinue
        return $true
    }catch{ Remove-PSDrive -Name "REDE_BL" -Force -ErrorAction SilentlyContinue; return $false }
}

function Extrair-E-SalvarChaveBitLocker {
    $nc = $env:COMPUTERNAME
    $va = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    $rk = $va.KeyProtector | Where-Object KeyProtectorType -eq "RecoveryPassword" -ErrorAction SilentlyContinue
    if(-not $rk){ Write-Host "⚠️ Nenhuma chave de recuperacao encontrada." -ForegroundColor Yellow; return }
    $conteudoChave = "CHAVE DE RECUPERACAO BITLOCKER`r`nEquipamento: $nc`r`nData: $(Get-Date)`r`n`r`nCHAVE:`r`n$($rk.RecoveryPassword)"
    $ckLocal = Join-Path $P3 ("Chave_BitLocker_" + $nc + ".txt")
    $conteudoChave | Out-File $ckLocal -Encoding UTF8 -Force
    Write-Host "✅ 💾 Chave salva: $ckLocal" -ForegroundColor Green
    Write-Log "Recovery key BitLocker salva localmente: $ckLocal" "OK"
    $script:caminhoChaveLocal = $ckLocal
    $nomeArqRede = "Chave_BitLocker_" + $nc + ".txt"
    if(Salvar-ChaveBitLockerRede -Conteudo $conteudoChave -NomeArquivo $nomeArqRede){
        Write-Host "✅ 🌐 Chave salva na rede." -ForegroundColor Green
        Write-Log "Recovery key BitLocker salva na rede: $nomeArqRede" "OK"
        $script:caminhoChaveRede = Join-Path $Config.BitLockerShare $nomeArqRede
    }
}

function Pedir-PinBitLocker {
    while($true){
        Write-Host ""
        Write-Host "ℹ️ PIN = SOMENTE NUMEROS (6 a 20 digitos)" -ForegroundColor Cyan
        $pin1 = ""; while($pin1 -notmatch "^\d{6,20}$"){ $pin1 = Read-Host "🔢 Digite o PIN"; if($pin1 -notmatch "^\d{6,20}$"){ Write-Host "❌ Apenas numeros, 6-20 digitos." -ForegroundColor Red } }
        $pin2 = ""; while($pin2 -notmatch "^\d{6,20}$"){ $pin2 = Read-Host "🔢 Confirme o PIN"; if($pin2 -notmatch "^\d{6,20}$"){ Write-Host "❌ Apenas numeros, 6-20 digitos." -ForegroundColor Red } }
        if($pin1 -eq $pin2){ Write-Host "✅ PIN confirmado." -ForegroundColor Green; return $pin1 }
        Write-Host "❌ Os PINs NAO conferem!" -ForegroundColor Red
    }
}

function Get-BitLockerStatus {
    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if(-not $vol){ return "INDISPONIVEL" }
    $pct = $vol.EncryptionPercentage
    switch($vol.EncryptionStatus){
        "FullyEncrypted"       { return "COMPLETO (100%)" }
        "FullyDecrypted"       { return "NAO CRIPTOGRAFADO" }
        "EncryptionInProgress" { return "EM ANDAMENTO ($pct%)" }
        "DecryptionInProgress" { return "DESCRIPTOGRAFANDO ($pct%)" }
        default                { return "$($vol.EncryptionStatus) ($pct%)" }
    }
}

function Confirmar-InicioCriptografia {
    param([int]$TimeoutSeg = 15)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while($sw.Elapsed.TotalSeconds -lt $TimeoutSeg){
        $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
        if($vol -and ($vol.EncryptionStatus -eq "EncryptionInProgress" -or $vol.EncryptionStatus -eq "FullyEncrypted")){
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ============================================================
# INÍCIO DO SCRIPT
# ============================================================
Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Blue
Write-Host "   🚀 AUTOMACAO DE POS-IMAGEM — $($Config.CompanyName)" -ForegroundColor Blue
Write-Host "============================================================" -ForegroundColor Blue
if($veioDeReinicioHost){ Write-Host "   🔄 RETOMANDO APOS REINICIO" -ForegroundColor Cyan }
Write-Host ""
Write-Log "===== Inicio da execucao (PID $PID) =====" "INFO"

if(-not (Testar-Administrador)){
    Write-Host "❌ EXECUTE COMO ADMINISTRADOR!" -ForegroundColor Red
    Write-Log "Script nao foi executado como administrador" "ERROR"
    Read-Host "⏹️ ENTER para fechar"; exit
}
Write-Host "✅ Privilegios: OK" -ForegroundColor Green

if(Test-Path $ARQ_LOCK){
    $pidLock = Get-Content $ARQ_LOCK -ErrorAction SilentlyContinue | Select-Object -First 1
    if($pidLock -and (Get-Process -Id $pidLock -ErrorAction SilentlyContinue)){
        Write-Host "❌ Ja existe instancia rodando (PID $pidLock)!" -ForegroundColor Red
        Read-Host "⏹️ ENTER"; exit
    }
    Remove-Item $ARQ_LOCK -Force -ErrorAction SilentlyContinue
}
"$PID" | Out-File $ARQ_LOCK -Force

$fab = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$cctkGlobal = Get-ChildItem "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe" -ErrorAction SilentlyContinue
if(-not $cctkGlobal){ $cctkGlobal = Get-ChildItem "C:\Program Files\Dell\Command Configure\X86_64\cctk.exe" -ErrorAction SilentlyContinue }

Mostrar-PreRequisitos -Fab $fab -CctkPath $(if($cctkGlobal){ $cctkGlobal.FullName } else { "" })

Write-Host "🖥️ Fabricante : $fab"
if($cctkGlobal){ Write-Host "🔧 CCTK       : $($cctkGlobal.FullName)" -ForegroundColor Green }
Write-Host ""

if($veioDeReinicioHost){ Write-Host "⏳ Retomando em 3s..." -ForegroundColor Cyan; Start-Sleep 3 }
else{ Read-Host "⏹️ ENTER para iniciar" }

# [1/8] BIOS
Clear-Host
Mostrar-Etapa -Numero 1 -Total 8 -Titulo "🔧 BIOS Dell"
$biosOK = $false
if($fab -notmatch "Dell"){ Write-Host "⚠️ Nao e Dell." -ForegroundColor Yellow; $statusBIOS = "IGNORADO - NAO E DELL"; $biosOK = $true }
elseif(-not $cctkGlobal){ Write-Host "⚠️ CCTK nao encontrado." -ForegroundColor Red; $statusBIOS = "IGNORADO - SEM CCTK"; $biosOK = $true }
else{
    $ver = Verificar-StatusBIOS -CaminhoCctk $cctkGlobal.FullName
    $ver.Detalhes | ForEach-Object { Write-Host "   $_" }
    Write-Host ""
    if(-not $ver.LeituraOK){
        Write-Host "⚠️ Nao foi possivel ler a BIOS. Verifique CCTK e senha admin." -ForegroundColor Red
        $statusBIOS = "FALHA NA LEITURA"; $biosOK = $false
    }
    elseif($ver.TudoCerto){ Write-Host "✅ BIOS OK!" -ForegroundColor Green; $statusBIOS = "OK - VERIFICADO"; $biosOK = $true }
    else{
        Write-Host "⚠️ Itens a ajustar: $($ver.ItensParaCorrigir -join ' | ')" -ForegroundColor Red
        if((Read-Host "🛠️ Corrigir agora? (S/ENTER)").ToUpper().Trim() -eq "S"){
            $exe = $cctkGlobal.FullName
            $sb  = Get-BiosPasswordPlain
            $erros = @()
            if(-not $ver.SenhaOk){ try { & $exe "--setuppwd=$sb" 2>&1 | Out-Null; Write-Host "   ✅ Senha definida" -ForegroundColor Green } catch { $erros += "Senha" } }
            if(-not $ver.UsbEmuOk){ try { & $exe "--UsbEmu=Disabled" "--valsetuppwd=$sb" 2>&1 | Out-Null; Write-Host "   ✅ USB desabilitado" -ForegroundColor Green } catch { $erros += "USB" } }
            if(-not $ver.SecureOk){ try { & $exe "--SecureBootResetKeys=AllKeys" "--valsetuppwd=$sb" 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; & $exe "--secureboot=enable" "--valsetuppwd=$sb" 2>&1 | Out-Null; Write-Host "   ✅ Secure Boot habilitado" -ForegroundColor Green } catch { $erros += "SecureBoot" } }
            if(-not $ver.NicOk){ try { & $exe "--embnic1=Enabled" "--valsetuppwd=$sb" 2>&1 | Out-Null; Write-Host "   ✅ NIC habilitada" -ForegroundColor Green } catch { $erros += "NIC" } }
            $sb = $null
            [GC]::Collect()
            if($erros.Count -eq 0){ Write-Log "BIOS ajustada com sucesso" "OK"; $statusBIOS = "AJUSTADO"; $biosOK = $true }
            else{ Write-Log "Falhas BIOS: $($erros -join ', ')" "WARN"; $statusBIOS = "PARCIAL"; $biosOK = $false }
        }else{ $statusBIOS = "IGNORADO PELO USUARIO" }
    }
}
Pausar-OuAuto -EtapaOK $biosOK

# [2/8] HOSTNAME
Clear-Host
Mostrar-Etapa -Numero 2 -Total 8 -Titulo "🏷️ Hostname"
$SERIAL = ((Get-CimInstance Win32_BIOS).SerialNumber.Trim()) -replace '[^A-Za-z0-9]',''
if([string]::IsNullOrWhiteSpace($SERIAL)){ $SERIAL = "INDISPONIVEL" }
$sc = $SERIAL.Substring([math]::Max(0, $SERIAL.Length - 8))
$tipoAuto = Detectar-TipoMaquina
$tipoNome = if($tipoAuto -eq "L"){"NOTEBOOK"}elseif($tipoAuto -eq "W"){"DESKTOP"}else{"NAO DETECTADO"}
Write-Host "📋 Serial : $sc" -ForegroundColor Green
Write-Host "🏷️ Nome   : $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "🔍 Tipo   : $tipoNome" -ForegroundColor Cyan
$hostOK = $false

if($tipoAuto -eq "L" -or $tipoAuto -eq "W"){
    $nomeEsperado = Calcular-NomePadrao -TipoLetra $tipoAuto -SerialParcial $sc
    Write-Host "🎯 Esperado: $nomeEsperado" -ForegroundColor Green
    if($env:COMPUTERNAME.Trim() -eq $nomeEsperado){ Write-Host "✅ Nome OK!" -ForegroundColor Green; $hostOK = $true }
    else{
        if((Read-Host "❓ Aplicar $nomeEsperado ? (S/N)").ToUpper().Trim() -eq "S"){
            "REINICIANDO" | Out-File $ARQ_REINICIO_HOST -Encoding UTF8 -Force
            Rename-Computer -NewName $nomeEsperado -Force -ErrorAction Stop | Out-Null
            $acao = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c start """" powershell.exe -NoExit -ExecutionPolicy Bypass -File ""$caminhoScript"""
            $gatilho = New-ScheduledTaskTrigger -AtLogon
            $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName $nomeTarefa -Action $acao -Trigger $gatilho -Settings $cfg -RunLevel Highest -Force | Out-Null
            Write-Host "🔄 Reiniciando em 5s..." -ForegroundColor Red
            for($i=5;$i -ge 1;$i--){ Write-Host "   $i..."; Start-Sleep 1 }
            Remove-Item $ARQ_LOCK -Force -ErrorAction SilentlyContinue
            Write-Log "Hostname alterado — reiniciando" "OK"
            Shutdown /r /t 0; exit
        }else{ Write-Host "⏭️ Mantido: $env:COMPUTERNAME" -ForegroundColor Yellow; $hostOK = $true }
    }
}else{
    $tipo = ""; while($tipo -ne "L" -and $tipo -ne "W"){ $tipo = (Read-Host "Tipo (L=Notebook / W=Desktop)").ToUpper().Trim() }
    $nomeEsperado = Calcular-NomePadrao -TipoLetra $tipo -SerialParcial $sc
    Write-Host "🎯 Proposto: $nomeEsperado" -ForegroundColor Cyan
    if((Read-Host "Confirmar? (S/N)").ToUpper().Trim() -eq "S" -and $env:COMPUTERNAME.Trim() -ne $nomeEsperado){
        "REINICIANDO" | Out-File $ARQ_REINICIO_HOST -Encoding UTF8 -Force
        Rename-Computer -NewName $nomeEsperado -Force -ErrorAction Stop | Out-Null
        $acao = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c start """" powershell.exe -NoExit -ExecutionPolicy Bypass -File ""$caminhoScript"""
        $gatilho = New-ScheduledTaskTrigger -AtLogon
        $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $nomeTarefa -Action $acao -Trigger $gatilho -Settings $cfg -RunLevel Highest -Force | Out-Null
        Write-Host "🔄 Reiniciando em 5s..." -ForegroundColor Red
        for($i=5;$i -ge 1;$i--){ Write-Host "   $i..."; Start-Sleep 1 }
        Remove-Item $ARQ_LOCK -Force -ErrorAction SilentlyContinue
        Shutdown /r /t 0; exit
    }else{ $hostOK = $true }
}
Pausar-OuAuto -EtapaOK $hostOK

# [3/8] LOCALIDADE
Clear-Host
Mostrar-Etapa -Numero 3 -Total 8 -Titulo "📍 Localidade + Patrimonio"
$descricaoOK = $false
$descAtual = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "srvcomment" -ErrorAction SilentlyContinue).srvcomment
if($descAtual -and $descAtual -match "PATRIMONIO:\s*\d+"){
    Write-Host "ℹ️ Descricao atual: $descAtual" -ForegroundColor Cyan
    if((Read-Host "❓ Reconfigurar? (S/N)").ToUpper().Trim() -ne "S"){ $statusLocalidade = $descAtual; $descricaoOK = $true }
    else{ $nova = Definir-LocalidadePatrimonio; if($nova){ $statusLocalidade = $nova; $descricaoOK = $true } }
}else{
    if((Read-Host "❓ Configurar Localidade+Patrimonio? (S/N)").ToUpper().Trim() -eq "S"){
        $nova = Definir-LocalidadePatrimonio
        if($nova){ $statusLocalidade = $nova; $descricaoOK = $true }
    }else{ $statusLocalidade = "IGNORADO"; $descricaoOK = $true }
}
Pausar-OuAuto -EtapaOK $descricaoOK

# [4/8] WINGET
Clear-Host
Mostrar-Etapa -Numero 4 -Total 8 -Titulo "⬆️ Winget"
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if(-not $wingetCmd){
    Write-Host "⚠️ Winget nao encontrado." -ForegroundColor Yellow
    $statusWinget = "IGNORADO - SEM WINGET"
    Read-Host "⏹️ ENTER"
}else{
    try { winget source update --accept-source-agreements 2>&1 | Out-Null }catch{}
    $rawList = ""
    try { $rawList = (winget upgrade --include-unknown --accept-source-agreements 2>&1 | Out-String) }catch{}
    $linhas = $rawList -split "`r?`n"
    $pacotes = @(); $inList = $false
    for($i = 0; $i -lt $linhas.Count; $i++){
        $l = $linhas[$i]
        if($l -match '^-{5,}'){ $inList = $true; continue }
        if(-not $inList){ continue }
        if([string]::IsNullOrWhiteSpace($l)){ break }
        if($l -match '^\s*\d+\s+(atualizaç|pacote|update|package|upgrades?\s+available|dispon[íi]vei)'){ continue }
        if($l -match 'têm números de versão|tem numeros de versao|nao podem ser determinad|not be determined|--include-unknown'){ continue }
        $tokens = @($l -split '\s+' | Where-Object { $_ -ne '' })
        if($tokens.Count -lt 5){ continue }
        $origem = $tokens[-1]; $id = $tokens[-4]; $nome = ($tokens[0..($tokens.Count - 5)] -join ' ').Trim()
        if([string]::IsNullOrWhiteSpace($nome) -or [string]::IsNullOrWhiteSpace($id)){ continue }
        if($id -notmatch '\.' -or $id.Length -lt 3){ continue }
        if($origem -ne "winget" -and $origem -ne "msstore"){ continue }
        $pacotes += [PSCustomObject]@{ Nome = $nome; Id = $id }
    }
    if($pacotes.Count -eq 0){ Write-Host "✅ Nada a atualizar." -ForegroundColor Green; $statusWinget = "OK - JA ATUALIZADO"; Read-Host "⏹️ ENTER" }
    else{
        $total = $pacotes.Count; $atual = 0; $ok = 0; $falha = 0
        foreach($p in $pacotes){
            $atual++
            Write-Host "  [$atual/$total] $($p.Nome)" -ForegroundColor Cyan -NoNewline
            try { winget upgrade --id $p.Id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null }catch{}
            if($LASTEXITCODE -eq 0){ Write-Host " ✅" -ForegroundColor Green; $ok++ }
            else{ Write-Host " ⚠️" -ForegroundColor Yellow; $falha++ }
        }
        $statusWinget = if($falha -eq 0){ "OK - $ok ATUALIZADOS" }else{ "PARCIAL - $ok OK / $falha FALHA" }
        Write-Log "Winget: $statusWinget" "INFO"
        Read-Host "⏹️ ENTER"
    }
}

# [5/8] DOMÍNIO
Clear-Host
Mostrar-Etapa -Numero 5 -Total 8 -Titulo "🌐 Dominio"
$da = (Get-CimInstance Win32_ComputerSystem).Domain.Trim()
Write-Host "💻 Dominio atual: $da" -ForegroundColor Cyan
if($da -eq $Config.DomainName){ Write-Host "✅ Ja no dominio correto." -ForegroundColor Green; $statusDominio = "OK - JA CONECTADO"; Pedir-CredenciaisRede }
else{
    if((Read-Host "🔗 Conectar ao dominio $($Config.DomainName)? (S/N)").ToUpper().Trim() -ne "S"){ $statusDominio = "IGNORADO"; Pedir-CredenciaisRede }
    else{
        $tc = 0; $ok = $false
        while(-not $ok){
            $res = Conectar-Dominio
            if($res -eq "SUCESSO"){ $statusDominio = "OK - ATIVO APOS REINICIO"; $ok = $true }
            elseif($res -eq "CREDENCIAL"){
                $tc++
                if($tc -ge 3){ Write-Host "❌ Maximo de tentativas." -ForegroundColor Red; Pedir-CredenciaisRede; break }
                if((Read-Host "🔄 Tentar novamente? (S/N)").ToUpper().Trim() -ne "S"){ Pedir-CredenciaisRede; break }
            }else{ if((Read-Host "🔄 Tentar novamente? (S/N)").ToUpper().Trim() -ne "S"){ Pedir-CredenciaisRede; break } }
        }
        if(-not $ok){ $statusDominio = "FALHA"; Pedir-CredenciaisRede }
    }
}
Read-Host "⏹️ ENTER para BitLocker 🔒"

# [6/8] BITLOCKER
Clear-Host
Mostrar-Etapa -Numero 6 -Total 8 -Titulo "🔒 BitLocker"
$tpm = Get-Tpm -ErrorAction SilentlyContinue; $pular = $false
if(-not $tpm.TpmPresent -or -not $tpm.TpmReady){
    Write-Host "❌ TPM indisponivel." -ForegroundColor Red; $statusTPM = "INDISPONIVEL"; $pular = $true; $statusBitLocker = "IGNORADO - SEM TPM"
    Read-Host "⏹️ ENTER"
}else{
    Write-Host "✅ TPM OK." -ForegroundColor Green; $statusTPM = "OK"
    if((Read-Host "Configurar BitLocker? (S/N)").ToUpper().Trim() -ne "S"){ $statusBitLocker = "IGNORADO"; $pular = $true }
}
if(-not $pular){
    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    $cript = ($vol -and ($vol.ProtectionStatus -eq "On" -or $vol.EncryptionStatus -like "*Encrypted*"))
    $temPin = $false
    if($vol -and $vol.KeyProtector){ foreach($kp in $vol.KeyProtector){ if($kp.KeyProtectorType -eq "TpmAndPin"){ $temPin = $true; break } } }
    if($cript -and $temPin){
        Write-Host "ℹ️ BitLocker ja configurado com PIN." -ForegroundColor Cyan
        [void](Extrair-E-SalvarChaveBitLocker)
        $statusBitLocker = "OK - JA CONFIGURADO (PIN)"
    }elseif($cript -and -not $temPin){
        if((Read-Host "BitLocker ativo sem PIN. Adicionar PIN? (S/N)").ToUpper().Trim() -eq "S"){
            $pin = Pedir-PinBitLocker
            try {
                $ps = ConvertTo-SecureString $pin -AsPlainText -Force
                Add-BitLockerKeyProtector -MountPoint "C:" -TpmAndPinProtector -Pin $ps -ErrorAction Stop | Out-Null
                Write-Host "✅ PIN adicionado!" -ForegroundColor Green
                [void](Extrair-E-SalvarChaveBitLocker)
                $statusBitLocker = "OK - PIN ADICIONADO"
            }catch{ Write-Log "Falha ao adicionar PIN: $_" "ERROR"; $statusBitLocker = "FALHA" }
            $pin = $null; $ps = $null; [GC]::Collect()
        }else{ [void](Extrair-E-SalvarChaveBitLocker); $statusBitLocker = "OK - SOMENTE TPM" }
    }else{
        if((Read-Host "Usar PIN? (S/N)").ToUpper().Trim() -eq "S"){
            $pin = Pedir-PinBitLocker
            try {
                $ps = ConvertTo-SecureString $pin -AsPlainText -Force
                $usoApenas = if($BitLockerUsedSpaceOnly){ $true } else { $false }
                Enable-BitLocker -MountPoint "C:" -EncryptionMethod Aes256 -UsedSpaceOnly:$usoApenas -TpmAndPinProtector -Pin $ps -SkipHardwareTest -ErrorAction Stop | Out-Null
                Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
                Write-Host "✅ BitLocker habilitado com PIN!" -ForegroundColor Green
                [void](Extrair-E-SalvarChaveBitLocker)
                [void](Confirmar-InicioCriptografia)
                $statusBitLocker = "INICIADO - " + (Get-BitLockerStatus)
                Write-Log "BitLocker: $statusBitLocker" "OK"
            }catch{ Write-Log "Falha BitLocker PIN: $_" "ERROR"; $statusBitLocker = "FALHA" }
            $pin = $null; $ps = $null; [GC]::Collect()
        }else{
            try {
                $usoApenas = if($BitLockerUsedSpaceOnly){ $true } else { $false }
                Enable-BitLocker -MountPoint "C:" -EncryptionMethod Aes256 -UsedSpaceOnly:$usoApenas -TpmProtector -SkipHardwareTest -ErrorAction Stop | Out-Null
                Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
                Write-Host "✅ BitLocker habilitado (TPM)." -ForegroundColor Green
                [void](Extrair-E-SalvarChaveBitLocker)
                [void](Confirmar-InicioCriptografia)
                $statusBitLocker = "INICIADO - " + (Get-BitLockerStatus)
                Write-Log "BitLocker: $statusBitLocker" "OK"
            }catch{ Write-Log "Falha BitLocker TPM: $_" "ERROR"; $statusBitLocker = "FALHA" }
        }
    }
}
Read-Host "⏹️ ENTER para prosseguir"

# [7/8] RELATÓRIO
Clear-Host
Mostrar-Etapa -Numero 7 -Total 8 -Titulo "📋 Relatorio Final"
Write-Host "============================================================" -ForegroundColor Green
Write-Host "          RELATORIO FINAL DE CONFIGURACAO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "🏷️  NOME          : $env:COMPUTERNAME"
Write-Host "🔧  BIOS          : $statusBIOS"
Write-Host "📍  LOCALIDADE    : $statusLocalidade"
Write-Host "⬆️  WINGET        : $statusWinget"
Write-Host "🌐  DOMINIO       : $statusDominio"
Write-Host "🔐  TPM           : $statusTPM"
Write-Host "🔒  BITLOCKER     : $statusBitLocker"
if($statusBitLocker -like "INICIADO*"){
    Write-Host "    ℹ️  Criptografia roda em background (disco inteiro)." -ForegroundColor DarkGray
    Write-Host "    ℹ️  Recovery key JÁ FOI SALVA — requisito de compliance atendido." -ForegroundColor DarkGray
    Write-Host "    ℹ️  Pode entregar a maquina ao usuario; conclusao é assíncrona." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "🔑 CHAVE LOCAL: $caminhoChaveLocal" -ForegroundColor Yellow
if($caminhoChaveRede -ne ""){ Write-Host "🔑 CHAVE REDE: $caminhoChaveRede" -ForegroundColor Yellow }
Write-Host ""
Write-Log "Relatorio final: BIOS=$statusBIOS | Localidade=$statusLocalidade | Winget=$statusWinget | Dominio=$statusDominio | TPM=$statusTPM | BitLocker=$statusBitLocker" "INFO"
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  1. Crie/valide o objeto do computador no AD." -ForegroundColor White
Write-Host "  2. Mova para a OU correta." -ForegroundColor White
Write-Host "  3. Faca login com credenciais corporativas." -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Yellow
Read-Host "⏹️ ENTER para prosseguir"

# [8/8] WINDOWS UPDATE
Clear-Host
Mostrar-Etapa -Numero 8 -Total 8 -Titulo "🔄 Windows Update / Finalizacao"
if((Read-Host "Executar Windows Update agora? (S/N)").ToUpper().Trim() -eq "S"){
    Instalar-WindowsUpdateCompleto
    Write-Host "📊 Status WU: $statusWindowsUpdate" -ForegroundColor Cyan
    Read-Host "⏹️ ENTER"
}else{ Write-Host "⏭️ WU ignorado." -ForegroundColor Yellow; $statusWindowsUpdate = "IGNORADO" }

# FINALIZAÇÃO
Write-Host ""
Write-Host "🧹 Limpando tarefa agendada e arquivos temporarios..." -ForegroundColor Gray
Unregister-ScheduledTask -TaskName $nomeTarefa -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $ARQ_REINICIO_HOST -Force -ErrorAction SilentlyContinue
Remove-Item $ARQ_LOCK -Force -ErrorAction SilentlyContinue
Write-Log "===== Execucao concluida =====" "OK"
Write-Host "✅ Pronto. Log: $ARQ_LOG" -ForegroundColor Green
Write-Host ""
Write-Host "🤖 ENTER para REINICIAR" -ForegroundColor Yellow
Read-Host
for($i=5; $i -ge 1;$i--){ Write-Host "   $i..."; Start-Sleep 1 }
Write-Host "0 - Reiniciando... 🚀"
Start-Sleep 1
Restart-Computer -Force
