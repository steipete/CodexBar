/**
 * Cursor Provider
 * 
 * Cursor is an AI-powered code editor. This provider checks for Cursor installation
 * and attempts to read usage data if available.
 * 
 * Note: Cursor doesn't have a CLI and stores auth in various locations depending
 * on the platform. The API requires authentication that's tied to the desktop app.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

interface CursorUsageResponse {
  'gpt-4': { numRequests: number; maxRequestUsage: number | null };
  'gpt-3.5-turbo': { numRequests: number; maxRequestUsage: number | null };
  'gpt-4o'?: { numRequests: number; maxRequestUsage: number | null };
  startOfMonth?: string;
}

export class CursorProvider extends BaseProvider {
  readonly id = 'cursor';
  readonly name = 'Cursor';
  readonly icon = '📝';
  readonly websiteUrl = 'https://cursor.sh';
  readonly statusPageUrl = 'https://status.cursor.sh';
  
  async isConfigured(): Promise<boolean> {
    // Check if Cursor is installed by looking for its data directories
    const cursorPaths = [
      // Windows
      path.join(os.homedir(), 'AppData', 'Roaming', 'Cursor'),
      path.join(os.homedir(), 'AppData', 'Local', 'Programs', 'cursor'),
      // macOS
      path.join(os.homedir(), 'Library', 'Application Support', 'Cursor'),
      // Linux
      path.join(os.homedir(), '.config', 'Cursor'),
      path.join(os.homedir(), '.cursor'),
    ];
    
    for (const cursorPath of cursorPaths) {
      try {
        await fs.access(cursorPath);
        return true;
      } catch {
        // Try next path
      }
    }
    
    return false;
  }
  
  private async getAuthToken(): Promise<string | null> {
    // Cursor stores auth in different locations per platform
    const possiblePaths = [
      path.join(os.homedir(), '.cursor', 'auth.json'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'Cursor', 'auth.json'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'Cursor', 'User', 'globalStorage', 'auth.json'),
      path.join(os.homedir(), '.config', 'Cursor', 'auth.json'),
      path.join(os.homedir(), 'Library', 'Application Support', 'Cursor', 'auth.json'),
    ];
    
    for (const authPath of possiblePaths) {
      try {
        const content = await fs.readFile(authPath, 'utf-8');
        const auth = JSON.parse(content);
        if (auth.accessToken) {
          return auth.accessToken;
        }
      } catch {
        // Try next path
      }
    }
    
    return null;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Check if Cursor is installed
    const isInstalled = await this.isConfigured();
    
    if (!isInstalled) {
      return null;
    }
    
    // Try to get auth token and fetch from API
    const token = await this.getAuthToken();
    
    if (token) {
      try {
        const response = await fetch('https://www.cursor.com/api/usage', {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
        });
        
        if (response.ok) {
          const data = await response.json() as CursorUsageResponse;
          return this.parseUsageResponse(data);
        }
      } catch (error) {
        logger.debug('Cursor API request failed:', error);
      }
    }
    
    // If no API access, return basic installed status
    return {
      session: {
        used: 0,
        limit: 0,
        percentage: 0,
        displayString: 'Installed',
      },
    };
  }
  
  private parseUsageResponse(data: CursorUsageResponse): ProviderUsage {
    // Combine usage across models
    let totalUsed = 0;
    let totalLimit = 0;
    
    // GPT-4 usage
    if (data['gpt-4']) {
      totalUsed += data['gpt-4'].numRequests;
      if (data['gpt-4'].maxRequestUsage) {
        totalLimit += data['gpt-4'].maxRequestUsage;
      }
    }
    
    // GPT-4o usage
    if (data['gpt-4o']) {
      totalUsed += data['gpt-4o'].numRequests;
      if (data['gpt-4o'].maxRequestUsage) {
        totalLimit += data['gpt-4o'].maxRequestUsage;
      }
    }
    
    // Default limit if not specified (Pro plan typically has 500/month)
    if (totalLimit === 0) {
      totalLimit = 500;
    }
    
    // Calculate reset time (start of next month)
    let resetTime: string | undefined;
    if (data.startOfMonth) {
      const start = new Date(data.startOfMonth);
      const nextMonth = new Date(start);
      nextMonth.setMonth(nextMonth.getMonth() + 1);
      resetTime = nextMonth.toISOString();
    }
    
    return {
      monthly: {
        used: totalUsed,
        limit: totalLimit,
        percentage: calculatePercentage(totalUsed, totalLimit),
        displayString: formatUsage(totalUsed, totalLimit, 'requests'),
        resetTime,
      },
    };
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
