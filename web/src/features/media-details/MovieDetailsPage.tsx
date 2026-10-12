import { useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import { getMovieDetails } from '../../lib/api/client';
import { posterUrl, backdropUrl } from '../../lib/api/poster';
import { useDeviceId } from '../../lib/useDeviceId';
import { StateMessage } from '../../components/StateMessage';
import { useAsync } from '../../lib/useAsync';
import { PosterImage } from '../../components/PosterImage';
import { Icon, type IconName } from '../../components/icons';
import { CastRail, type CastMember } from './CastRail';

/**
 * `details_json` arrives as a raw JSON *string*, not an object, and the spec
 * types it as an empty record. Parse defensively and treat a malformed value as
 * absent rather than letting it take down the screen.
 */
interface ExtendedDetails {
  tagline?: string;
  certification?: string;
  directors?: string[];
  writers?: string[];
  production?: string[];
  imdb_id?: string;
  trailer_key?: string;
  cast?: CastMember[];
}

/**
 * TMDb extended metadata (tagline, cast, crew, certification).
 *
 * **The shape differs by endpoint, which is the trap.** `GET /api/movie/<file>`
 * parses `details_json` server-side and sends `extended` as a real object
 * (`app/routes/api.py:940`), while the raw `movie.details_json` is the JSON
 * *string*. This originally only accepted the string, so on the details page
 * every extended field silently degraded to absent — no tagline, no cast, no
 * directors — with no error anywhere. Accept both, and reject anything that is
 * neither, so a malformed value still degrades instead of throwing.
 */
function parseDetails(raw: unknown): ExtendedDetails {
  if (typeof raw === 'string') {
    if (raw.length === 0) return {};
    try {
      const parsed: unknown = JSON.parse(raw);
      return parsed && typeof parsed === 'object' ? (parsed as ExtendedDetails) : {};
    } catch {
      return {};
    }
  }
  if (raw && typeof raw === 'object') {
    return raw as ExtendedDetails;
  }
  return {};
}

/** `1968-04-02` -> `Apr 2, 1968`. Returns null for anything unparseable. */
function formatReleaseDate(value: string | null | undefined): string | null {
  if (!value) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
}

function watchRoute(filename: string, replay = false): string {
  const base = `/watch/${filename.split('/').map(encodeURIComponent).join('/')}`;
  return replay ? `${base}?replay=1` : base;
}

export function MovieDetailsPage() {
  // Splat route: the filename is a relative path and contains slashes.
  const params = useParams();
  const filename = params['*'] ?? '';
  const deviceId = useDeviceId();

  const { data, error, loading } = useAsync(
    (signal) => getMovieDetails(decodeURIComponent(filename), { signal, deviceId }),
    [filename, deviceId],
  );

  const extended = useMemo(() => (data ? parseDetails(data.extended) : {}), [data]);
  const trailerRef = useRef<HTMLDialogElement>(null);
  // The iframe is mounted only while the dialog is open, so the YouTube player
  // is never fetched on a page the viewer may never want the trailer on.
  const [trailerOpen, setTrailerOpen] = useState(false);
  // Overview overflow toggle; see the synopsis paragraph for why it is bounded.
  const [expanded, setExpanded] = useState(false);

  const openTrailer = () => {
    setTrailerOpen(true);
    const dialog = trailerRef.current;
    if (!dialog) return;
    /*
     * `showModal()` is the Baseline path: it gives top-layer stacking, focus
     * trapping and Escape-to-close. Guard it anyway, because a missing method
     * would otherwise throw *inside a click handler* and leave the page with a
     * state flag set but no dialog. The attribute fallback still opens the
     * dialog, just without the top-layer niceties.
     */
    if (typeof dialog.showModal === 'function') {
      dialog.showModal();
    } else {
      dialog.setAttribute('open', '');
    }
  };

  if (!data) {
    return (
      <StateMessage loading={loading} error={error} empty={false} emptyText="">
        {null}
      </StateMessage>
    );
  }

  const { movie, specs } = data;
  /*
   * Use the server's `backdrop_tmdb_id`, NOT `movie.tmdb_id`.
   *
   * The server gates that value on the title actually *having* backdrop
   * artwork (`backdrop_path` or a cached file) and sends `null` when it does
   * not. Deriving the URL from `movie.tmdb_id` instead - which this page
   * originally did - requests a backdrop that does not exist, producing a 404
   * for every title in the library without one. Same lesson as the profile
   * lookup: trust the value the server computed as safe.
   */
  const backdrop = backdropUrl(data.backdrop_tmdb_id);
  const playHref = watchRoute(movie.filename);
  const replayHref = watchRoute(movie.filename, true);
  const genres = (movie.genres ?? '')
    .split(',')
    .map((g) => g.trim())
    .filter(Boolean);
  const releaseDate = formatReleaseDate(movie.release_date);

  return (
    <article data-testid="movie-details" className="pb-16">
      {/*
        The hero breaks out of <main>'s padding with negative margins so the
        backdrop runs edge-to-edge and *under* the sticky glass header, the way
        a streaming service presents a title. The inner column restores the
        padding and is width-capped to the same measure as the body below, so
        the title, the poster and every section heading share one left edge.
        Top padding clears the ~61px sticky header with room to spare, so
        nothing in the poster column can ever sit under it.
      */}
      <section className="relative -mx-4 -mt-8 sm:-mx-6">
        <div className="absolute inset-0 overflow-hidden">
          {backdrop ? (
            <img
              src={backdrop}
              alt=""
              role="presentation"
              // The backdrop is the largest above-the-fold image on this
              // screen, so it is the LCP candidate here.
              fetchPriority="high"
              decoding="async"
              className="h-full w-full scale-105 object-cover object-[center_28%]"
            />
          ) : (
            <div className="h-full w-full brand-gradient opacity-30" aria-hidden="true" />
          )}
          {/* Stacked scrims, each earning its place: a light flat base so the
              artwork keeps its presence, a vertical wash that melts the image
              into the page while keeping the sticky header readable, and a
              horizontal wash that seats the text column and then releases, so
              the right-hand side of the artwork stays visible. */}
          <div className="absolute inset-0 bg-obsidian-950/20" />
          <div className="absolute inset-0 bg-gradient-to-b from-obsidian-950/90 via-obsidian-950/30 to-obsidian-950" />
          <div className="absolute inset-0 bg-gradient-to-r from-obsidian-950 via-obsidian-950/72 to-transparent" />
        </div>

        {/*
          Three columns on a wide screen: poster, then the identity block
          (title / meta / genres / actions), then a "soft details" panel that
          carries the prose. The third column exists because the backdrop's
          right-hand side is otherwise a large empty field, and a streaming
          hero should spend it on something rather than on artwork alone.
        */}
        {/*
          Vertical rhythm. `pt-20 sm:pt-24` still clears the ~61px sticky
          header with real margin, and the bottom padding is deliberately
          tighter than the top: the hero has to clear a fixed bar above it but
          only needs to hand off to the page below. Compressing further would
          start to crowd the poster, which is why this stops where it does.
        */}
        <div className="relative mx-auto max-w-[1200px] px-4 pb-7 pt-20 sm:px-6 sm:pb-9 sm:pt-24">
          <div className="flex flex-col gap-6 lg:flex-row lg:items-start lg:gap-8">
            <div className="w-36 shrink-0 sm:w-48">
              <div className="overflow-hidden rounded-2xl border border-white/10 shadow-2xl shadow-black/70">
                <div className="aspect-2/3">
                  <PosterImage
                    src={posterUrl(movie.poster)}
                    alt={`Poster for ${movie.title}`}
                    priority="lazy"
                  />
                </div>
              </div>
              <WatchProgressBar percent={movie.percent} />
            </div>

            <div className="min-w-0 flex-1">
              <h1 className="text-balance text-3xl font-bold tracking-tight text-white sm:text-4xl lg:text-5xl">
                {movie.title}
              </h1>

              {extended.tagline ? (
                <p className="mt-2 max-w-2xl text-sm italic text-white/55 sm:text-base">
                  {extended.tagline}
                </p>
              ) : null}

              <MetaRow
                year={movie.year}
                runtime={data.formatted_runtime ?? (movie.runtime ? `${movie.runtime} min` : null)}
                certification={extended.certification}
                rating={movie.rating}
              />

              {genres.length > 0 ? (
                <ul className="mt-3.5 flex flex-wrap gap-2" aria-label="Genres">
                  {genres.map((genre) => (
                    <li
                      key={genre}
                      className="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-xs font-medium text-white/70"
                    >
                      {genre}
                    </li>
                  ))}
                </ul>
              ) : null}

              <ActionBar
                playHref={playHref}
                replayHref={replayHref}
                position={movie.position}
                trailerKey={extended.trailer_key}
                imdbId={extended.imdb_id}
                tmdbId={movie.tmdb_id}
                onOpenTrailer={openTrailer}
              />

              {data.needs_transcode && !data.is_transcode_ready ? (
                <p
                  className="mt-3 flex items-center gap-2 rounded-lg border border-brand-400/30 bg-brand-500/10 px-3 py-2 text-xs text-brand-300"
                  role="status"
                >
                  <Icon name="bolt" size={14} />
                  First play builds a stream for this title &mdash; it will begin
                  automatically.
                </p>
              ) : null}

              {/*
                The synopsis sits directly under the actions, which is where
                Netflix and Apple TV both put it and where the eye already is.
                That also fills what was an empty band of backdrop below the
                buttons. Italic, so it reads as the title's own voice rather
                than as another metadata block, and `text-wrap: pretty` because
                this is body copy - `balance` is for short headings and the
                guidance is explicit that it must not be used on paragraphs.
              */}
              {movie.overview ? (
                <p
                  className={`mt-4 max-w-2xl text-pretty text-[15px] italic leading-relaxed text-white/70 ${
                    expanded ? '' : 'line-clamp-3 lg:line-clamp-4'
                  }`}
                >
                  {movie.overview}
                </p>
              ) : null}

              {/* A long overview would otherwise drive the hero very tall, so
                  the overflow is bounded behind an explicit control. */}
              {movie.overview && movie.overview.length > 260 ? (
                <button
                  type="button"
                  onClick={() => setExpanded((v) => !v)}
                  className="card-ring mt-1.5 inline-flex items-center gap-1 text-xs font-medium text-white/60 transition hover:text-white"
                  aria-expanded={expanded}
                >
                  {expanded ? 'Less' : 'More'}
                  <Icon name="chevron" size={12} className={expanded ? 'rotate-180' : ''} />
                </button>
              ) : null}
            </div>

            {/*
              Crew facts. In a wide screen this fills the column the backdrop
              would otherwise leave empty; below `lg` it simply stacks after the
              synopsis. Deliberately *not* the synopsis as well - one home per
              fact is what stops the same names appearing twice on one screen.
            */}
            <aside className="w-full shrink-0 lg:w-[19rem] xl:w-[21rem]">
              <div className="rounded-2xl border border-white/10 bg-obsidian-900/55 p-5 shadow-xl shadow-black/30 backdrop-blur-md">
                {extended.directors?.length ||
                extended.writers?.length ||
                extended.production?.length ||
                releaseDate ? (
                  <dl className="mt-4 space-y-3 border-t border-white/10 pt-4">
                    {extended.directors?.length ? (
                      <Fact icon="user" term="Director" compact>
                        {extended.directors.join(', ')}
                      </Fact>
                    ) : null}
                    {extended.writers?.length ? (
                      <Fact icon="pen" term="Writers" compact>
                        {extended.writers.join(', ')}
                      </Fact>
                    ) : null}
                    {extended.production?.length ? (
                      <Fact icon="building" term="Studios" compact>
                        {extended.production.join(', ')}
                      </Fact>
                    ) : null}
                    {releaseDate ? (
                      <Fact icon="calendar" term="Released" compact>
                        {releaseDate}
                      </Fact>
                    ) : null}
                  </dl>
                ) : null}
              </div>
            </aside>
          </div>
        </div>
      </section>

      <div className="mx-auto mt-9 max-w-[1200px] space-y-11 px-4 sm:space-y-12 sm:px-6">
        {extended.cast && extended.cast.length > 0 ? (
          <section aria-labelledby="cast-heading">
            <SectionHeading id="cast-heading" icon="users" title="Top Billed Cast" />
            <CastRail cast={extended.cast} />
          </section>
        ) : null}

        {/*
          Crew facts live in the hero panel, not in a section of their own. They
          are exactly the "soft details" that belong beside the title, and a
          separate Cast & Crew block would print the same names twice on a wide
          screen while leaving the hero's right column empty.
        */}
        <section aria-labelledby="media-heading">
          <SectionHeading id="media-heading" icon="disc" title="Media Information" />
          <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <SpecCard
              icon="video"
              label="Video"
              value={specs.resolution || 'Unknown'}
              sub={[specs.video_codec, specs.video_profile].filter(Boolean).join(' \u00b7 ') || 'Standard'}
              badge={specs.resolution_badge || null}
            />
            <SpecCard
              icon="audio"
              label="Audio"
              value={specs.audio_codec || 'Unknown'}
              sub={specs.audio_channels || 'Stereo'}
            />
            <SpecCard
              icon="disc"
              label="Container"
              value={specs.container || 'Unknown'}
              sub={specs.file_size || null}
            />
            <SpecCard
              icon="gauge"
              label="Bitrate"
              value={specs.bitrate || 'Standard'}
              sub={specs.aspect_ratio ? `Aspect ${specs.aspect_ratio}` : null}
            />
            <SpecCard
              icon="subtitles"
              label="Subtitles"
              value={
                specs.subtitles && specs.subtitles.length > 0
                  ? `${specs.subtitles.length} track${specs.subtitles.length > 1 ? 's' : ''}`
                  : 'None'
              }
              sub={
                specs.subtitles && specs.subtitles.length > 0
                  ? specs.subtitles.slice(0, 3).join(', ')
                  : 'No subtitles available'
              }
              wide={(specs.subtitles?.length ?? 0) > 3}
            />
          </ul>
        </section>
      </div>

      {extended.trailer_key ? (
        <TrailerDialog
          ref={trailerRef}
          open={trailerOpen}
          trailerKey={extended.trailer_key}
          title={movie.title}
          onClose={() => setTrailerOpen(false)}
        />
      ) : null}
    </article>
  );
}

/* ------------------------------------------------------------------------- */
/* Presentational pieces                                                      */
/* ------------------------------------------------------------------------- */

function SectionHeading({ id, icon, title }: { id: string; icon: IconName; title: string }) {
  return (
    <h2
      id={id}
      className="mb-4 flex items-center gap-2.5 text-lg font-semibold tracking-tight text-white"
    >
      <Icon name={icon} size={18} className="text-brand-400" />
      {title}
    </h2>
  );
}

function MetaRow({
  year,
  runtime,
  certification,
  rating,
}: {
  year: number | null | undefined;
  runtime: string | null;
  certification?: string;
  rating: number | null | undefined;
}) {
  return (
    <div className="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2 text-sm text-white/70">
      {year ? <span>{year}</span> : null}
      {runtime ? (
        <span className="inline-flex items-center gap-1.5">
          <Icon name="clock" size={14} className="opacity-60" />
          {runtime}
        </span>
      ) : null}
      {certification ? (
        <span className="rounded border border-white/25 px-1.5 py-0.5 text-[11px] font-medium uppercase tracking-wide text-white/80">
          {certification}
        </span>
      ) : null}
      {rating ? (
        <span className="inline-flex items-center gap-1 font-medium text-amber-300">
          <Icon name="star" size={14} />
          {rating.toFixed(1)}
          <span className="text-xs font-normal text-white/45">/10</span>
        </span>
      ) : null}
    </div>
  );
}

function ActionBar({
  playHref,
  replayHref,
  position,
  trailerKey,
  imdbId,
  tmdbId,
  onOpenTrailer,
}: {
  playHref: string;
  replayHref: string;
  position: number;
  trailerKey?: string;
  imdbId?: string;
  tmdbId?: number | null;
  onOpenTrailer: () => void;
}) {
  const resumable = position > 10;

  return (
    <div className="mt-5 flex flex-wrap items-center gap-2.5">
      <Link
        to={playHref}
        data-testid="play-button"
        className="card-ring inline-flex items-center gap-2 rounded-full brand-gradient px-6 py-2.5 text-sm font-semibold text-white shadow-lg shadow-brand-600/25 transition hover:brightness-110"
      >
        <Icon name="play" size={16} />
        {resumable ? 'Resume' : 'Play'}
      </Link>

      <Link
        to={replayHref}
        className="card-ring inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-4 py-2.5 text-sm text-white/85 transition hover:bg-white/10"
      >
        <Icon name="rotate" size={15} />
        Replay
      </Link>

      {trailerKey ? (
        <button
          type="button"
          onClick={onOpenTrailer}
          className="card-ring inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-4 py-2.5 text-sm text-white/85 transition hover:bg-white/10"
        >
          <Icon name="youtube" size={15} />
          Trailer
        </button>
      ) : null}

      {imdbId ? (
        <a
          href={`https://www.imdb.com/title/${encodeURIComponent(imdbId)}/`}
          target="_blank"
          rel="noopener noreferrer"
          className="card-ring inline-flex items-center gap-1.5 rounded-full border border-white/15 px-3.5 py-2 text-xs font-semibold text-white/75 transition hover:bg-white/10 hover:text-white"
        >
          IMDb
          <Icon name="external" size={12} />
          <span className="sr-only">(opens in a new tab)</span>
        </a>
      ) : null}

      {tmdbId ? (
        <a
          href={`https://www.themoviedb.org/movie/${tmdbId}`}
          target="_blank"
          rel="noopener noreferrer"
          className="card-ring inline-flex items-center gap-1.5 rounded-full border border-white/15 px-3.5 py-2 text-xs font-semibold text-white/75 transition hover:bg-white/10 hover:text-white"
        >
          TMDB
          <Icon name="external" size={12} />
          <span className="sr-only">(opens in a new tab)</span>
        </a>
      ) : null}
    </div>
  );
}

function WatchProgressBar({ percent }: { percent: number | undefined }) {
  const clamped = Math.max(0, Math.min(100, Math.round(percent ?? 0)));
  if (clamped <= 0) return null;
  return (
    <div
      className="mt-2 h-1 overflow-hidden rounded-full bg-white/10"
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={clamped}
      aria-label="Watched"
    >
      <div className="brand-gradient h-full rounded-full" style={{ width: `${clamped}%` }} />
    </div>
  );
}

function Fact({
  icon,
  term,
  children,
  compact,
}: {
  icon: IconName;
  term: string;
  children: React.ReactNode;
  /** Tighter metrics for the narrow hero panel. */
  compact?: boolean;
}) {
  return (
    <div className={`flex gap-3 ${compact ? 'text-[13px] leading-snug' : ''}`}>
      <Icon name={icon} size={compact ? 14 : 16} className="mt-0.5 shrink-0 text-brand-400/80" />
      <div className="min-w-0">
        <dt className="text-xs uppercase tracking-wide text-white/40">{term}</dt>
        <dd className="mt-0.5 text-sm text-white/85">{children}</dd>
      </div>
    </div>
  );
}

function SpecCard({
  icon,
  label,
  value,
  sub,
  badge,
  wide,
}: {
  icon: IconName;
  label: string;
  value: string;
  sub?: string | null;
  badge?: string | null;
  wide?: boolean;
}) {
  return (
    <li
      className={`rounded-xl border border-white/10 bg-obsidian-800/70 p-4 backdrop-blur-sm transition hover:border-white/20 ${
        wide ? 'sm:col-span-2 lg:col-span-1' : ''
      }`}
    >
      <div className="flex items-center gap-2 text-xs uppercase tracking-wide text-white/40">
        <Icon name={icon} size={14} className="text-brand-400/80" />
        {label}
        {badge ? (
          <span className="ml-auto rounded bg-brand-500/20 px-1.5 py-0.5 text-[10px] font-semibold text-brand-300">
            {badge}
          </span>
        ) : null}
      </div>
      <p className="mt-2 text-lg font-semibold text-white">{value}</p>
      {sub ? (
        <p className="mt-0.5 line-clamp-2 text-xs text-white/50" title={sub}>
          {sub}
        </p>
      ) : null}
    </li>
  );
}

/**
 * Trailer in a native `<dialog>`.
 *
 * `showModal()` supplies focus trapping, Escape-to-close and the top-layer
 * stacking for free. The iframe is mounted only while open, so the YouTube
 * player is never fetched speculatively, and unmounting it on close stops
 * playback rather than leaving audio running behind the page.
 */
function TrailerDialog({
  ref,
  open,
  trailerKey,
  title,
  onClose,
}: {
  ref: React.RefObject<HTMLDialogElement | null>;
  open: boolean;
  trailerKey: string;
  title: string;
  onClose: () => void;
}) {
  return (
    <dialog
      ref={ref}
      className="m-auto w-[min(56rem,92vw)] overflow-hidden rounded-2xl border border-white/15 bg-obsidian-900 p-0 backdrop:bg-black/80"
      onClose={onClose}
      onClick={(event) => {
        // A click on the backdrop lands on the dialog element itself; clicks
        // inside the panel land on its children and must not dismiss it.
        if (event.target === event.currentTarget) event.currentTarget.close();
      }}
    >
      <div className="flex items-center justify-between gap-3 border-b border-white/10 px-4 py-3">
        <h2 className="min-w-0 truncate text-sm font-semibold text-white">
          Trailer &mdash; <span className="text-white/60">{title}</span>
        </h2>
        <button
          type="button"
          onClick={() => ref.current?.close()}
          className="card-ring shrink-0 rounded-full border border-white/15 px-3 py-1 text-xs text-white/70 transition hover:bg-white/10 hover:text-white"
        >
          Close
        </button>
      </div>
      {open ? (
        <div className="aspect-video w-full bg-black">
          <iframe
            className="h-full w-full"
            src={`https://www.youtube-nocookie.com/embed/${encodeURIComponent(trailerKey)}?autoplay=1`}
            title={`Trailer for ${title}`}
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
            allowFullScreen
          />
        </div>
      ) : null}
    </dialog>
  );
}

export default MovieDetailsPage;