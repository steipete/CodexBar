/**
 * Logger utility using winston
 */

import winston from 'winston';
import path from 'path';
import { app } from 'electron';

// Get user data path for log files
const getLogPath = (): string => {
  try {
    return path.join(app.getPath('userData'), 'logs');
  } catch {
    // App not ready yet, use temp directory
    return path.join(process.env.TEMP ?? '/tmp', 'codexbar', 'logs');
  }
};

export const logger = winston.createLogger({
  level: process.env.NODE_ENV === 'development' ? 'debug' : 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.printf(({ timestamp, level, message, stack }) => {
      const msg = stack ?? message;
      return `${timestamp} [${level.toUpperCase()}] ${msg}`;
    })
  ),
  transports: [
    // Console output
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.printf(({ timestamp, level, message }) => {
          return `${timestamp} [${level}] ${message}`;
        })
      ),
    }),
    // File output (only when app is ready)
    ...(process.type === 'browser' ? [
      new winston.transports.File({
        filename: path.join(getLogPath(), 'error.log'),
        level: 'error',
        maxsize: 5 * 1024 * 1024, // 5MB
        maxFiles: 3,
      }),
      new winston.transports.File({
        filename: path.join(getLogPath(), 'combined.log'),
        maxsize: 10 * 1024 * 1024, // 10MB
        maxFiles: 5,
      }),
    ] : []),
  ],
});
