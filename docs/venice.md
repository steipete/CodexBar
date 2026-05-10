# Venice

[Venice](https://venice.ai) is an AI inference platform that provides API access to various language models.

## Setup

1. Sign up or log in at https://venice.ai
2. Navigate to your API settings at https://venice.ai/settings/api
3. Create or retrieve your API key
4. In CodexBar, add your Venice API key via:
   - Preferences > Providers > Venice, OR
   - Set the environment variable `VENICE_API_KEY` or `VENICE_KEY`

## Balance Query

CodexBar fetches your current Venice API balance using the `/api/v1/billing/balance` endpoint.

### Balance Types

- **DIEM**: Venice's native credits (if epoch allocation is configured)
- **USD**: Dollar balance if available
- **Consumption Currency**: Indicates which currency is active for current billing

### Display

CodexBar shows:
- Current remaining balance (DIEM or USD)
- Epoch allocation progress (if applicable)
- "Balance unavailable" if consumption is temporarily disabled

## Troubleshooting

**No balance showing?**
- Verify your API key is correct
- Check network connectivity
- Ensure your Venice account has an active balance

**API rate limiting?**
- CodexBar caches balance data and updates every 30 seconds
- If you hit rate limits, wait a moment before refreshing
