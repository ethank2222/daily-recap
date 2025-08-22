# Daily Development Recap

Automated GitHub Actions workflow that generates daily development summaries and sends them to Microsoft Teams.

## Features

- Runs automatically every day at 7:00 AM (configurable)
- Fetches commits from the previous workday (handles weekends automatically)
- Scans ALL repositories the user has access to (personal and organization repos)
- Uses AI (ChatGPT) to generate intelligent, prioritized summaries
- Sends formatted reports to Microsoft Teams via webhook
- Manual triggering available for testing

## Setup

### 1. GitHub Secrets

Add the following secrets to your repository:

- **`TOKEN_GITHUB`** - GitHub Personal Access Token
  - Required scopes: `repo`, `read:org`
  - Create at: https://github.com/settings/tokens

- **`OPENAI_API_KEY`** - OpenAI API Key
  - Get from: https://platform.openai.com/api-keys
  - Model used: gpt-4o-mini (for cost efficiency)

- **`WEBHOOK_URL`** - Microsoft Teams Incoming Webhook URL
  - Create in Teams: Channel → Connectors → Incoming Webhook
  - Format: `https://outlook.office.com/webhook/...`

### 2. Schedule Configuration

The workflow runs at 7:00 AM Pacific Time by default. To change:

Edit `.github/workflows/daily-recap.yml`:
```yaml
schedule:
  - cron: '0 15 * * *'  # 7 AM PT (UTC-8)
```

Use [crontab.guru](https://crontab.guru/) to calculate your desired schedule.

## Manual Testing

Trigger the workflow manually:
1. Go to Actions tab in your repository
2. Select "Daily Development Recap"
3. Click "Run workflow"

## How It Works

1. **Fetch Commits** (`fetch-commits.sh`)
   - Determines the date range (yesterday, or Friday if today is Monday)
   - Fetches all repositories accessible to the user
   - Retrieves commit details including files changed and statistics

2. **Generate Summary** (`generate-summary.sh`)
   - Processes all commits through ChatGPT
   - Creates prioritized, meaningful bullet points
   - Groups related changes together

3. **Send to Teams** (`send-webhook.sh`)
   - Formats the summary as an Adaptive Card
   - Sends to the configured Teams channel

## Output Example

The Teams message includes:
- Date of activity
- Total commits and repositories affected
- AI-generated summary with prioritized changes
- Specific file mentions for bug fixes

## Troubleshooting

- **No commits found**: Check if the user has made commits in the date range
- **Authentication failed**: Verify TOKEN_GITHUB has proper permissions
- **ChatGPT errors**: Check OPENAI_API_KEY validity and credits
- **Teams webhook fails**: Verify WEBHOOK_URL is correct and active

## Security Notes

- All tokens are stored as GitHub secrets
- Scripts use proper error handling and pipefail
- Temporary files are cleaned up automatically
- No sensitive data is logged

## License

MIT