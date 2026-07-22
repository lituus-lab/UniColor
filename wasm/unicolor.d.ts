// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
//
// TypeScript declarations for the UniColor WASM binding (`wasm/unicolor.js`).
// `load()` instantiates the Emscripten module, runs `uc_init`, and resolves to
// the API object. Ordinals mirror `include/UniColor.h`.

// SpaceTag ordinals (frozen).
export interface TagOrdinals {
  readonly UNKNOWN: 0;
  readonly SRGB: 1;
  readonly SRGB_LIN: 2;
  readonly P3: 3;
  readonly P3_LIN: 4;
  readonly REC2020: 5;
  readonly REC2020_LIN: 6;
  readonly A98: 7;
  readonly A98_LIN: 8;
  readonly PROPHOTO: 9;
  readonly PROPHOTO_LIN: 10;
  readonly XYZ: 11;
  readonly XYY: 12;
  readonly LAB: 13;
  readonly LCH: 14;
  readonly OKLAB: 15;
  readonly OKLCH: 16;
  readonly HSV: 17;
  readonly HSL: 18;
  readonly HWB: 19;
  readonly CMYK: 20;
  readonly YCBCR: 21;
  readonly ICTCP: 22;
  readonly JZAZBZ: 23;
  readonly CAM16: 24;
  readonly CAM16_UCS: 25;
  readonly HCT: 26;
}

export interface PalTagOrdinals {
  readonly ORDERED: 0;
  readonly UNORDERED: 1;
  readonly SCIENTIFIC: 2;
  readonly TERMINAL: 3;
  readonly CATEGORICAL: 4;
  readonly CONTINUOUS: 5;
  readonly SEMANTIC: 6;
}

export interface PalIntentOrdinals {
  readonly QUALITATIVE: 0;
  readonly SEQUENTIAL: 1;
  readonly DIVERGING: 2;
  readonly UI: 3;
  readonly SCIENTIFIC: 4;
  readonly CATEGORICAL: 5;
  readonly TERMINAL: 6;
}

export interface SeverityOrdinals {
  readonly INFO: 0;
  readonly WARNING: 1;
  readonly ERROR: 2;
  readonly FATAL: 3;
}

// A SpaceTag ordinal (UC_TAG_*).
export type SpaceTag = TagOrdinals[keyof TagOrdinals];
export type PaletteTag = PalTagOrdinals[keyof PalTagOrdinals];
export type PaletteIntent = PalIntentOrdinals[keyof PalIntentOrdinals];
export type Severity = SeverityOrdinals[keyof SeverityOrdinals];

// A perceptual color: a SpaceTag, the three chromatic components, and a
// straight-alpha in [0,1]. A plain JS value — no native memory to free.
export class Color {
  readonly tag: SpaceTag;
  readonly comps: [number, number, number];
  readonly alpha: number;
  /** Alias for `comps`. */
  get components(): [number, number, number];

  static parse(s: string): Color;
  static srgb(r: number, g: number, b: number): Color;
  static oklch(l: number, c: number, h: number): Color;
  static make(tag: SpaceTag, c0: number, c1: number, c2: number, alpha?: number): Color;

  convert(target: SpaceTag): Color;
  gamutMap(target: SpaceTag): Color;
  /** `legacy` true emits `#rrggbb[aa]`; false (default) emits `oklch(L C h[/a])`. */
  formatCss(legacy?: boolean): string;
  /** WCAG 2.2 contrast, or a named metric ("wcag22" | "apca" | "bridgepca"). */
  contrast(bg: Color, metric?: string | null): number;
  /** Perceptual distance under a named metric (deltaE76/94/2000/cmc/ok/...). */
  distance(other: Color, metric: string): number;
  toString(): string;
}

// A theme-tree node: primitives carry a `color`; semantics and components carry
// an `alias`. Accept the tuple form (mirrors the Python binding) or a record.
export type Token =
  | [string, Color | null, string | null]
  | { name: string; color: Color | null; alias: string | null };

// A 3-layer token tree (primitives / semantics / components). Wraps a wasm
// pointer — call `free()` when done.
export class Theme {
  free(): void;

  static make(prims: Token[], sems?: Token[], comps?: Token[]): Theme;

  /** Resolves a role to a color; throws on an undefined role / dangling alias / cycle. */
  resolve(role: string): Color;
  hasRole(role: string): boolean;
  get count(): number;
  /** Render to a registered format ("css", "json", "tailwind", ...). */
  export(name: string, legacy?: boolean): string;
}

// An immutable color set. Wraps a wasm pointer — call `free()` when done.
export class Palette {
  free(): void;

  static make(tag: PaletteTag, colors: Color[], intent: PaletteIntent, seed?: number): Palette;

  /** Discrete index for the five discrete structures; RangeError out of range. */
  colorAt(i: number): Color;
  /** Ordered-ramp sample at t in [0,1]; RangeError out of range / non-ramp. */
  sample(t: number): Color;
  /** Role access for a Semantic palette; throws on unknown role / non-semantic. */
  role(name: string): Color;
  get length(): number;
  get tag(): PaletteTag;
  get intent(): PaletteIntent;
}

// Import diagnostics. The target theme/palette is not held here — use
// `importTheme` / `importPalette`. Wraps a wasm pointer — call `free()`.
export class ImportReport {
  free(): void;

  static importReported(input: string, fmt: string, strict?: boolean): ImportReport;

  get formatName(): string;
  get schemaVersion(): string;
  get warningCount(): number;
  /** The message of warning `i`; RangeError out of range. */
  warning(i: number): string;
}

// One rule result from a validation report.
export interface Rule {
  readonly name: string;
  readonly severity: Severity;
  readonly metric: number;
  readonly threshold: number;
  readonly message: string;
}

// The result of running every registered rule over a theme or palette. Wraps a
// wasm pointer — call `free()` when done.
export class ValidationReport {
  free(): void;

  static validateTheme(t: Theme): ValidationReport;
  static validatePalette(p: Palette): ValidationReport;

  get score(): number;
  get worst(): Severity;
  get ruleCount(): number;
  /** Rule `i`; RangeError out of range. */
  rule(i: number): Rule;
}

export interface UniColorAPI {
  version(): string;
  abiMajor(): number;
  abiMinor(): number;
  abiPatch(): number;

  parse(s: string): Color;
  srgb(r: number, g: number, b: number): Color;
  oklch(l: number, c: number, h: number): Color;
  make(tag: SpaceTag, c0: number, c1: number, c2: number, alpha?: number): Color;
  contrast(fg: Color, bg: Color, metric?: string | null): number;
  distance(a: Color, b: Color, metric: string): number;

  theme(prims: Token[], sems?: Token[], comps?: Token[]): Theme;
  palette(tag: PaletteTag, colors: Color[], intent: PaletteIntent, seed?: number): Palette;

  importTheme(input: string, fmt: string, strict?: boolean): Theme;
  importPalette(input: string, fmt: string, strict?: boolean): Palette;
  importReported(input: string, fmt: string, strict?: boolean): ImportReport;

  validateTheme(t: Theme): ValidationReport;
  validatePalette(p: Palette): ValidationReport;

  readonly Color: typeof Color;
  readonly Theme: typeof Theme;
  readonly Palette: typeof Palette;
  readonly ImportReport: typeof ImportReport;
  readonly ValidationReport: typeof ValidationReport;

  readonly TAG: TagOrdinals;
  readonly PAL_TAG: PalTagOrdinals;
  readonly PAL_INTENT: PalIntentOrdinals;
  readonly SEVERITY: SeverityOrdinals;
}

// Load and initialize the wasm module. Resolves to the API object.
export function load(): Promise<UniColorAPI>;