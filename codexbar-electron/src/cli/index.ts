#!/usr/bin/env node
/**
 * CodexBar CLI
 * 
 * Command-line interface for querying AI provider usage.
 * Mirrors the functionality of the macOS bundled CLI.
 */

import { Command } from 'commander';
import { CodexProvider } from '../main/providers/codex/CodexProvider';
import { ClaudeProvider } from '../main/providers/claude/ClaudeProvider';
import { CursorProvider } from '../main/providers/cursor/CursorProvider';
import { GeminiProvider } from '../main/providers/gemini/GeminiProvider';
import { BaseProvider } from '../main/providers/BaseProvider';

const program = new Command();

// All available providers
const providers: Record<string, BaseProvider> = {
  codex: new CodexProvider(),
  claude: new ClaudeProvider(),
  cursor: new CursorProvider(),
  gemini: new GeminiProvider(),
  // Add more as needed
};

program
  .name('codexbar')
  .description('Monitor API usage limits for AI providers')
  .version('0.1.0');

program
  .command('status')
  .description('Show usage status for all configured providers')
  .option('-p, --provider <name>', 'Specific provider to check')
  .option('-j, --json', 'Output as JSON')
  .action(async (options) => {
    const providersToCheck = options.provider 
      ? [options.provider] 
      : Object.keys(providers);
    
    const results: Record<string, any> = {};
    
    for (const name of providersToCheck) {
      const provider = providers[name];
      if (!provider) {
        console.error(`Unknown provider: ${name}`);
        continue;
      }
      
      const configured = await provider.isConfigured();
      if (!configured) {
        results[name] = { status: 'not configured' };
        continue;
      }
      
      const result = await provider.refresh();
      results[name] = {
        status: result.state,
        usage: result.usage,
        error: result.error,
      };
    }
    
    if (options.json) {
      console.log(JSON.stringify(results, null, 2));
    } else {
      printStatus(results);
    }
  });

program
  .command('list')
  .description('List all available providers')
  .action(() => {
    console.log('Available providers:\n');
    for (const [id, provider] of Object.entries(providers)) {
      console.log(`  ${provider.icon} ${provider.name} (${id})`);
    }
  });

program
  .command('refresh')
  .description('Refresh usage data for all providers')
  .option('-p, --provider <name>', 'Specific provider to refresh')
  .action(async (options) => {
    const providersToRefresh = options.provider 
      ? [options.provider] 
      : Object.keys(providers);
    
    console.log('Refreshing...\n');
    
    for (const name of providersToRefresh) {
      const provider = providers[name];
      if (!provider) continue;
      
      const configured = await provider.isConfigured();
      if (!configured) {
        console.log(`  ${provider.icon} ${provider.name}: not configured`);
        continue;
      }
      
      const result = await provider.refresh();
      const status = result.state === 'success' ? '✓' : '✗';
      console.log(`  ${provider.icon} ${provider.name}: ${status}`);
    }
  });

function printStatus(results: Record<string, any>) {
  console.log('CodexBar Status\n');
  console.log('─'.repeat(50));
  
  for (const [name, data] of Object.entries(results)) {
    const provider = providers[name];
    if (!provider) continue;
    
    console.log(`\n${provider.icon} ${provider.name}`);
    
    if (data.status === 'not configured') {
      console.log('   Status: Not configured');
      continue;
    }
    
    if (data.status === 'error') {
      console.log(`   Status: Error - ${data.error}`);
      continue;
    }
    
    if (data.usage) {
      if (data.usage.session) {
        const s = data.usage.session;
        console.log(`   Session: ${s.displayString} (${s.percentage}%)`);
        if (s.resetCountdown) {
          console.log(`   Resets: ${s.resetCountdown}`);
        }
      }
      if (data.usage.weekly) {
        const w = data.usage.weekly;
        console.log(`   Weekly: ${w.displayString} (${w.percentage}%)`);
      }
      if (data.usage.monthly) {
        const m = data.usage.monthly;
        console.log(`   Monthly: ${m.displayString} (${m.percentage}%)`);
      }
      if (data.usage.cost) {
        console.log(`   Cost: ${data.usage.cost.displayString}`);
      }
    } else {
      console.log('   No usage data available');
    }
  }
  
  console.log('\n' + '─'.repeat(50));
}

program.parse();
