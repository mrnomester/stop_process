# Проверка прав администратора
function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Перезапуск с правами администратора
if (-not (Test-IsAdmin)) {
    Write-Host "Требуются права администратора. Перезапуск с повышенными привилегиями..." -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Definition
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
    exit
}

# Функция для завершения процесса через WMI
function Stop-Process-WMI {
    param(
        [string]$ComputerName,
        [int]$ProcessId
    )
    
    try {
        $process = Get-WmiObject -Class Win32_Process -Filter "ProcessId = $ProcessId" `
            -ComputerName $ComputerName -ErrorAction Stop
        $result = $process.Terminate()
        
        if ($result.ReturnValue -eq 0) {
            return $true
        }
        else {
            Write-Host "Ошибка WMI (код $($result.ReturnValue))" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "Ошибка WMI: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Функция для завершения процесса через WinRM
function Stop-Process-WinRM {
    param(
        [string]$ComputerName,
        [int]$ProcessId
    )
    
    try {
        $scriptBlock = {
            param($pid_val)
            Stop-Process -Id $pid_val -Force -ErrorAction Stop
        }
        
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock `
            -ArgumentList $ProcessId -ErrorAction Stop
        
        return $true
    }
    catch {
        Write-Host "Ошибка WinRM: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Основной скрипт
try {
    # Запрос имени компьютера
    $pc_name = Read-Host "`nВведите имя компьютера (ENTER для локального ПК)"
    if ([string]::IsNullOrWhiteSpace($pc_name)) {
        $pc_name = "."
        $isLocal = $true
    }
    else {
        $isLocal = $false
    }

    # Проверка доступности
    if (-not $isLocal) {
        Write-Host "`nПроверка доступности $pc_name..." -ForegroundColor Cyan
        $ping_result = Test-Connection -ComputerName $pc_name -Count 2 -Quiet -ErrorAction SilentlyContinue
        
        if (-not $ping_result) {
            Write-Host "`nОшибка: $pc_name недоступен!" -ForegroundColor Red
            Write-Host "Возможные причины:`n   - Компьютер выключен`n   - Проблемы с сетью`n   - Блокировка ICMP" -ForegroundColor Yellow
            exit
        }
    }
    
    # Запрос имени процесса
    $processName = Read-Host "`nВведите имя процесса (можно часть имени)"
    if ([string]::IsNullOrWhiteSpace($processName)) {
        Write-Host "Имя процесса не может быть пустым!" -ForegroundColor Red
        exit
    }

    # Получение процессов
    Write-Host "`nПоиск процессов '$processName' на $pc_name..." -ForegroundColor Cyan
    $processes = @()
    
    # Для локального компьютера
    if ($isLocal) {
        $processes = Get-Process -Name "*$processName*" -ErrorAction SilentlyContinue | 
                     Select-Object Id, ProcessName, @{Name="MachineName"; Expression={"$env:COMPUTERNAME"}}
    }
    # Для удаленного компьютера через WMI
    else {
        try {
            $processes = Get-WmiObject -Class Win32_Process -ComputerName $pc_name -Filter "Name LIKE '%$processName%'" -ErrorAction Stop |
                         Select-Object ProcessId, Name, @{Name="MachineName"; Expression={$pc_name}} |
                         ForEach-Object {
                             [PSCustomObject]@{
                                 Id = $_.ProcessId
                                 ProcessName = $_.Name
                                 MachineName = $_.MachineName
                             }
                         }
            Write-Host "Использован метод: WMI" -ForegroundColor DarkCyan
        }
        catch {
            Write-Host "WMI недоступен: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Попытка использовать WinRM..." -ForegroundColor Cyan
            
            try {
                $processes = Invoke-Command -ComputerName $pc_name -ScriptBlock {
                    param($name) 
                    Get-Process -Name "*$name*" -ErrorAction SilentlyContinue |
                    Select-Object Id, ProcessName, @{Name="MachineName"; Expression={$env:COMPUTERNAME}}
                } -ArgumentList $processName -ErrorAction Stop
                
                Write-Host "Использован метод: WinRM" -ForegroundColor DarkCyan
            }
            catch {
                Write-Host "Ошибка WinRM: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Не удалось получить список процессов!" -ForegroundColor Red
                exit
            }
        }
    }

    # Проверка результатов
    if (-not $processes -or $processes.Count -eq 0) {
        Write-Host "`nПроцессы не найдены!" -ForegroundColor Yellow
        exit
    }

    # Вывод списка процессов
    Write-Host "`nНайдено процессов: $($processes.Count)" -ForegroundColor Green
    $processes | Format-Table -Property Id, ProcessName, MachineName -AutoSize

    # Подтверждение
    $confirmation = Read-Host "`nВы уверены, что хотите завершить эти процессы? (Y/N)"
    if ($confirmation -ne 'Y') {
        Write-Host "Отмена операции..." -ForegroundColor Yellow
        exit
    }

    # Завершение процессов
    Write-Host "`nЗавершение процессов..." -ForegroundColor Cyan
    $successCount = 0
    $errorCount = 0

    foreach ($process in $processes) {
        try {
            $completed = $false
            
            # Для локального компьютера
            if ($isLocal) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $completed = $true
            }
            # Для удаленного компьютера
            else {
                # Сначала пробуем WMI
                if (-not $completed) {
                    $completed = Stop-Process-WMI -ComputerName $pc_name -ProcessId $process.Id
                }
                
                # Если WMI не сработал, пробуем WinRM
                if (-not $completed) {
                    $completed = Stop-Process-WinRM -ComputerName $pc_name -ProcessId $process.Id
                }
            }
            
            if ($completed) {
                Write-Host "Успешно завершен: $($process.ProcessName) (PID: $($process.Id))" -ForegroundColor Green
                $successCount++
            }
            else {
                Write-Host "Не удалось завершить: $($process.ProcessName) (PID: $($process.Id))" -ForegroundColor Red
                $errorCount++
            }
        }
        catch {
            Write-Host "Ошибка завершения $($process.ProcessName) (PID: $($process.Id)): $_" -ForegroundColor Red
            $errorCount++
        }
    }

    # Итоговый отчет
    Write-Host "`nРезультаты:" -ForegroundColor Cyan
    Write-Host "Успешно завершено: $successCount" -ForegroundColor Green
    
    # Исправленная строка с условным оператором
    if ($errorCount -gt 0) {
        Write-Host "Не удалось завершить: $errorCount" -ForegroundColor Red
    }
    else {
        Write-Host "Не удалось завершить: $errorCount" -ForegroundColor Gray
    }
    
    # Рекомендации
    if ($errorCount -gt 0) {
        Write-Host "`nРекомендации:" -ForegroundColor Yellow
        Write-Host "1. Проверьте правильность имени процесса"
        Write-Host "2. Убедитесь в наличии прав администратора"
        Write-Host "3. Проверьте доступность WMI и WinRM на целевом ПК"
        Write-Host "4. Для системных процессов может потребоваться перезагрузка"
    }
}
catch {
    Write-Host "`nКритическая ошибка: $_" -ForegroundColor Red
}