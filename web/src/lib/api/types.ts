/**
 * Domain aliases derived from the generated OpenAPI schema.
 *
 * Gate B: every type here traces back to `docs/openapi.yaml`. Nothing in this
 * file is hand-written as a shape - it is a named alias onto a generated
 * contract, so a spec change surfaces as a compile error rather than a
 * silently-drifting interface.
 */
import type { components } from './schema';

export type MovieSummaryItem = components['schemas']['MovieSummaryItem'];
export type MovieSummary = MovieSummaryItem;
export type MovieListResponse = components['schemas']['MovieListResponse'];
export type MovieDetailsResponse = components['schemas']['MovieDetailsResponse'];
export type MediaInfoResponse = components['schemas']['MediaInfoResponse'];
export type QualityOption = components['schemas']['QualityOption'];
export type TranscodeStatusResponse = components['schemas']['TranscodeStatusResponse'];
export type MediaReadinessResponse = components['schemas']['MediaReadinessResponse'];
export type TechnicalSpecs = components['schemas']['TechnicalSpecs'];

export type TranscodeStatus = TranscodeStatusResponse['status'];
export type ReadinessStatus = MediaReadinessResponse['status'];