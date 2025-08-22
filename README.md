# Daily Development Recap

A GitHub Actions workflow that automatically generates daily development summaries by analyzing commits across all accessible repositories and sending them to Microsoft Teams.

## Features

-   **Cross-platform compatibility**: Works on Linux, macOS, and Windows
-   **Comprehensive commit analysis**: Fetches commits from all branches across all accessible repositories
-   **AI-powered summaries**: Uses ChatGPT to generate intelligent, concise summaries
-   **MS Teams integration**: Sends formatted summaries via webhook
-   **Robust error handling**: Graceful fallbacks and detailed logging
-   **Rate limit protection**: Handles GitHub API rate limits automatically
-   **Timezone support**: Configurable for different time zones

## How It Works

1. **Commit Fetching**: Scans all repositories and branches for commits from the previous workday by the specified author
2. **Data Processing**: Extracts commit messages, files changed, and statistics
3. **AI Summary**: Uses ChatGPT to generate a human-readable summary
4. **Delivery**: Sends the summary to MS Teams via webhook

## Author Tracking

The system can track commits from any GitHub user by setting the `AUTHOR_ACCOUNT` environment variable. This allows you to:

-   Track your own commits across all repositories
-   Monitor commits from team members or contributors
-   Generate reports for specific developers or teams
-   Use a service account to track commits from multiple users

## Setup

### 1. Repository Setup

Clone this repository and ensure the following structure:

```
.github/
├── scripts/
│   ├── daily-recap.sh          # Main orchestrator
│   ├── fetch-commits.sh        # GitHub API integration
│   ├── generate-summary.sh     # ChatGPT integration
│   ├── send-webhook.sh         # MS Teams webhook
│   └── debug-json.sh           # Debugging utility
└── workflows/
    └── daily-recap.yml         # GitHub Actions workflow
```

### 2. GitHub Secrets

Set up the following secrets in your GitHub repository:

-   `TOKEN_GITHUB`: GitHub Personal Access Token with `repo` and `read:org` scopes
-   `OPENAI_API_KEY`: OpenAI API key for ChatGPT access
-   `WEBHOOK_URL`: MS Teams webhook URL
-   `AUTHOR_ACCOUNT`: GitHub username whose commits you want to track

### 3. MS Teams Webhook

1. In your MS Teams channel, click the "..." menu
2. Select "Connectors"
3. Find "Incoming Webhook" and configure it
4. Copy the webhook URL to your GitHub secrets

## Configuration

### Schedule

The workflow runs daily at 7:00 AM Pacific Time by default. To modify:

```yaml
on:
    schedule:
        - cron: "0 15 * * *" # UTC time (7:00 AM PT = 15:00 UTC)
```

### Timezone

All operations use Pacific Time by default. To change:

```bash
export TZ='America/New_York'  # For Eastern Time
```

### Date Range Logic

-   **Monday**: Looks at Friday's commits
-   **Other days**: Looks at yesterday's commits

## Scripts Overview

### daily-recap.sh

Main orchestrator that:

-   Validates environment variables
-   Coordinates the entire process
-   Provides detailed logging
-   Handles cleanup

### fetch-commits.sh

GitHub API integration that:

-   Authenticates with GitHub
-   Fetches commits from all accessible repositories
-   Handles rate limiting
-   Processes multiple branches
-   Extracts commit details

### generate-summary.sh

ChatGPT integration that:

-   Processes commit data
-   Generates intelligent summaries
-   Handles API errors gracefully
-   Formats output for Teams

### send-webhook.sh

MS Teams integration that:

-   Creates adaptive cards
-   Sends formatted messages
-   Handles webhook responses
-   Provides delivery confirmation

## Troubleshooting

### Common Issues

1. **JSON parsing errors**: Usually caused by special characters in commit messages

    - Fixed with improved escaping and validation

2. **Rate limiting**: GitHub API limits exceeded

    - Script includes automatic rate limit handling

3. **Authentication failures**: Invalid or expired tokens

    - Check token permissions and expiration

4. **Timeout issues**: Network or API delays
    - Scripts include timeout protection

### Debug Mode

Run the debug script to check system health:

```bash
bash .github/scripts/debug-json.sh
```

### Manual Testing

Trigger the workflow manually:

1. Go to Actions tab in GitHub
2. Select "Daily Development Recap"
3. Click "Run workflow"

### Logs

On workflow failure, logs are automatically uploaded as artifacts for 7 days.

## API Requirements

### GitHub API

-   Personal Access Token with `repo` and `read:org` scopes
-   Rate limit: 5,000 requests/hour for authenticated users
-   Can search for commits by any GitHub user (not just the token owner)

### OpenAI API

-   API key with access to GPT-4o-mini model
-   Rate limit: Varies by plan

### MS Teams

-   Incoming webhook URL
-   No rate limits (but recommended to stay under 100 messages/minute)

## Security Considerations

-   All API keys are stored as GitHub secrets
-   Scripts use minimal required permissions
-   No sensitive data is logged
-   Temporary files are cleaned up automatically

## Performance

-   Typical runtime: 2-5 minutes
-   Handles repositories with thousands of commits
-   Automatic pagination for large datasets
-   Efficient deduplication of commits

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review the logs in GitHub Actions
3. Open an issue with detailed information
