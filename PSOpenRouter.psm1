Import-Module PSModuleManager
Import-Module Read-Menu

$SettingsManager = PSModuleManager -ScriptRoot $PSScriptRoot -FileName 'settings'
$Settings = $SettingsManager.FileContent

$PromptsManager = PSModuleManager -ScriptRoot $PSScriptRoot -FileName 'prompts'
$Prompts = PromptsManager.FileContent

# Will ddd this as a setting later.
$LLMTextColor = 'Cyan'

$CurrentMessageHistory = [System.Collections.Generic.List[PSObject]]::new()

function OR() {
    $selectedAction = Read-Menu -Header 'PSOpenRouter' -Options @('New session', 'Settings') -ExitOption 'Exit' -CleanUpAfter

    switch ($selectedAction) {
        'New session' {
            $promptOptions = 'None' + $Prompts.PSObject.Properties.Name
            
            $selectedPrompt = Read-Menu -Header 'Select prompt' -Options $promptOptions -ExitOption 'Exit' -CleanUpAfter

            switch ($selectedPrompt) {
                'None' { 
                    New-Session -SystemPrompt $null
                }

                default {
                    New-Session -SystemPrompt $Prompts.$selectedPrompt
                }

                'Exit' { break }
            }
        }
        'Settings' {
            Open-SettingsMenu
        }

        'Exit' { break }
    }
}

function New-Session($SystemPrompt) {
    $CurrentMessageHistory.Clear()

    $httpClient = [System.Net.Http.HttpClient]::new()

    Write-MenuHeader -Header "PSOpenRouter session"

    while ($true) {
        $userInput = Read-Host "You"
        Write-Host

        try {
            $stream = New-Stream -UserInput $userInput -SystemPrompt $SystemPrompt -HttpClient $httpClient 
            
            $modelResponse = Read-Stream $stream

            Save-ToCurrentMessageHistory -UserInput $userInput -ModelResponse $modelResponse
        }

        catch { throw "Error: $_" }
    }
}

function New-Stream($UserInput, $SystemPrompt, $HttpClient) {
    $messages = @()

    if ($SystemPrompt) {
        $messages += @{
            role    = 'system'
            content = $SystemPrompt
        }    
    }

    if ($CurrentMessageHistory.Count) {
        $messages += $CurrentMessageHistory
    }

    $messages += @{
        role    = 'user'
        content = $UserInput
    }

    $requestBody = @{
        model    = $Settings.Model.CurrentModel
        messages = $messages
        stream   = 'true'
    } | ConvertTo-Json

    $request = [System.Net.Http.HttpRequestMessage]::new('POST', $($Settings.ApiUrl))
    $request.Headers.Add('Authorization', "Bearer $($Settings.ApiKey)")
    $request.Content = [System.Net.Http.StringContent]::new($RequestBody, [System.Text.Encoding]::UTF8, 'application/json')

    $cancellationToken = [System.Threading.CancellationTokenSource]::new().Token

    $response = $httpClient.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellationToken).GetAwaiter().GetResult()

    if (-not $response.IsSuccessStatusCode) {
        throw "Request failed with status code $($response.StatusCode)."
    }

    return $response.Content.ReadAsStreamAsync($cancellationToken).GetAwaiter().GetResult()
}

function Read-Stream($Stream) {
    $reader = [System.IO.StreamReader]::new($Stream)

    $modelResponse = ""

    $firstToken = $true

    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        
        $valuesToSkip = @(': OPENROUTER PROCESSING', 'data: [DONE]', '')

        if ($line -in $valuesToSkip) { continue }

        try {
            $parsedLine = ($line.Substring(6) | ConvertFrom-Json).choices.delta.content

            # Trim leading whitespace from the first token.
            if ($firstToken -and $parsedLine) {
                $parsedLine = $ParsedLine.TrimStart()
                $firstToken = $false
            }

            Write-Host -NoNewLine -ForegroundColor $LLMTextColor $parsedLine
            $modelResponse += $parsedLine
        }

        catch { throw "Stream error: $_" }
    }

    Write-Host `n

    return $modelResponse
}

function Save-ToCurrentMessageHistory($UserInput, $ModelResponse) {
    if ($ModelResponse) {
        $CurrentMessageHistory.Add(@{
                role    = 'user'
                content = $UserInput
            })
        $CurrentMessageHistory.Add(@{
                role    = 'assistant'
                content = $ModelResponse
            })
    }
}

function Open-SettingsMenu() {
    $selectedAction = Read-Menu -Header 'PSOpenRouter Settings' -Options @('Model', 'Prompts') -ExitOption 'Exit' -CleanUpAfter

    switch ($selectedAction) {
        'Model' {
            Open-ModelMenu
        }

        'Prompts' {
            Open-PromptsMenu
        }

    }
}

function Open-ModelMenu() {
    $selectedAction = Read-Menu -Header "Model settings" -Subheader ("Current model: $($Settings.CurrentModel)") -Options ('Add model', 'Change model') -ExitOption 'Exit' -CleanUpAfter

    switch ($selectedAction) {
        'Add model' {
            $newModel = Read-Input -Header 'Add model' -Instruction 'Enter OpenRouter model id' -CleanUpAfter

            if (-not $newModel) {
                Write-Host "No model provided." -ForegroundColor Yellow
            }

            $modelsList = $Settings.Model.Models + $newModel

            $SettingsManager.SetValue(('Model', 'CurrentModel'), $newModel)
            $SettingsManager.SetValue(('Model', 'Models'), $modelsList)

            Write-Host "$newModel set to current model."`n -ForegroundColor Yellow
        }
        'Change model' {

            $selectedModel = Read-Menu -Header 'Select model' -Options $Settings.Model.Models -ExitOption 'Exit' -CleanUpAfter

            switch ($selectedModel) {
                default {
                    $SettingsManager.SetValue(('Model', 'CurrentModel'), $selectedModel)
                    Write-Host "Current model set to $selectedModel."`n -ForegroundColor Yellow
                }

                'Exit' { Write-Host 'Current model not changed.'`n -ForegroundColor Yellow; break }

            }
        }
        'Exit' { break }
    }
}

Export-ModuleMember -Function OR
# TODO: Rename OR to PSOpenRouter and export both variants in a manifest.