/**
 * GitHub Copilot Provider
 * 
 * GitHub Copilot is typically accessed through VS Code or other IDE extensions.
 * This provider checks for the presence of the Copilot extension and GitHub CLI auth.
 * Copilot doesn't expose usage limits - it's unlimited for paid subscribers.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class CopilotProvider extends BaseProvider {
  readonly id = 'copilot';
  readonly name = 'GitHub Copilot';
  readonly icon = '🐙';
  readonly websiteUrl = 'https://github.com/features/copilot';
  readonly statusPageUrl = 'https://www.githubstatus.com';
  
  async isConfigured(): Promise<boolean> {
    // Check multiple possible configurations
    
    // 1. Check GitHub CLI auth
    const ghConfigPaths = [
      path.join(os.homedir(), '.config', 'gh', 'hosts.yml'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'GitHub CLI', 'hosts.yml'),
    ];
    
    for (const configPath of ghConfigPaths) {
      try {
        await fs.access(configPath);
        return true;
      } catch {
        // Try next path
      }
    }
    
    // 2. Check for VS Code Copilot extension
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    try {
      const extensions = await fs.readdir(vscodeExtensions);
      const hasCopilot = extensions.some(ext => 
        ext.startsWith('github.copilot') || ext.includes('copilot')
      );
      if (hasCopilot) return true;
    } catch {
      // VS Code extensions dir not found
    }
    
    // 3. Check for GitHub CLI with copilot extension
    try {
      const result = await runCommand('gh', ['extension', 'list']);
      if (result.exitCode === 0 && result.stdout.toLowerCase().includes('copilot')) {
        return true;
      }
    } catch {
      // gh CLI not available
    }
    
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // GitHub Copilot doesn't have usage limits for paid subscribers
    // We can check the subscription status via gh CLI if available
    
    let subscriptionInfo = 'Active';
    
    try {
      // Try to get GitHub user info to confirm auth
      const result = await runCommand('gh', ['auth', 'status'], { timeout: 10000 });
      
      if (result.exitCode === 0) {
        // Extract account info from output
        const accountMatch = result.stdout.match(/Logged in to [^\s]+ account (\w+)/i) ||
                            result.stderr.match(/Logged in to [^\s]+ account (\w+)/i);
        if (accountMatch) {
          subscriptionInfo = `@${accountMatch[1]}`;
        }
      }
    } catch (error) {
      logger.debug('Could not get GitHub auth status:', error);
    }
    
    // Check for Copilot extension version
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    try {
      const extensions = await fs.readdir(vscodeExtensions);
      const copilotExt = extensions.find(ext => ext.startsWith('github.copilot-'));
      if (copilotExt) {
        const versionMatch = copilotExt.match(/github\.copilot-(\d+\.\d+\.\d+)/);
        if (versionMatch) {
          subscriptionInfo += ` · v${versionMatch[1]}`;
        }
      }
    } catch {
      // Ignore
    }
    
    return {
      session: {
        used: 0,
        limit: 0, // 0 limit indicates unlimited
        percentage: 0,
        displayString: subscriptionInfo,
      },
    };
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
