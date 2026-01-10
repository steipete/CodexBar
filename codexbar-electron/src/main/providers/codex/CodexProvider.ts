/**
 * Codex (OpenAI) Provider
 * 
 * The Codex CLI doesn't store usage data locally or provide a status command.
 * This provider checks if the CLI is installed and configured.
 * Usage tracking would require API integration with OpenAI's usage dashboard.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class CodexProvider extends BaseProvider {
  readonly id = 'codex';
  readonly name = 'Codex';
  readonly icon = '🤖';
  readonly websiteUrl = 'https://platform.openai.com';
  readonly statusPageUrl = 'https://status.openai.com';
  
  private codexDir = path.join(os.homedir(), '.codex');
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if codex CLI is available
      const result = await runCommand('codex', ['--version']);
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // The Codex CLI doesn't have a status/usage command
    // and doesn't store usage data locally.
    // We can only confirm the CLI is installed and working.
    
    try {
      const result = await runCommand('codex', ['--version']);
      
      if (result.exitCode === 0) {
        // CLI is working, return a basic status
        // Extract version from output
        const version = result.stdout.trim() || 'installed';
        
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: `CLI ${version}`,
          },
        };
      }
    } catch (error) {
      logger.debug('Codex CLI check failed:', error);
    }
    
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
