/**
 * Cursor Provider
 * 
 * Fetches usage from Cursor's API endpoint.
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
  
  private readonly API_URL = 'https://www.cursor.com/api/usage';
  
  async isConfigured(): Promise<boolean> {
    // Check if Cursor is installed and has auth
    const authToken = await this.getAuthToken();
    return authToken !== null;
  }
  
  private async getAuthToken(): Promise<string | null> {
    // Cursor stores auth in different locations per platform
    const possiblePaths = [
      path.join(os.homedir(), '.cursor', 'auth.json'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'Cursor', 'auth.json'),
      path.join(os.homedir(), '.config', 'Cursor', 'auth.json'),
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
    try {
      const token = await this.getAuthToken();
      if (!token) {
        logger.warn('Cursor: No auth token found');
        return null;
      }
      
      const response = await fetch(this.API_URL, {
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
      });
      
      if (!response.ok) {
        logger.warn(`Cursor API returned ${response.status}`);
        return null;
      }
      
      const data = await response.json() as CursorUsageResponse;
      return this.parseUsageResponse(data);
    } catch (error) {
      logger.error('Failed to fetch Cursor usage:', error);
      return null;
    }
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
