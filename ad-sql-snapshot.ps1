# ===============================================================
# ad-sql-snapshot.ps1
# Snapshot de usuarios activos de Active Directory hacia SQL Server
# ===============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================= CONFIG =================
$Config = @{
    ScriptName = 'AD-SQL-Snapshot'
    LogRoot = 'C:\Scripts\Logs\AD-SQL-Snapshot'
    ActiveDirectoryModule = 'ActiveDirectory'
    Sql = @{
        Server = 'SQLSERVER01'
        Database = 'AutomationDB'
        Table = 'dbo.AD_Users_Snapshot'
        UseIntegratedSecurity = $true
        SqlUser = 'sql_user_placeholder'
        SqlPasswordEnvVar = 'AUTOMATION_SQL_PASSWORD'
        CommandTimeoutSeconds = 60
    }
    Notification = @{
        Mail = @{
            Enabled = $true
            SmtpServer = 'smtp.company.local'
            Port = 587
            UseSsl = $true
            User = 'smtp_user_placeholder'
            PasswordEnvVar = 'AUTOMATION_SMTP_PASSWORD'
            From = 'automation@company.local'
            To = @('ops@company.local')
        }
        Telegram = @{
            Enabled = $true
            BotTokenEnvVar = 'AUTOMATION_TELEGRAM_BOT_TOKEN'
            ChatIdEnvVar = 'AUTOMATION_TELEGRAM_CHAT_ID'
        }
    }
}

# ================= LOG =================
if (-not (Test-Path -Path $Config.LogRoot)) {
    New-Item -Path $Config.LogRoot -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $Config.LogRoot ('{0}-{1:yyyyMMdd}.log' -f $Config.ScriptName, (Get-Date))

function Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO',
        [hashtable]$Data
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        level = $Level
        script = $Config.ScriptName
        host = $env:COMPUTERNAME
        message = $Message
        data = $Data
    }

    Add-Content -Path $LogFile -Value ($entry | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    Write-Host ('[{0}] {1}' -f $Level, $Message)
}

function Send-Mail {
    param(
        [Parameter(Mandatory)] [string]$Subject,
        [Parameter(Mandatory)] [string]$Body
    )

    if (-not $Config.Notification.Mail.Enabled) { return }

    try {
        $smtpPassword = [Environment]::GetEnvironmentVariable($Config.Notification.Mail.PasswordEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($smtpPassword)) { $smtpPassword = [Environment]::GetEnvironmentVariable($Config.Notification.Mail.PasswordEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($smtpPassword)) { throw "No se encontró variable de entorno '$($Config.Notification.Mail.PasswordEnvVar)'." }

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $Config.Notification.Mail.From
        foreach ($recipient in $Config.Notification.Mail.To) { [void]$mail.To.Add($recipient) }
        $mail.Subject = $Subject
        $mail.Body = $Body

        $smtp = New-Object System.Net.Mail.SmtpClient($Config.Notification.Mail.SmtpServer, $Config.Notification.Mail.Port)
        $smtp.EnableSsl = $Config.Notification.Mail.UseSsl
        $smtp.Credentials = New-Object System.Net.NetworkCredential($Config.Notification.Mail.User, $smtpPassword)
        $smtp.Send($mail)

        $mail.Dispose(); $smtp.Dispose()
        Log -Message 'Notificación SMTP enviada.'
    }
    catch {
        Log -Message "Error en SMTP: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Send-Telegram {
    param([Parameter(Mandatory)] [string]$Message)

    if (-not $Config.Notification.Telegram.Enabled) { return }

    try {
        $botToken = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.BotTokenEnvVar, 'Machine')
        $chatId = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.ChatIdEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($botToken)) { $botToken = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.BotTokenEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($chatId)) { $chatId = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.ChatIdEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($botToken) -or [string]::IsNullOrWhiteSpace($chatId)) { throw 'Faltan credenciales de Telegram en variables de entorno.' }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $botToken) -Method Post -Body @{ chat_id = $chatId; text = $Message } | Out-Null
        Log -Message 'Notificación Telegram enviada.'
    }
    catch {
        Log -Message "Error en Telegram: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function New-SqlConnection {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Config.Sql.Server
    $builder['Initial Catalog'] = $Config.Sql.Database
    $builder['Connect Timeout'] = 15

    if ($Config.Sql.UseIntegratedSecurity) {
        $builder['Integrated Security'] = $true
    }
    else {
        $sqlPassword = [Environment]::GetEnvironmentVariable($Config.Sql.SqlPasswordEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($sqlPassword)) { $sqlPassword = [Environment]::GetEnvironmentVariable($Config.Sql.SqlPasswordEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($sqlPassword)) { throw "No se encontró la variable de entorno '$($Config.Sql.SqlPasswordEnvVar)'." }
        $builder['User ID'] = $Config.Sql.SqlUser
        $builder['Password'] = $sqlPassword
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $connection.Open()
    return $connection
}

function Test-Prerequisites {
    if (-not (Get-Module -ListAvailable -Name $Config.ActiveDirectoryModule)) {
        throw "El módulo '$($Config.ActiveDirectoryModule)' no está instalado."
    }
    Import-Module $Config.ActiveDirectoryModule -ErrorAction Stop
}

$errorsList = New-Object System.Collections.Generic.List[string]
$sqlConnection = $null

Log -Message '=== INICIO AD SQL SNAPSHOT ==='

try {
    Test-Prerequisites

    $allUsers = Get-ADUser -Filter * -Properties Enabled, GivenName, Surname, Mail -ErrorAction Stop
    $enabledUsers = $allUsers | Where-Object { $_.Enabled -eq $true }
    $disabledCount = ($allUsers | Where-Object { $_.Enabled -eq $false }).Count

    Log -Message "Usuarios activos: $($enabledUsers.Count). Deshabilitados detectados: $disabledCount"

    $sqlConnection = New-SqlConnection

    $mergeSql = @"
MERGE $($Config.Sql.Table) AS target
USING (SELECT @SamAccountName AS SamAccountName) AS source
ON target.SamAccountName = source.SamAccountName
WHEN MATCHED THEN
    UPDATE SET DisplayName = @DisplayName, GivenName = @GivenName, Surname = @Surname, Mail = @Mail, Enabled = @Enabled, LastSeen = @LastSeen
WHEN NOT MATCHED THEN
    INSERT (SamAccountName, DisplayName, GivenName, Surname, Mail, Enabled, LastSeen)
    VALUES (@SamAccountName, @DisplayName, @GivenName, @Surname, @Mail, @Enabled, @LastSeen);
"@

    foreach ($user in $enabledUsers) {
        $command = $sqlConnection.CreateCommand()
        $command.CommandText = $mergeSql
        $command.CommandTimeout = $Config.Sql.CommandTimeoutSeconds

        [void]$command.Parameters.Add('@SamAccountName', [System.Data.SqlDbType]::VarChar, 128)
        [void]$command.Parameters.Add('@DisplayName', [System.Data.SqlDbType]::NVarChar, 256)
        [void]$command.Parameters.Add('@GivenName', [System.Data.SqlDbType]::NVarChar, 128)
        [void]$command.Parameters.Add('@Surname', [System.Data.SqlDbType]::NVarChar, 128)
        [void]$command.Parameters.Add('@Mail', [System.Data.SqlDbType]::NVarChar, 256)
        [void]$command.Parameters.Add('@Enabled', [System.Data.SqlDbType]::Bit)
        [void]$command.Parameters.Add('@LastSeen', [System.Data.SqlDbType]::DateTime)

        $command.Parameters['@SamAccountName'].Value = [string]$user.SamAccountName
        $command.Parameters['@DisplayName'].Value = [string]$user.Name
        $command.Parameters['@GivenName'].Value = [string]$user.GivenName
        $command.Parameters['@Surname'].Value = [string]$user.Surname
        $command.Parameters['@Mail'].Value = [string]$user.Mail
        $command.Parameters['@Enabled'].Value = $true
        $command.Parameters['@LastSeen'].Value = Get-Date

        [void]$command.ExecuteNonQuery()
        $command.Dispose()
    }
}
catch {
    $errorsList.Add($_.Exception.Message)
    Log -Message "Error general: $($_.Exception.Message)" -Level 'ERROR'
}
finally {
    if ($null -ne $sqlConnection) {
        if ($sqlConnection.State -eq [System.Data.ConnectionState]::Open) { $sqlConnection.Close() }
        $sqlConnection.Dispose()
    }
}

# ================= NOTIFICACION FINAL =================
if ($errorsList.Count -gt 0) {
    $errorBody = "Falló AD-SQL Snapshot en $env:COMPUTERNAME`n" + ($errorsList -join "`n")
    Send-Mail -Subject "ERROR AD-SQL Snapshot - $env:COMPUTERNAME" -Body $errorBody
    Send-Telegram -Message $errorBody
}
else {
    Send-Telegram -Message "AD-SQL Snapshot finalizado correctamente en $env:COMPUTERNAME"
}

Log -Message '=== FIN AD SQL SNAPSHOT ==='

# ---
# ## ‍ Desarrollado por Isaac Esteban Haro Torres
# **Ingeniero en Sistemas · Full Stack · Automatización · Data**
# -  Email: zackharo1@gmail.com
# -  WhatsApp: 098805517
# -  GitHub: https://github.com/ieharo1
# -  Portafolio: https://ieharo1.github.io/portafolio-isaac.haro/
# ---
# ##  Licencia
# © 2026 Isaac Esteban Haro Torres - Todos los derechos reservados.
