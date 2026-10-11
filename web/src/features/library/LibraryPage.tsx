import { listMovies } from '../../lib/api/client';
import { useDeviceId } from '../../lib/useDeviceId';
import { StateMessage } from '../../components/StateMessage';
import { useAsync } from '../../lib/useAsync';
import { MovieGrid } from '../../components/MovieGrid';

export function LibraryPage() {
  const deviceId = useDeviceId();

  const { data, error, loading } = useAsync(
    (signal) => listMovies({ signal, deviceId }),
    [deviceId],
  );

  const movies = data?.movies ?? [];
  const watching = data?.watching ?? [];

  return (
    <div className="space-y-10">
      {/*
        "Continue watching" only renders when there is something to continue.
        An empty rail is worse than no rail - it reads as a broken feature
        rather than an absent one.
      */}
      {watching.length > 0 ? (
        <MovieGrid movies={watching} title="Continue watching" />
      ) : null}

      <StateMessage
        loading={loading}
        error={error}
        empty={!loading && !error && movies.length === 0}
        emptyText="No movies found. Run a scan from the library page to populate the catalog."
      >
        <MovieGrid movies={movies} title={watching.length > 0 ? 'All movies' : 'Movies'} />
      </StateMessage>
    </div>
  );
}

export default LibraryPage;