#!/usr/bin/env python3
"""Reject release profiles that cannot authorize CodexBar's CloudKit push entitlements."""

import datetime
import plistlib
import subprocess
import sys


def validate(profile_path, app_identifier):
    decoded = subprocess.run(
        ['security', 'cms', '-D', '-i', profile_path], capture_output=True, check=True,
    ).stdout
    profile = plistlib.loads(decoded)
    entitlements = profile['Entitlements']
    team, bundle = app_identifier.split('.', 1)
    required = {
        'com.apple.application-identifier': app_identifier,
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.aps-environment': 'production',
        'com.apple.developer.icloud-container-environment': 'Production',
    }
    for key, value in required.items():
        if entitlements.get(key) != value:
            raise ValueError(f'{key} must authorize {value}')
    services = entitlements.get('com.apple.developer.icloud-services')
    if services != '*' and not (isinstance(services, list) and 'CloudKit' in services):
        raise ValueError('profile must authorize CloudKit')
    containers = entitlements.get('com.apple.developer.icloud-container-identifiers')
    if not isinstance(containers, list) or f'iCloud.{bundle}' not in containers:
        raise ValueError('profile must authorize the app iCloud container')
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('profile is expired or has no expiration date')


if __name__ == '__main__':
    profile_path, app_identifier = sys.argv[1:]
    try:
        validate(profile_path, app_identifier)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError, AttributeError):
        print(
            f'ERROR: {profile_path} does not authorize this CloudKit release. Enable Push Notifications '
            f'for {app_identifier}, regenerate its Developer ID provisioning profile with '
            'com.apple.developer.aps-environment = production, and replace that file '
            '(the profile must be unexpired and match the app, team, and iCloud container).',
            file=sys.stderr,
        )
        sys.exit(1)
