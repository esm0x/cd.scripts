#First install the openai module with the command below:
#Install-Module OpenAI

# Import the OpenAI module
Import-Module OpenAI

# Set your OpenAI API key
$apiKey = "YOUR_API_KEY_HERE"

# Set the prompt and initial message
$prompt = "Hello, ChatGPT!"
$message = ""

# Loop until the user types "exit"
while ($message -ne "exit") {
    # Get the user's input
    $message = Read-Host -Prompt $prompt

    # Send the user's input to ChatGPT and get the response
    $response = Invoke-OpenAICompletion -Prompt $message -ApiKey $apiKey -ModelId "davinci" -MaxTokens 50

    # Print the response
    Write-Host $response.choices.text
}
