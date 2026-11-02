import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../../../core/device/data/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../library/data/repositories/library_repository.dart';
import '../../../library/domain/models/movie_item.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../../domain/models/storage_audit_model.dart';
import '../providers/admin_providers.dart';

enum _InventoryFilter { all, needsTranscode, hls, direct, watched, unwatched }

enum _InventorySort { title, year, recent }

class MediaInventoryView extends ConsumerStatefulWidget {
  const MediaInventoryView({super.key});

  @override
  ConsumerState<MediaInventoryView> createState() => _MediaInventoryViewState();
}

class _MediaInventoryViewState extends ConsumerState<MediaInventoryView> {
  final TextEditingController _searchController = TextEditingController();
  _InventoryFilter _filter = _InventoryFilter.all;
  _InventorySort _sort = _InventorySort.title;
  String? _busyFilename;
  final Map<String, _MovieTranscodeState> _transcodeStates = {};
  final Set<String> _checkedTranscodeStates = {};
  final Set<String> _loadingTranscodeStates = {};
  int _transcodeStateGeneration = 0;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    _transcodeStateGeneration++;
    setState(() {
      _transcodeStates.clear();
      _checkedTranscodeStates.clear();
      _loadingTranscodeStates.clear();
    });
    await Future.wait([
      ref.read(libraryControllerProvider.notifier).loadLibrary(isRefresh: true),
      ref.read(storageControllerProvider.notifier).refresh(force: true),
    ]);
  }

  bool _isMkv(MovieItem movie) =>
      movie.filename.toLowerCase().endsWith('.mkv') || movie.needsTranscode;

  ActiveHlsCache? _cacheFor(MovieItem movie, List<ActiveHlsCache> caches) {
    final filename = movie.filename.toLowerCase();
    for (final cache in caches) {
      final source = cache.sourceFile.toLowerCase();
      // The audit's source_file currently contains only a basename. Do not
      // attach it to a nested title with the same basename as another movie.
      if (source == filename) return cache;
    }
    return null;
  }

  bool _hasCache(MovieItem movie, List<ActiveHlsCache> caches) {
    if (_isMkv(movie)) {
      return _transcodeStates[movie.filename]?.isComplete == true;
    }
    return _cacheFor(movie, caches) != null;
  }

  bool _isTranscoding(MovieItem movie) {
    return _transcodeStates[movie.filename]?.isInProgress == true;
  }

  bool _needsPreTranscode(MovieItem movie) {
    return _isMkv(movie) && _transcodeStates[movie.filename]?.status == 'idle';
  }

  void _ensureTranscodeStates(List<MovieItem> movies) {
    final candidates = movies
        .where(
          (movie) =>
              _isMkv(movie) &&
              !_checkedTranscodeStates.contains(movie.filename) &&
              !_loadingTranscodeStates.contains(movie.filename),
        )
        .toList();
    if (candidates.isEmpty) return;

    final generation = _transcodeStateGeneration;
    _loadingTranscodeStates.addAll(candidates.map((movie) => movie.filename));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repository = ref.read(libraryRepositoryProvider);
      final results = await Future.wait(
        candidates.map((movie) async {
          final response = await repository.getTranscodeStatus(movie.filename);
          return (filename: movie.filename, response: response);
        }),
      );
      if (!mounted || generation != _transcodeStateGeneration) return;
      setState(() {
        for (final result in results) {
          _loadingTranscodeStates.remove(result.filename);
          _checkedTranscodeStates.add(result.filename);
          _transcodeStates[result.filename] = _MovieTranscodeState.fromJson(
            result.response,
          );
        }
      });
    });
  }

  List<MovieItem> _visibleMovies(
    List<MovieItem> movies,
    List<ActiveHlsCache> caches,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    final result = movies.where((movie) {
      if (query.isNotEmpty) {
        final matches =
            movie.title.toLowerCase().contains(query) ||
            movie.filename.toLowerCase().contains(query) ||
            (movie.year?.toString().contains(query) ?? false);
        if (!matches) return false;
      }

      final isMkv = _isMkv(movie);
      final hasCache = _hasCache(movie, caches);
      switch (_filter) {
        case _InventoryFilter.all:
          return true;
        case _InventoryFilter.needsTranscode:
          return _needsPreTranscode(movie);
        case _InventoryFilter.hls:
          return isMkv || hasCache;
        case _InventoryFilter.direct:
          return !isMkv;
        case _InventoryFilter.watched:
          return movie.percent > 0;
        case _InventoryFilter.unwatched:
          return movie.percent == 0;
      }
    }).toList();

    result.sort((a, b) {
      switch (_sort) {
        case _InventorySort.title:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case _InventorySort.year:
          return (b.year ?? 0).compareTo(a.year ?? 0);
        case _InventorySort.recent:
          return (b.updatedAt ?? '').compareTo(a.updatedAt ?? '');
      }
    });
    return result;
  }

  Future<void> _watch(MovieItem movie) async {
    final baseUrl = ref.read(serverBaseUrlProvider);
    final mediaUrl = '$baseUrl/media/${Uri.encodeComponent(movie.filename)}';
    await context.push(
      AppRoutes.player,
      extra: {
        'mediaUrl': mediaUrl,
        'title': movie.title,
        'subtitle': '${movie.year ?? ''} • ${movie.formattedRuntime}',
        'startPosition': movie.position > 10
            ? Duration(seconds: movie.position.toInt())
            : null,
        'mediaFilename': movie.filename,
        'backLabel': 'Back to Admin Hub',
      },
    );
    if (mounted) {
      await ref
          .read(libraryControllerProvider.notifier)
          .loadLibrary(isRefresh: true);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: destructive
                ? AppColors.brandRed.withValues(alpha: 0.65)
                : AppColors.borderMedium,
          ),
        ),
        title: Text(title, style: AppTypography.titleLarge),
        content: Text(
          message,
          style: AppTypography.bodyMedium.copyWith(
            color: AppColors.textSecondary,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: destructive
                  ? AppColors.brandRed
                  : AppColors.surfaceHighlight,
              foregroundColor: destructive
                  ? AppColors.textOnBrand
                  : AppColors.textPrimary,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _archive(MovieItem movie) async {
    final confirmed = await _confirm(
      title: 'Archive Original?',
      message:
          'Move the original file for “${movie.title}” to cold storage? Its stream cache will remain available for playback.',
      action: 'Archive Original',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyFilename = movie.filename);
    try {
      final success = await ref
          .read(adminRepositoryProvider)
          .archiveMovieMedia(movie.filename);
      if (!success) {
        throw StateError('The server did not archive this media item.');
      }
      await _refresh();
      if (mounted) {
        _showMessage(
          'Archived “${movie.title}”; its stream cache remains available.',
        );
      }
    } catch (error) {
      if (mounted) _showMessage('Archive failed: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busyFilename = null);
    }
  }

  Future<void> _delete(MovieItem movie) async {
    final confirmed = await _confirm(
      title: 'Permanently Delete & Purge?',
      message:
          'Delete “${movie.title}” and purge its source video, stream caches, thumbnails, sidecar subtitles, metadata, and playback progress? This cannot be undone.',
      action: 'Delete Everything',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyFilename = movie.filename);
    try {
      final success = await ref
          .read(adminRepositoryProvider)
          .deleteMovieMedia(movie.filename);
      if (!success) {
        throw StateError('The server did not delete this media item.');
      }
      await _refresh();
      if (mounted) {
        _showMessage('Deleted “${movie.title}” and its associated data.');
      }
    } catch (error) {
      if (mounted) _showMessage('Delete failed: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busyFilename = null);
    }
  }

  Future<void> _preTranscode(MovieItem movie) async {
    setState(() => _busyFilename = movie.filename);
    try {
      final success = await ref
          .read(adminRepositoryProvider)
          .preTranscodeMovie(movie.filename);
      if (!success) throw StateError('The server did not queue this title.');
      await _refresh();
      if (mounted) _showMessage('Pre-transcode queued for “${movie.title}”.');
    } catch (error) {
      if (mounted) {
        _showMessage('Could not queue pre-transcode: $error', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busyFilename = null);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError
              ? AppColors.statusError
              : AppColors.surfaceHighlight,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryControllerProvider);
    final storage = ref.watch(storageControllerProvider);
    final baseUrl = ref.watch(serverBaseUrlProvider);
    final isTv = ref.watch(isTvModeProvider);
    final movies = library.movies;
    final caches = storage.report?.audit.activeHls ?? const <ActiveHlsCache>[];
    _ensureTranscodeStates(movies);
    final filtered = _visibleMovies(movies, caches);
    final readyCount = movies.where((movie) => _hasCache(movie, caches)).length;
    final directCount = movies.where((movie) => !_isMkv(movie)).length;

    return RefreshIndicator(
      color: AppColors.brandRed,
      backgroundColor: AppColors.surfaceElevated,
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.all(isTv ? 24 : 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildSummary(
                  total: movies.length,
                  filtered: filtered.length,
                  ready: readyCount,
                  direct: directCount,
                  storageLoading: storage.isLoading,
                  isTv: isTv,
                ),
                const SizedBox(height: 14),
                _buildSearchAndSort(isTv),
                const SizedBox(height: 12),
                _buildFilters(isTv, totalCount: movies.length),
                const SizedBox(height: 12),
                if (library.status == LibraryStatus.loading && movies.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(36),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.brandRed,
                      ),
                    ),
                  )
                else if (library.status == LibraryStatus.error &&
                    movies.isEmpty)
                  _buildError(
                    library.errorMessage ??
                        'Could not load the media inventory.',
                  )
                else if (movies.isEmpty)
                  _buildEmpty('No media files are available in the library.')
                else if (filtered.isEmpty)
                  _buildEmpty(
                    'No titles match these search and filter settings.',
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'MEDIA INVENTORY',
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          if (filtered.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                isTv ? 24 : 16,
                0,
                isTv ? 24 : 16,
                24,
              ),
              sliver: SliverList.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildMovieCard(
                    filtered[index],
                    caches: caches,
                    baseUrl: baseUrl,
                    isTv: isTv,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummary({
    required int total,
    required int filtered,
    required int ready,
    required int direct,
    required bool storageLoading,
    required bool isTv,
  }) {
    return Container(
      padding: EdgeInsets.all(isTv ? 20 : 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.video_library_rounded,
                color: AppColors.brandRed,
                size: 22,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Media Inventory',
                  style: AppTypography.titleMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$filtered of $total',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Play, inspect, archive, pre-transcode, or permanently delete titles.',
            style: AppTypography.labelSmall.copyWith(
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _summaryPill(
                'Stream Ready',
                '$ready',
                AppColors.statusSuccess,
                loading: storageLoading,
              ),
              _summaryPill('Direct Play', '$direct', AppColors.statusInfo),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryPill(
    String label,
    String value,
    Color color, {
    bool loading = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '$value $label',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndSort(bool isTv) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: isTv ? 60 : 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  color: AppColors.textMuted,
                  size: 21,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    style: AppTypography.bodyMedium,
                    decoration: const InputDecoration(
                      hintText: 'Search title, filename, or year',
                      hintStyle: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear search',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 19,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<_InventorySort>(
              value: _sort,
              dropdownColor: AppColors.surfaceElevated,
              iconEnabledColor: AppColors.textSecondary,
              style: AppTypography.labelSmall.copyWith(
                color: AppColors.textPrimary,
              ),
              items: const [
                DropdownMenuItem(
                  value: _InventorySort.title,
                  child: Text('Title'),
                ),
                DropdownMenuItem(
                  value: _InventorySort.year,
                  child: Text('Year'),
                ),
                DropdownMenuItem(
                  value: _InventorySort.recent,
                  child: Text('Recent'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _sort = value);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilters(bool isTv, {required int totalCount}) {
    final options = [
      (_InventoryFilter.all, 'All ($totalCount)'),
      (_InventoryFilter.needsTranscode, '⚡ Needs Pre-Transcode'),
      (_InventoryFilter.hls, 'Adaptive / MKV'),
      (_InventoryFilter.direct, 'Direct Play'),
      (_InventoryFilter.watched, 'In Progress'),
      (_InventoryFilter.unwatched, 'Unwatched'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TvFocusable(
                borderRadius: BorderRadius.circular(999),
                scaleOnFocus: false,
                onPressed: () => setState(() => _filter = option.$1),
                builder: (context, isFocused, _) {
                  final selected = _filter == option.$1;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: EdgeInsets.symmetric(
                      horizontal: isTv ? 16 : 12,
                      vertical: isTv ? 11 : 9,
                    ),
                    decoration: BoxDecoration(
                      color: selected || isFocused
                          ? AppColors.brandRed.withValues(
                              alpha: isFocused ? 0.30 : 0.18,
                            )
                          : AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isFocused
                            ? AppColors.brandRedLight
                            : selected
                            ? AppColors.brandRed
                            : AppColors.borderSubtle,
                        width: isFocused ? 3 : 1,
                      ),
                      boxShadow: isFocused
                          ? [
                              BoxShadow(
                                color: AppColors.brandRedGlow.withValues(
                                  alpha: 0.85,
                                ),
                                blurRadius: 18,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      option.$2,
                      style: AppTypography.labelSmall.copyWith(
                        color: selected || isFocused
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight: selected || isFocused
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMovieCard(
    MovieItem movie, {
    required List<ActiveHlsCache> caches,
    required String baseUrl,
    required bool isTv,
  }) {
    final cache = _cacheFor(movie, caches);
    final hasCache = _hasCache(movie, caches);
    final isMkv = _isMkv(movie);
    final transcodeState = _transcodeStates[movie.filename];
    final isCheckingTranscode = _loadingTranscodeStates.contains(
      movie.filename,
    );
    final isBusy = _busyFilename == movie.filename;
    final extension = movie.filename.split('.').last.toUpperCase();
    final poster = movie.posterUrl(baseUrl);
    final status = hasCache
        ? 'Stream Ready${cache != null && cache.sizeBytes > 0 ? ' • ${_formatBytes(cache.sizeBytes)}' : ''}'
        : isMkv && isCheckingTranscode
        ? 'Checking Stream Status…'
        : isMkv && _isTranscoding(movie)
        ? 'Pre-Transcode In Progress'
        : isMkv && transcodeState?.status == 'idle'
        ? 'Pre-Transcode Required'
        : isMkv
        ? 'Stream Status Unavailable'
        : 'Direct Play';
    final statusColor = hasCache
        ? AppColors.statusSuccess
        : isMkv && transcodeState?.status == 'idle'
        ? const Color(0xFFFFC45C)
        : isMkv
        ? AppColors.textSecondary
        : AppColors.statusInfo;

    return Container(
      padding: EdgeInsets.all(isTv ? 16 : 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: isTv ? 54 : 46,
                  height: isTv ? 78 : 66,
                  child: poster == null
                      ? const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(
                            Icons.movie_outlined,
                            color: AppColors.textMuted,
                          ),
                        )
                      : Image.network(
                          poster,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) =>
                              const ColoredBox(
                                color: AppColors.surface,
                                child: Icon(
                                  Icons.movie_outlined,
                                  color: AppColors.textMuted,
                                ),
                              ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${movie.title}${movie.year != null ? ' (${movie.year})' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodyMedium.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      movie.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        _badge(extension, AppColors.textSecondary),
                        _badge(status, statusColor),
                        if (movie.percent > 0)
                          _badge(
                            'Watched ${movie.percent.round()}%',
                            AppColors.brandRedLight,
                          ),
                      ],
                    ),
                    if (movie.runtime != null && movie.runtime! > 0) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Runtime: ${movie.formattedRuntime}${movie.rating != null ? ' • Rating: ${movie.rating!.toStringAsFixed(1)}' : ''}',
                        style: AppTypography.labelSmall.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _actionButton(
                icon: Icons.play_arrow_rounded,
                label: 'Watch',
                color: AppColors.brandRed,
                enabled: !isBusy,
                onPressed: () => _watch(movie),
              ),
              _actionButton(
                icon: Icons.info_outline_rounded,
                label: 'Details',
                color: AppColors.statusInfo,
                enabled: !isBusy,
                onPressed: () =>
                    context.push(AppRoutes.movieDetails, extra: movie),
              ),
              if (_needsPreTranscode(movie))
                _actionButton(
                  icon: Icons.bolt_rounded,
                  label: isBusy ? 'Queuing…' : 'Pre-Transcode',
                  color: const Color(0xFFFFC45C),
                  enabled: _busyFilename == null,
                  onPressed: () => _preTranscode(movie),
                ),
              if (isMkv && hasCache)
                _actionButton(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  color: const Color(0xFFFFC45C),
                  enabled: _busyFilename == null,
                  onPressed: () => _archive(movie),
                ),
              _actionButton(
                icon: Icons.delete_outline_rounded,
                label: isBusy ? 'Working…' : 'Delete',
                color: AppColors.statusError,
                enabled: _busyFilename == null,
                onPressed: () => _delete(movie),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return TvFocusable(
      borderRadius: BorderRadius.circular(999),
      scaleOnFocus: false,
      onPressed: enabled ? onPressed : null,
      builder: (context, isFocused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: isFocused
              ? color.withValues(alpha: 0.28)
              : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isFocused
                ? AppColors.textPrimary
                : color.withValues(alpha: 0.45),
            width: isFocused ? 3 : 1,
          ),
          boxShadow: isFocused
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.7),
                    blurRadius: 15,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.statusError.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.statusError.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Media inventory could not load',
            style: AppTypography.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: AppTypography.labelSmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => ref
                .read(libraryControllerProvider.notifier)
                .loadLibrary(isRefresh: true),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Column(
          children: [
            const Icon(
              Icons.video_library_outlined,
              size: 32,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            if (_searchController.text.isNotEmpty ||
                _filter != _InventoryFilter.all) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() {
                  _searchController.clear();
                  _filter = _InventoryFilter.all;
                }),
                child: const Text('Reset search and filters'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }
}

class _MovieTranscodeState {
  final String status;
  final bool isComplete;

  const _MovieTranscodeState({required this.status, required this.isComplete});

  bool get isInProgress => status == 'queued' || status == 'transcoding';

  factory _MovieTranscodeState.fromJson(Map<String, dynamic> json) {
    final status = json['status']?.toString().toLowerCase() ?? 'unknown';
    return _MovieTranscodeState(
      status: status,
      isComplete: json['is_complete'] == true || status == 'complete',
    );
  }
}
