# (c) ALLIANCE GROUP
# v.2024-01-29
# Параметры командной строки:
Param (
[string]$computer,
[string]$service
)
# Запуск с параметрами:
# .\имя_скрипта.ps1 -computer "Имя_или_адрес_компьютера" [-service "Имя_сервиса"]
#
# TODO: Форматирование отступов, удаление лишних строк и пробелов...
# TODO: Добавить процедуру генерации файла конфига вместо копирования заранее заданного (для вариативности настроек)...
# Global settings:
$global:ErrorActionPreference = "SilentlyContinue"
$error.clear()

# Debug mode variable:
$DEBUGMODE = $True

# Some helper variables:
$scriptPath = Split-Path $MyInvocation.MyCommand.Path -Parent
$scriptName = $MyInvocation.MyCommand.Name.split(".")[0]
$scriptLog = $scriptName + ".log"

# Дефолтное имя файла со списком компьютеров (должен находиться в той же папке, что и скрипт).
$computerList = ".\computers.csv" 
# Имя подкаталога, содержащего файлы с версиями zabbix_agent для двух платформ:
$src_path = ".\bin\*"
# Имена файлов zabbix_agent в версии для двух платформ (первый элемент -- для 64, второй -- для 32):
$zabbixAgentBins = @('zabbix_agentd64.exe','zabbix_agentd32.exe')
# Имя готового файла с конфигурацией:
$zabbixConf = "zabbix_agentd.conf"

# Путь к интерпретатору командной строки на удалённом компьютере:
$commandProcessor = 'C:\Windows\System32\cmd.exe'

# Дефолтное имя сервиса (обычно 'Zabbix Agent'):
$serviceName = "Zabbix Agent"


$src_folder_zabbix_agent = "$scriptPath/bin"


# Вспомогательная функция получения пути к файлу из полного пути:
function Get-PathFromFullPath($pathName) {  
    if ($pathName.StartsWith("`"")) {
        $pathName = $pathName.Substring(1)
        $index = $pathName.IndexOf("`"")
        if ($index -gt -1) {
            return $pathName.Substring(0, $index)
        }
        else {
            return $pathName
        }
    } 
    if ($pathName.Contains(" ")) {
        $index = $pathName.IndexOf(" ")
        return $pathName.Substring(0, $index)
    }
    return $pathName
}


# Вспомогательная функция определения разрядности платформы на целевом компьютере:
function Get-PlatformOnRemote($remoteName) {
    return $(Get-CimInstance -ClassName Win32_Processor -computername $remoteName | where {$_.DeviceID -eq "CPU0"} | Select AddressWidth).AddressWidth
}


# Функция установки zabbix_agent (вариант с установкой без внешних утилит, только средствами PowerShell):
function Install-ZabbixOnRemote($remoteName) {
    # TODO: Использовать внешние (глобальные) переменные только через передачу параметров функции...
    $dst_path = "\\$remoteName\c$\Program Files\$serviceName"
    #Создание новой папки на удалённом компьютере (базовый способ):
    New-Item "$dst_path" -Type Directory
    # TODO: Делать новую папку для сервиса методом Invoke-Command -Computer $srv -ScriptBlock {...

    # Копирование на удалённый компьютер содержимого каталога с исполнимым файлом агента забикса и файлом конфигурации:
    # TODO: Копирование только необходимых файлов (агент нужной разрядности и файл настроек)...
    Write-Output "INFO: Copy Zabbix Agent and config to '$dst_path'"
    # Copy-Item -Path $src_path -Destination $dst_path -Recurse -Force
    Copy-Item $src_path $dst_path -Force

    # Определение разрядности ОС на целевом компьютере:
    $bit = Get-PlatformOnRemote($remoteName)
    if ($DEBUGMODE) { Write-Output "DEBUG: Architecture on remote '$remoteName' is: $bit" }
    # Определение и использование исполнимого файла в зависимости от разрядности:
    if ($bit -like '*32*') {
        $zabbixAgentBin = $zabbixAgentBins[1]
    }
    else {
        $zabbixAgentBin = $zabbixAgentBins[0]
    }
    #
    # Установка службы агента забикса:
    #
    # Cборка переменной с командой агенту на установку самого себя (созданию сервиса):
    $zabbixAgentCmd = """C:\Program Files\" + $serviceName + "\" + $zabbixAgentBin + """ --config ""C:\Program Files\" + $serviceName + "\" + $zabbixConf + """ --install"
    if ($DEBUGMODE) { Write-Output "DEBUG: Zabbix Agent complete command line: $zabbixAgentCmd" }
    # Предварительная сборка параметров запуска процедуры удалённой установки с использованием командного процессора и командой агенту:
    $parameters = @{
        ComputerName = $remoteName
        ScriptBlock = { Param ($param1, $param2, $param3) & $param1 $param2 $param3 }
        ArgumentList =  $commandProcessor, '/C', $zabbixAgentCmd
    }
    # Запуска процедуры удалённой установки с ранее заданными параметрами:
    $res = Invoke-Command @parameters -Verbose -ErrorAction SilentlyContinue -ErrorVariable errres 2>$null 
    if ($DEBUGMODE) { Write-Output "DEBUG: Remote run result: $res" }
    if ($DEBUGMODE) { Write-Output "DEBUG: Remote run errors: $errres" }
    # Результат установки:
    if (($res -match 'installed successfully') -or ($errres -match 'installed successfully'))
    {
        Write-Output "INFO: Successfully Installed Zabbix Agent! Start UP Zabbix Agent on $remoteName!"
        # Удалённый запуск нового сервиса:
        Get-Service -Name "$serviceName*" -ComputerName $remoteName | Start-Service
    }
    elseif ($errres -match 'already exists')
    {
        Write-Output "INFO: Zabbix Agent Already Exists on $remoteName."
        # Удалённый запуск уже имеющегося сервиса:
        Get-Service -Name "$serviceName*" -ComputerName $remoteName | Start-Service
    }
    else {
        Write-Output "ERROR: Zabbix Agent not Installed on $remoteName"
    }
}

# Вспомогательная функция удаления сервиса на удалённом компьютере:
function Del-ServiceOnRemote {
    Param(
        [string]$remoteName,
        [string]$remoteService
    )
    $res = $(Get-CimInstance -ClassName Win32_Service -Filter "Name='$remoteService'" -ComputerName $remoteName | Remove-CimInstance -ErrorVariable errres 2>$null)
    if ($DEBUGMODE) { Write-Output "DEBUG: Remote delete service result: $res" }   
    if ($DEBUGMODE) { Write-Output "DEBUG: Remote delete service errors: $errres" }
    # TODO: [0x00000430] Указанная служба была отмечена для удаления.
}


# ***************** START OF SCRIPT:

# Запись в лог-файл всего, что выводит скрипт:
Start-Transcript -Append $scriptPath\$scriptLog

if ($DEBUGMODE) { Write-Output "INFO: DEBUG MODE is ON" }


# Если в командной строке задан параметр -Computer, то записать его значение во временный файл 
# и далее использовать этот файл как список компьютеров для установки (вместо дефолтного 'computers.csv'):
if ($computer) {
    $computerList = $scriptPath + "\computers.tmp"
    Set-Content -Path "$computerList" -Value "$computer"
    if ($DEBUGMODE) { Write-Output "DEBUG: Command line parameter 'computer' was set as: $computer" }
}

# Если задано имя сервиса, то использовать его (вместо дефолтного 'Zabbix Agent'):
if ($service) {
    $serviceName = $service
    if ($DEBUGMODE) { Write-Output "DEBUG: Command line parameter 'service' was set to: $service" }
}


#Основной цикл по списку компьютеров из файла:
Import-CSV "$computerList" -header("ComputerName") | ForEach {
    $srv = $_.ComputerName

    # TODO: Добавить проверку полученного имени на "закомментированность"...
    # if ( !($srv -match "#") ){ ... }

    Write-Output "$("*"*40)"
    Write-Output "INFO: Computer: $srv"
    if ((Test-NetConnection -ComputerName $srv).PingSucceeded)
    {
        # Проверка наличия сервиса на сервере:
        $testservice = Get-Service -Name "$serviceName*" -ComputerName $srv
        # Если сервисов с похожим именем больше нуля:
        if (!@($testservice).Count -eq 0)
        {
            Write-Output "INFO: Service '$serviceName' found on $srv."
            # Получение объект типа "сервис" в переменную:
            $ServiceAgentZabbix=Get-Service -Name "$serviceName*" -ComputerName $srv
            if ($DEBUGMODE) { Write-Output "DEBUG: Service raw name is: $ServiceAgentZabbix" }
            # Получение из объекта поле имя (в отдельную переменную):
            $ServiceAgentZabbixName = $($ServiceAgentZabbix.Name)
            if ($DEBUGMODE) { Write-Output "DEBUG: Service pretty name is: $ServiceAgentZabbixName" }

            #
            # Остановка службы:
            #
            Write-Output "INFO: Stop Service '$serviceName' on $srv."
            Stop-Service $ServiceAgentZabbix

            # Определение некоторых параметров запуска службы (командная строка, путь, исполнимый файл):
            $serviceData = Get-CimInstance -ClassName Win32_service -Filter "Name='$ServiceAgentZabbixName'" -Property PathName,Name,DisplayName,State -Computername $srv
            $servicefullcommand = $($serviceData.PathName)
            if ($DEBUGMODE) { Write-Output "DEBUG: Service Full Command line: $servicefullcommand" }
            $serviceshortcommand = Get-PathFromFullPath $servicefullcommand
            if ($DEBUGMODE) { Write-Output "DEBUG: Service Path to Exe: $serviceshortcommand" }
            $servicepathonly = Split-Path $serviceshortcommand -Parent
            $servicepathonly = $servicepathonly + "\"
            if ($DEBUGMODE) { Write-Output "DEBUG: Service Path Only: $servicepathonly" }
            $servicefilename = Split-Path $serviceshortcommand -Leaf
            if ($DEBUGMODE) { Write-Output "DEBUG: Service Executable: $servicefilename" }

            #
            # Удаление службы:
            #
            Write-Output "INFO: Delete Service '$serviceName' on $srv"
            Del-ServiceOnRemote -remoteName $srv -remoteService $ServiceAgentZabbixName
            # TODO: Добавить проверку, что сервис действительно удалён, а не "помечен на удаление" (в некоторых случаях)...

            #
            # Удаление ветки реестра:
            #
            Invoke-Command -ComputerName $srv -ScriptBlock {Remove-Item -Path HKLM:"\SYSTEM\CurrentControlSet\Services\EventLog\Application\Zabbix Agent" -Recurse}
            #
            # Удаление содержимого каталога (только если ранее удалось получить путь к файлам из описания сервиса):
            #
            if ( ! ($servicepathonly -eq "\") ) {
              Write-Output "INFO: Deleted all files on $srv in folder '$servicepathonly' excluding *.log"
              $res = Invoke-Command -Computer $srv -ScriptBlock {Remove-Item -Path $args[0] -Exclude $args[1] -Force -Recurse -ErrorAction SilentlyContinue -WarningAction SilentlyContinue} -ArgumentList "$servicepathonly","*.log" -ErrorVariable errres 2>$null
              if ($DEBUGMODE) { Write-Output "DEBUG: Remote delete files result: $res" }
              if ($DEBUGMODE) { Write-Output "DEBUG: Remote delete files errors: $errres" }
            }
        }
        else {
            Write-Output "INFO: Service '$serviceName' not found on $srv."
            Write-Output "INFO: Install one:"
        }
    # Вызов подпрограммы установки:
    Install-ZabbixOnRemote $srv
    }
    else { 
        Write-Output "The server '$srv' is unavailable!"
    }
}

# Отмена (завершение) записи в лог-файл:
Stop-Transcript

# ***************** END OF SCRIPT