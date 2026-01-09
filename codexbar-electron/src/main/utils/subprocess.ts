/**
 * Subprocess utilities for running CLI commands
 */

import { spawn, SpawnOptions } from 'child_process';
import { logger } from './logger';

export interface CommandResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export interface CommandOptions {
  timeout?: number; // milliseconds
  cwd?: string;
  env?: NodeJS.ProcessEnv;
}

/**
 * Run a command and capture output
 */
export async function runCommand(
  command: string,
  args: string[] = [],
  options: CommandOptions = {}
): Promise<CommandResult> {
  const { timeout = 30000, cwd, env } = options;
  
  return new Promise((resolve, reject) => {
    logger.debug(`Running command: ${command} ${args.join(' ')}`);
    
    const spawnOptions: SpawnOptions = {
      cwd,
      env: { ...process.env, ...env },
      shell: true, // Use shell on Windows for better compatibility
      windowsHide: true,
    };
    
    const child = spawn(command, args, spawnOptions);
    
    let stdout = '';
    let stderr = '';
    let killed = false;
    
    // Set up timeout
    const timer = setTimeout(() => {
      killed = true;
      child.kill('SIGTERM');
      reject(new Error(`Command timed out after ${timeout}ms`));
    }, timeout);
    
    child.stdout?.on('data', (data) => {
      stdout += data.toString();
    });
    
    child.stderr?.on('data', (data) => {
      stderr += data.toString();
    });
    
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    
    child.on('close', (code) => {
      clearTimeout(timer);
      if (!killed) {
        resolve({
          stdout: stdout.trim(),
          stderr: stderr.trim(),
          exitCode: code ?? 0,
        });
      }
    });
  });
}

/**
 * Check if a command exists in PATH
 */
export async function commandExists(command: string): Promise<boolean> {
  try {
    // Use 'where' on Windows, 'which' on Unix
    const checkCmd = process.platform === 'win32' ? 'where' : 'which';
    const result = await runCommand(checkCmd, [command], { timeout: 5000 });
    return result.exitCode === 0;
  } catch {
    return false;
  }
}
