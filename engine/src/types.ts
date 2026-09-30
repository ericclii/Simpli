/**
 * NoScroll rule bundle types.
 *
 * A bundle is DATA, not code: it ships in the app, is ed25519-verified natively,
 * and the engine interprets it.
 */

export type SurfaceKind =
  | 'dom-remove'
  | 'route-block'
  | 'route-allow-only'
  | 'route-rewrite'
  | 'style';

/** How aggressively a matched node is suppressed. */
export type Suppression = 'remove' | 'hide';

export interface SurfaceBase {
  kind: SurfaceKind;
  /** Enabled state until the user changes it. */
  defaultEnabled?: boolean;
  /** Human label shown in native settings UI. */
  label?: string;
  /** Provenance for vendored rules (licence compliance). */
  source?: string;
}

export interface DomRemoveSurface extends SurfaceBase {
  kind: 'dom-remove';
  selectors: string[];
  suppression?: Suppression;
  /**
   * Re-justify the parent flex container after removing a child. Removing one
   * nav icon otherwise misaligns the rest and leaves a dead tap zone.
   */
  afterRemove?: 'rejustify' | 'none';
  /** Only apply on routes matching these patterns. */
  onlyOnRoutes?: string[];
}

export interface RouteBlockSurface extends SurfaceBase {
  kind: 'route-block';
  patterns: string[];
  redirect: string;
}

/**
 * "Only these routes are allowed" — everything else redirects.
 *
 * Exists because the alternative (a route-block with a negative lookahead over
 * every auth path) got the auth list wrong twice: once on Instagram, once on
 * TikTok. Enumerating what to EXCLUDE is a bug generator; enumerating what to
 * ALLOW is not, and the engine exempts auth surfaces structurally.
 */
export interface RouteAllowOnlySurface extends SurfaceBase {
  kind: 'route-allow-only';
  /** Routes that remain reachable. Auth surfaces are always allowed on top. */
  allow: string[];
  redirect: string;
}

export interface RouteRewriteSurface extends SurfaceBase {
  kind: 'route-rewrite';
  /** Regex with capture groups, applied to pathname + search. */
  pattern: string;
  /** Replacement using $1-style references. */
  replacement: string;
}

export interface StyleSurface extends SurfaceBase {
  kind: 'style';
  css: string;
}

export type Surface =
  | DomRemoveSurface
  | RouteBlockSurface
  | RouteAllowOnlySurface
  | RouteRewriteSurface
  | StyleSurface;

export interface Service {
  /** Host match patterns, e.g. "*://*.instagram.com/*". */
  match: string[];
  /**
   * Additional auth routes for this service. MERGED with the engine's hard-coded
   * list — a bundle can widen the allow-list but can never narrow it.
   */
  authAllowList?: string[];
  surfaces: Record<string, Surface>;
}

export interface RuleBundle {
  version: number;
  /** Engine versions below this refuse the bundle. */
  minEngine: number;
  /** ed25519 signature over the canonical body. Verified natively, before injection. */
  signature?: string;
  services: Record<string, Service>;
}

/** Per-surface user settings, keyed "service.surface". */
export type Settings = Record<string, boolean>;

export interface EngineConfig {
  bundle: RuleBundle;
  settings: Settings;
}
