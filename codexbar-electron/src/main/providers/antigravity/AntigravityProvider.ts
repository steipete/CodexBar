/**
 * Antigravity Provider
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { logger } from '../../utils/logger';

export class AntigravityProvider extends BaseProvider {
  readonly id = 'antigravity';
  readonly name = 'Antigravity';
  readonly icon = '🚀';
  readonly websiteUrl = 'https://antigravity.ai';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // TODO: Implement configuration check
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    logger.debug('Antigravity: Not yet implemented');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
