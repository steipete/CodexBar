/**
 * Augment Provider
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { logger } from '../../utils/logger';

export class AugmentProvider extends BaseProvider {
  readonly id = 'augment';
  readonly name = 'Augment';
  readonly icon = '🔮';
  readonly websiteUrl = 'https://augment.dev';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // TODO: Implement configuration check
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    logger.debug('Augment: Not yet implemented');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
