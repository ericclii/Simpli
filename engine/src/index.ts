/**
 * NoScroll engine entry point.
 *
 * Bundled to a single IIFE and injected at documentStart by the iOS shell,
 * which sets window.__NOSCROLL_CONFIG just before it.
 */

import { start } from './engine.js';
import type { EngineConfig } from './types.js';

declare global {
  interface Window {
    __NOSCROLL_CONFIG?: EngineConfig;
  }
}

const injected = window.__NOSCROLL_CONFIG;
if (injected) start(injected);
