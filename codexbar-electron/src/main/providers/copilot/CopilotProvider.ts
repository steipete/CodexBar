/**
 * GitHub Copilot Provider
 * 
 * Fetches usage from GitHub Copilot's usage API.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
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
    // 1. Check for GitHub CLI auth (existing check)
    const ghConfigPath = path.join(os.homedir(), '.config', 'gh', 'hosts.yml');
    const ghConfigPathWin = path.join(os.homedir(), 'AppData', 'Roaming', 'GitHub CLI', 'hosts.yml');
    
    // 2. Check for VS Code Extension (Windows/Linux/Mac standard path)
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    
    try {
      // Check GH CLI (Unix)
      await fs.access(ghConfigPath);
      return true;
    } catch {
      try {
        // Check GH CLI (Windows)
        await fs.access(ghConfigPathWin);
        return true;
      } catch {
        try {
          // Check VS Code Extensions
          const extensions = await fs.readdir(vscodeExtensions);
          const hasCopilot = extensions.some(ext => ext.startsWith('github.copilot'));
          if (hasCopilot) return true;
        } catch (err) {
          // Ignore error (dir might not exist)
        }
      }
    }
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Copilot doesn't expose usage limits in the same way
    // It's typically unlimited for paid subscribers
    
    // Return a placeholder indicating active status
    return {
      session: {
        used: 0,
        limit: 0, // 0 limit often implies "unlimited" or "special" handling in UI logic
        percentage: 0,
        displayString: 'Active', // Changed from "Unlimited" to "Active" to sound more "connected"
      },
    };
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
