/**
 * Claude (Anthropic) Provider
 * 
 * Fetches usage from Claude CLI's stats-cache.json file stored in ~/.claude/
 * This file contains detailed usage statistics including:
 * - Daily activity (message count, session count, tool calls)
 * - Token usage by model
 * - Total sessions and messages
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

interface DailyActivity {
  date: string;
  messageCount: number;
  sessionCount: number;
  toolCallCount: number;
}

interface DailyModelTokens {
  date: string;
  tokensByModel: Record<string, number>;
}

interface ModelUsageStats {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens: number;
  cacheCreationInputTokens: number;
  webSearchRequests: number;
  costUSD: number;
  contextWindow: number;
}

interface ClaudeStatsCache {
  version: number;
  lastComputedDate: string;
  dailyActivity: DailyActivity[];
  dailyModelTokens: DailyModelTokens[];
  modelUsage: Record<string, ModelUsageStats>;
  totalSessions: number;
  totalMessages: number;
  longestSession?: {
    sessionId: string;
    duration: number;
    messageCount: number;
    timestamp: string;
  };
  firstSessionDate?: string;
  hourCounts?: Record<string, number>;
}

export class ClaudeProvider extends BaseProvider {
  readonly id = 'claude';
  readonly name = 'Claude';
  readonly icon = '🎭';
  readonly websiteUrl = 'https://claude.ai';
  readonly statusPageUrl = 'https://status.anthropic.com';
  
  private claudeDir = path.join(os.homedir(), '.claude');
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if claude CLI is available
      const result = await runCommand('claude', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found, check for config directory
    }
    
    // Check for .claude directory with stats
    const statsPath = path.join(this.claudeDir, 'stats-cache.json');
    try {
      await fs.access(statsPath);
      return true;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Read stats from ~/.claude/stats-cache.json
      const statsPath = path.join(this.claudeDir, 'stats-cache.json');
      
      try {
        await fs.access(statsPath);
      } catch {
        logger.debug('Claude stats-cache.json not found');
        return null;
      }
      
      const content = await fs.readFile(statsPath, 'utf-8');
      const stats: ClaudeStatsCache = JSON.parse(content);
      
      return this.parseStatsCache(stats);
    } catch (error) {
      logger.error('Failed to fetch Claude usage:', error);
      return null;
    }
  }
  
  private parseStatsCache(stats: ClaudeStatsCache): ProviderUsage | null {
    const usage: ProviderUsage = {};
    
    // Get today's date
    const today = new Date();
    const todayStr = today.toISOString().split('T')[0];
    
    // Get week start (Sunday)
    const weekStart = new Date(today);
    weekStart.setDate(today.getDate() - today.getDay());
    const weekStartStr = weekStart.toISOString().split('T')[0];
    
    // Get month start
    const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
    const monthStartStr = monthStart.toISOString().split('T')[0];
    
    // Calculate daily usage
    const todayActivity = stats.dailyActivity.find(a => a.date === todayStr);
    const todayTokens = stats.dailyModelTokens.find(t => t.date === todayStr);
    
    if (todayActivity || todayTokens) {
      const messages = todayActivity?.messageCount ?? 0;
      const sessions = todayActivity?.sessionCount ?? 0;
      const tokens = todayTokens ? Object.values(todayTokens.tokensByModel).reduce((a, b) => a + b, 0) : 0;
      
      usage.session = {
        used: tokens,
        limit: 1000000, // No hard limit, using arbitrary high value
        percentage: Math.min(100, Math.round((tokens / 1000000) * 100)),
        displayString: `${messages} msgs · ${sessions} sessions · ${formatTokenCount(tokens)} tokens`,
      };
    }
    
    // Calculate weekly usage
    const weeklyActivity = stats.dailyActivity.filter(a => a.date >= weekStartStr);
    const weeklyTokensData = stats.dailyModelTokens.filter(t => t.date >= weekStartStr);
    
    if (weeklyActivity.length > 0 || weeklyTokensData.length > 0) {
      const messages = weeklyActivity.reduce((sum, a) => sum + a.messageCount, 0);
      const sessions = weeklyActivity.reduce((sum, a) => sum + a.sessionCount, 0);
      const tokens = weeklyTokensData.reduce((sum, t) => 
        sum + Object.values(t.tokensByModel).reduce((a, b) => a + b, 0), 0
      );
      
      usage.weekly = {
        used: tokens,
        limit: 10000000,
        percentage: Math.min(100, Math.round((tokens / 10000000) * 100)),
        displayString: `${messages} msgs · ${sessions} sessions · ${formatTokenCount(tokens)} tokens`,
      };
    }
    
    // Calculate monthly usage (all time from model usage)
    const totalInputTokens = Object.values(stats.modelUsage).reduce((sum, m) => sum + m.inputTokens, 0);
    const totalOutputTokens = Object.values(stats.modelUsage).reduce((sum, m) => sum + m.outputTokens, 0);
    const totalTokens = totalInputTokens + totalOutputTokens;
    
    if (stats.totalMessages > 0) {
      usage.monthly = {
        used: totalTokens,
        limit: 50000000,
        percentage: Math.min(100, Math.round((totalTokens / 50000000) * 100)),
        displayString: `${stats.totalMessages} msgs · ${stats.totalSessions} sessions · ${formatTokenCount(totalTokens)} tokens`,
      };
    }
    
    // Log model breakdown
    logger.info('Claude usage by model:');
    for (const [model, modelStats] of Object.entries(stats.modelUsage)) {
      const modelTokens = modelStats.inputTokens + modelStats.outputTokens;
      logger.info(`  ${model}: ${formatTokenCount(modelStats.inputTokens)} in, ${formatTokenCount(modelStats.outputTokens)} out`);
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
