/**
 * Vertex AI (Google Cloud) Provider
 * 
 * Vertex AI is Google Cloud's AI platform. This provider checks for
 * Google Cloud credentials and gcloud CLI configuration.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class VertexAIProvider extends BaseProvider {
  readonly id = 'vertexai';
  readonly name = 'Vertex AI';
  readonly icon = '☁️';
  readonly websiteUrl = 'https://cloud.google.com/vertex-ai';
  readonly statusPageUrl = 'https://status.cloud.google.com';
  
  async isConfigured(): Promise<boolean> {
    // Check for Google Cloud credentials
    const credPaths = [
      path.join(os.homedir(), '.config', 'gcloud', 'application_default_credentials.json'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'gcloud', 'application_default_credentials.json'),
    ];
    
    for (const credPath of credPaths) {
      try {
        await fs.access(credPath);
        return true;
      } catch {
        // Try next
      }
    }
    
    // Check GOOGLE_APPLICATION_CREDENTIALS env var
    if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
      try {
        await fs.access(process.env.GOOGLE_APPLICATION_CREDENTIALS);
        return true;
      } catch {
        // File doesn't exist
      }
    }
    
    // Check for gcloud CLI
    try {
      const result = await runCommand('gcloud', ['--version']);
      if (result.exitCode === 0) {
        // Check if authenticated
        const authResult = await runCommand('gcloud', ['auth', 'list', '--format=json']);
        if (authResult.exitCode === 0) {
          try {
            const accounts = JSON.parse(authResult.stdout);
            if (Array.isArray(accounts) && accounts.length > 0) {
              return true;
            }
          } catch {
            // Parse failed
          }
        }
      }
    } catch {
      // gcloud not found
    }
    
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Try to get current project and account from gcloud
    try {
      const projectResult = await runCommand('gcloud', ['config', 'get-value', 'project']);
      const accountResult = await runCommand('gcloud', ['config', 'get-value', 'account']);
      
      if (projectResult.exitCode === 0 || accountResult.exitCode === 0) {
        const project = projectResult.stdout.trim() || 'unknown';
        const account = accountResult.stdout.trim() || '';
        
        let displayString = `Project: ${project}`;
        if (account) {
          // Truncate email for display
          const shortAccount = account.split('@')[0];
          displayString = `${shortAccount} · ${project}`;
        }
        
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString,
          },
        };
      }
    } catch (error) {
      logger.debug('Vertex AI: gcloud command failed:', error);
    }
    
    // If we have credentials but no gcloud CLI
    return {
      session: {
        used: 0,
        limit: 0,
        percentage: 0,
        displayString: 'Configured',
      },
    };
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
