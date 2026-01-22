/**
 * Gemini (Google) Provider
 * 
 * Fetches usage from Gemini CLI session files stored in ~/.gemini/tmp/
 * Each session contains messages with token counts that we aggregate.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

interface GeminiTokens {
  input: number;
  output: number;
  cached?: number;
  thoughts?: number;
  tool?: number;
  total?: number;
}

interface GeminiMessage {
  id: string;
  timestamp: string;
  type: string;
  content?: string;
  tokens?: GeminiTokens;
  model?: string;
}

interface GeminiSession {
  sessionId: string;
  projectHash: string;
  startTime: string;
  lastUpdated: string;
  messages: GeminiMessage[];
  summary?: string;
}

interface ModelUsage {
  model: string;
  requests: number;
  inputTokens: number;
  outputTokens: number;
  cachedTokens: number;
}

export class GeminiProvider extends BaseProvider {
  readonly id = 'gemini';
  readonly name = 'Gemini';
  readonly icon = '💎';
  readonly websiteUrl = 'https://gemini.google.com';
  readonly statusPageUrl = 'https://status.cloud.google.com';
  
  private geminiDir = path.join(os.homedir(), '.gemini');
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if gemini CLI exists
      const result = await runCommand('gemini', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for .gemini directory with oauth credentials
    const oauthPath = path.join(this.geminiDir, 'oauth_creds.json');
    try {
      await fs.access(oauthPath);
      return true;
    } catch {
      // Also check for Google Cloud credentials
      const credPath = path.join(os.homedir(), '.config', 'gcloud', 'application_default_credentials.json');
      try {
        await fs.access(credPath);
        return true;
      } catch {
        return false;
      }
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Read all session files from ~/.gemini/tmp/*/chats/*.json
      const usage = await this.aggregateSessionUsage();
      
      if (usage) {
        return usage;
      }
    } catch (error) {
      logger.error('Failed to fetch Gemini usage:', error);
    }
    
    return null;
  }
  
  /**
   * Aggregate usage from all Gemini CLI session files
   */
  private async aggregateSessionUsage(): Promise<ProviderUsage | null> {
    const tmpDir = path.join(this.geminiDir, 'tmp');
    
    try {
      await fs.access(tmpDir);
    } catch {
      logger.debug('Gemini tmp directory not found');
      return null;
    }
    
    const modelUsage = new Map<string, ModelUsage>();
    let totalRequests = 0;
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let totalCachedTokens = 0;
    
    // Get today's date for daily filtering
    const today = new Date();
    const todayStr = today.toISOString().split('T')[0];
    
    // Get week start (Sunday)
    const weekStart = new Date(today);
    weekStart.setDate(today.getDate() - today.getDay());
    weekStart.setHours(0, 0, 0, 0);
    
    // Get month start
    const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
    
    let dailyInputTokens = 0;
    let dailyOutputTokens = 0;
    let dailyRequests = 0;
    
    let weeklyInputTokens = 0;
    let weeklyOutputTokens = 0;
    let weeklyRequests = 0;
    
    let monthlyInputTokens = 0;
    let monthlyOutputTokens = 0;
    let monthlyRequests = 0;
    
    try {
      // List all project directories in tmp
      const entries = await fs.readdir(tmpDir, { withFileTypes: true });
      
      for (const entry of entries) {
        if (!entry.isDirectory() || entry.name === 'bin') continue;
        
        const chatsDir = path.join(tmpDir, entry.name, 'chats');
        
        try {
          await fs.access(chatsDir);
        } catch {
          continue; // No chats directory
        }
        
        // Read all session files
        const sessionFiles = await fs.readdir(chatsDir);
        
        for (const file of sessionFiles) {
          if (!file.endsWith('.json') || !file.startsWith('session-')) continue;
          
          const sessionPath = path.join(chatsDir, file);
          
          try {
            const content = await fs.readFile(sessionPath, 'utf-8');
            const session: GeminiSession = JSON.parse(content);
            
            // Process each message with tokens
            for (const message of session.messages) {
              if (!message.tokens || message.type !== 'gemini') continue;
              
              const { input, output, cached = 0 } = message.tokens;
              const model = message.model || 'unknown';
              const msgDate = new Date(message.timestamp);
              
              // Aggregate by model
              const existing = modelUsage.get(model) || {
                model,
                requests: 0,
                inputTokens: 0,
                outputTokens: 0,
                cachedTokens: 0,
              };
              
              existing.requests += 1;
              existing.inputTokens += input;
              existing.outputTokens += output;
              existing.cachedTokens += cached;
              modelUsage.set(model, existing);
              
              // Total counters
              totalRequests += 1;
              totalInputTokens += input;
              totalOutputTokens += output;
              totalCachedTokens += cached;
              
              // Time-based filtering
              if (msgDate.toISOString().split('T')[0] === todayStr) {
                dailyRequests += 1;
                dailyInputTokens += input;
                dailyOutputTokens += output;
              }
              
              if (msgDate >= weekStart) {
                weeklyRequests += 1;
                weeklyInputTokens += input;
                weeklyOutputTokens += output;
              }
              
              if (msgDate >= monthStart) {
                monthlyRequests += 1;
                monthlyInputTokens += input;
                monthlyOutputTokens += output;
              }
            }
          } catch (err) {
            logger.debug(`Failed to parse session file ${file}:`, err);
          }
        }
      }
    } catch (error) {
      logger.error('Failed to read Gemini sessions:', error);
      return null;
    }
    
    if (totalRequests === 0) {
      return null;
    }
    
    // Gemini CLI doesn't have explicit limits, so we show usage without percentage
    // For free tier, there are rate limits but no monthly caps
    // We'll show token counts with a reasonable display
    
    const usage: ProviderUsage = {};
    
    // Session = today's usage
    if (dailyRequests > 0) {
      const dailyTotalTokens = dailyInputTokens + dailyOutputTokens;
      usage.session = {
        used: dailyTotalTokens,
        limit: 1000000, // Arbitrary high limit for display
        percentage: Math.min(100, Math.round((dailyTotalTokens / 1000000) * 100)),
        displayString: `${dailyRequests} reqs · ${formatTokenCount(dailyInputTokens)} in · ${formatTokenCount(dailyOutputTokens)} out`,
      };
    }
    
    // Weekly usage
    if (weeklyRequests > 0) {
      const weeklyTotalTokens = weeklyInputTokens + weeklyOutputTokens;
      usage.weekly = {
        used: weeklyTotalTokens,
        limit: 10000000, // Arbitrary high limit
        percentage: Math.min(100, Math.round((weeklyTotalTokens / 10000000) * 100)),
        displayString: `${weeklyRequests} reqs · ${formatTokenCount(weeklyInputTokens)} in · ${formatTokenCount(weeklyOutputTokens)} out`,
      };
    }
    
    // Monthly usage
    if (monthlyRequests > 0) {
      const monthlyTotalTokens = monthlyInputTokens + monthlyOutputTokens;
      usage.monthly = {
        used: monthlyTotalTokens,
        limit: 50000000, // Arbitrary high limit
        percentage: Math.min(100, Math.round((monthlyTotalTokens / 50000000) * 100)),
        displayString: `${monthlyRequests} reqs · ${formatTokenCount(monthlyInputTokens)} in · ${formatTokenCount(monthlyOutputTokens)} out`,
      };
    }
    
    // Log model breakdown for debugging
    logger.info('Gemini usage by model:');
    for (const [model, stats] of modelUsage) {
      logger.info(`  ${model}: ${stats.requests} reqs, ${stats.inputTokens} in, ${stats.outputTokens} out`);
    }
    
    return Object.keys(usage).length > 0 ? usage : null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}

/**
 * Format token count for display (e.g., 1234 -> "1.2K", 1234567 -> "1.2M")
 */
function formatTokenCount(count: number): string {
  if (count >= 1000000) {
    return `${(count / 1000000).toFixed(1)}M`;
  }
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1)}K`;
  }
  return count.toString();
}
