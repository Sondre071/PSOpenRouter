Import-Module PSModuleManager
Import-Module Read-Menu

$SettingsManager = PSModuleManager -ScriptRoot $PSScriptRoot -FileName 'settings'
$Settings = $SettingsManager.FileContent

$LLMTextColor = 'Cyan'

$CurrentMessageHistory = [System.Collections.Generic.List[PSObject]]::new()

function OR() {
    $menu = { Open-MainMenu }
    while ($menu) {
        $menu = & $menu
    }
}

function Open-MainMenu() {
    $action = Read-Menu -Header 'PSOpenRouter' -Options ('New session', 'Settings') -ExitOption 'Exit'
    switch ($action) {
        'New session' { return { Open-NewSessionMenu } }

        'Settings' { return { Open-SettingsMenu } }

        'Exit' { return $null }
    }
}

function Open-NewSessionMenu() {
    $promptOptions = @('None') + $SettingsManager.GetFileNames('prompts')
            
    $selectedPrompt = Read-Menu -Header 'Select prompt' -Options $promptOptions -ExitOption 'Back'

    switch ($selectedPrompt) {
        'None' { New-Session -SystemPrompt $null }

        default {
            $content = $SettingsManager.GetFile("prompts/$selectedPrompt.txt")
            $content ??= $SettingsManager.GetFile("prompts/$selectedPrompt.md")

            New-Session -SystemPrompt $content }

        'Back' { return { Open-MainMenu } }
    }
}

function Open-SettingsMenu() {
    $action = Read-Menu -Header 'Settings' -Options @('Model', 'Prompts') -ExitOption 'Back'

    switch ($action) {
        'Model' { return { Open-ModelMenu } }

        'Prompts' { return { Open-PromptsMenu } }

        'Back' { return { Open-MainMenu } }
    }
}

function Open-ModelMenu() {
    $selectedAction = Read-Menu -Header 'Model settings' -Subheaders ("Current model: $($Settings.CurrentModel)", '') -Options ('Add model', 'Change model', 'Remove model') -ExitOption 'Back'

    switch ($selectedAction) {
        'Add model' {
            $newModel = Read-Input -Header 'Add model' -Instruction 'Model id'

            if ($newModel) {
                $modelsList = $Settings.Models + $newModel

                $SettingsManager.Set(('CurrentModel'), $newModel, $True)
                $SettingsManager.Set(('Models'), $modelsList, $True)
            }

            return { Open-ModelMenu }
        }

        'Change model' {
            $selectedModel = Read-Menu -Header 'Select model' -Options $Settings.Models -ExitOption 'Exit'

            switch ($selectedModel) {
                default {
                    $SettingsManager.Set(('CurrentModel'), $selectedModel, $True)
                    return { Open-ModelMenu }
                }

                'Exit' { return { Open-ModelMenu } }
            }
        }

        'Remove model' { return { Open-RemoveModelMenu } }

        'Back' { return { Open-SettingsMenu } }
    }
}

function Open-RemoveModelMenu() {
    while ($true) {

        $selectedModel = Read-Menu -Header 'Delete model' -Options $Settings.Models -ExitOption 'Back'
        switch ($selectedModel) {
            default {
                $Settings.Models = $Settings.Models -ne $selectedModel
                $SettingsManager.Set(('Models'), $Settings.Models, $true)

                if ($selectedModel -eq $Settings.CurrentModel) {
                    $SettingsManager.Set(('CurrentModel'), '', $true)
                }
            }

            'Back' { return { Open-ModelMenu } }
        }
    }
}

function Open-PromptsMenu {

    $action = Read-Menu -Header 'Prompt settings' -Options ('Add prompt') -ExitOption 'Back'
    switch ($action) {

        'Add prompt' {
            $newPromptName = Read-Input -Header 'Add new prompt' -Instruction 'Name'
            $newPrompt = Read-Input -Header 'New prompt' -Subheaders ("Name: $newPromptName", '') -Instruction 'Prompt'

            if (-not $newPrompt) {
                break
            }

            $SettingsManager.SetFile("prompts/$newPromptName.txt", $newPrompt)

            return { Open-PromptsMenu }
        }

        'Back' { return { Open-SettingsMenu } }
    }
}

function New-Session($SystemPrompt) {
    $CurrentMessageHistory.Clear()

    $httpClient = [System.Net.Http.HttpClient]::new()

    Write-MenuHeader -Header 'Chat session'
    Write-Host

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
        model    = $Settings.CurrentModel
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
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') {
            break
        }

        $line = $reader.ReadLine()
        
        $valuesToSkip = (': OPENROUTER PROCESSING', 'data: [DONE]', '')

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

Export-ModuleMember -Function OR
# TODO: Rename OR to PSOpenRouter and export both variants in a manifest.