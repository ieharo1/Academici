# AD SQL Snapshot - Documentacion Operativa

Script principal: `ad-sql-snapshot.ps1`

## Objetivo
Extraer usuarios activos de Active Directory y actualizar un snapshot en SQL Server con control de errores y notificaciones empresariales.

## Funcionamiento
1. Valida que exista el modulo `ActiveDirectory`.
2. Lee usuarios AD (`Get-ADUser`) y separa habilitados/deshabilitados.
3. Abre conexion SQL con credenciales seguras o seguridad integrada.
4. Ejecuta `MERGE` por cada usuario activo para insertar/actualizar.
5. Registra logs estructurados JSON diarios.
6. Si hay error, envia alerta por SMTP y Telegram.

## Prerequisitos
- Windows Server 2019/2022 o Windows PowerShell 5.1+
- Modulo `ActiveDirectory`
- Acceso al controlador de dominio
- SQL Server accesible
- Conectividad SMTP y HTTPS hacia Telegram

## Configuracion
Edita la seccion `CONFIG` del script:
- `Sql.Server`, `Sql.Database`, `Sql.Table`
- `Sql.UseIntegratedSecurity`
- `Notification.Mail.*`
- `Notification.Telegram.*`
- `LogRoot`

## Variables de entorno obligatorias
Si no usas seguridad integrada en SQL:
- `AUTOMATION_SQL_PASSWORD`

Para notificaciones:
- `AUTOMATION_SMTP_PASSWORD`
- `AUTOMATION_TELEGRAM_BOT_TOKEN`
- `AUTOMATION_TELEGRAM_CHAT_ID`

Ejemplo (PowerShell como admin):

```powershell
[Environment]::SetEnvironmentVariable('AUTOMATION_SQL_PASSWORD','<valor>','Machine')
[Environment]::SetEnvironmentVariable('AUTOMATION_SMTP_PASSWORD','<valor>','Machine')
[Environment]::SetEnvironmentVariable('AUTOMATION_TELEGRAM_BOT_TOKEN','<valor>','Machine')
[Environment]::SetEnvironmentVariable('AUTOMATION_TELEGRAM_CHAT_ID','<valor>','Machine')
```

## Estructura SQL esperada (referencia)
Tabla: `dbo.AD_Users_Snapshot`
Campos sugeridos:
- `SamAccountName` (PK)
- `DisplayName`
- `GivenName`
- `Surname`
- `Mail`
- `Enabled`
- `LastSeen`

## Como ejecutar

```powershell
cd C:\Users\Nabetse\Downloads\server\Academici
.\ad-sql-snapshot.ps1
```

## Programar ejecucion automatica
Task Scheduler:
- Trigger: diario (ejemplo 06:00)
- Action: `powershell.exe`
- Arguments: `-ExecutionPolicy Bypass -File "C:\Users\Nabetse\Downloads\server\Academici\ad-sql-snapshot.ps1"`
- Ejecutar con cuenta de servicio con permisos AD + SQL

## Validacion post ejecucion
- Revisar archivo de log en `LogRoot`
- Confirmar filas actualizadas en SQL
- Verificar notificaciones en caso de error

## Seguridad y buenas practicas
- No hardcodear passwords
- Usar variables de entorno o cuenta administrada
- Limitar permisos de la cuenta del script
- Proteger carpeta de logs
---
## ‍ Desarrollado por Isaac Esteban Haro Torres
**Ingeniero en Sistemas · Full Stack · Automatización · Data**
-  Email: zackharo1@gmail.com
-  WhatsApp: 098805517
-  GitHub: https://github.com/ieharo1
-  Portafolio: https://ieharo1.github.io/portafolio-isaac.haro/
---
##  Licencia
© 2026 Isaac Esteban Haro Torres - Todos los derechos reservados.
