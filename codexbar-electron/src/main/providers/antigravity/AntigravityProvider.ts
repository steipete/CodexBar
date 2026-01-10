/**
 * Antigravity Provider
 * 
 * Antigravity stores conversation data in ~/.gemini/antigravity/conversations/
 * as .pb (protobuf) files. Since protobuf parsing is complex, we'll check
 * for the presence of conversations and provide basic stats.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class AntigravityProvider extends BaseProvider {
  readonly id = 'antigravity';
  readonly name = 'Antigravity';
  readonly icon = '🚀';
  readonly websiteUrl = 'https://antigravity.dev';
  readonly statusPageUrl = undefined;
  
  private antigravityDir = path.join(os.homedir(), '.gemini', 'antigravity');
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if antigravity CLI is available
      const result = await runCommand('antigravity', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for antigravity directory
    try {
      await fs.access(this.antigravityDir);
      return true;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      const conversationsDir = path.join(this.antigravityDir, 'conversations');
      
      try {
        await fs.access(conversationsDir);
      } catch {
        logger.debug('Antigravity conversations directory not found');
        return null;
      }
      
      // Count conversation files
      const files = await fs.readdir(conversationsDir);
      const pbFiles = files.filter(f => f.endsWith('.pb'));
      
      if (pbFiles.length === 0) {
        return null;
      }
      
      // Get file stats to calculate total size (proxy for usage)
      let totalSize = 0;
      let latestModified = new Date(0);
      
      for (const file of pbFiles) {
        try {
          const stat = await fs.stat(path.join(conversationsDir, file));
          totalSize += stat.size;
          if (stat.mtime > latestModified) {
            latestModified = stat.mtime;
          }
        } catch {
          // Skip files we can't stat
        }
      }
      
      // Format size
      const sizeStr = formatSize(totalSize);
      const lastUsed = formatRelativeTime(latestModified);
      
      return {
        session: {
          used: pbFiles.length,
          limit: 0, // No limit
          percentage: 0,
          displayString: `${pbFiles.length} conversations · ${sizeStr}`,
        },
        monthly: {
          used: pbFiles.length,
          limit: 0,
          percentage: 0,
          displayString: `Last active: ${lastUsed}`,
        },
      };
    } catch (error) {
      logger.error('Failed to fetch Antigravity usage:', error);
      return null;
    }
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}

/**
 * Format bytes to human readable size
 */
function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${bytes} B`;
}

/**
 * Format date to relative time string
 */
function formatRelativeTime(date: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMins / 60);
  const diffDays = Math.floor(diffHours / 24);
  
  if (diffMins < 1) return 'just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;
  
  return date.toLocaleDateString();
}
