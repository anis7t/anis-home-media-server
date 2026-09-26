import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../data/models/movie_details.dart';
import '../../data/models/movie_extended_details.dart';
import '../../data/models/movie_item.dart';
import '../../data/models/movie_specs.dart';
import '../../data/repositories/library_repository.dart';

/// Screen displaying rich metadata, technical specs, and direct playback handshake for a single movie.
class MovieDetailsScreen extends ConsumerStatefulWidget {
  final MovieItem? initialMovie;
  final String? filename;

  const MovieDetailsScreen({super.key, this.initialMovie, this.filename});

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen> {
  MovieDetails? _details;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchDetails();
  }

  String get _targetFilename {
    return widget.initialMovie?.filename ?? widget.filename ?? '';
  }

  Future<void> _fetchDetails() async {
    final fn = _targetFilename;
    if (fn.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'No movie file specified.';
      });
      return;
    }

    try {
      final repo = ref.read(libraryRepositoryProvider);
      final details = await repo.getMovieDetails(fn);
      if (mounted) {
        setState(() {
          _details = details;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _launchPlayer({Duration? startPosition}) async {
    final movie = _details?.movie ?? widget.initialMovie;
    if (movie == null) return;

    final baseUrl = ref.read(serverBaseUrlProvider);
    final mediaUrl = '$baseUrl/media/${Uri.encodeComponent(movie.filename)}';

    final targetPosition =
        startPosition ??
        (movie.position > 10
            ? Duration(seconds: movie.position.toInt())
            : null);

    await context.push(
      AppRoutes.player,
      extra: {
        'mediaUrl': mediaUrl,
        'title': movie.title,
        'subtitle': '${movie.year ?? ''} • ${movie.formattedRuntime}',
        'startPosition': targetPosition,
        'mediaFilename': movie.filename,
      },
    );

    // Refresh details upon return to synchronize watch position
    if (mounted) {
      _fetchDetails();
    }
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) return '0:00';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final baseUrl = ref.watch(serverBaseUrlProvider);
    final movie = _details?.movie ?? widget.initialMovie;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildContent(baseUrl, movie),
    );
  }

  Widget _buildContent(String baseUrl, MovieItem? movie) {
    if (_isLoading && movie == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.brandRed),
      );
    }

    if (_errorMessage != null && movie == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: AppColors.statusError,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load movie details',
                style: AppTypography.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: AppTypography.bodyMedium,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                key: const ValueKey('retry_details_button'),
                onPressed: () {
                  setState(() => _isLoading = true);
                  _fetchDetails();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandRed,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (movie == null) {
      return const Center(child: Text('Movie not found'));
    }

    final posterUrl = movie.posterUrl(baseUrl);
    final backdropUrl =
        _details?.backdropUrl(baseUrl) ?? movie.backdropUrl(baseUrl);
    final specs = _details?.specs;
    final extended = _details?.extended;
    final transcode = _details?.transcodeInfo;

    return Stack(
      children: [
        // Scrollable content
        SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero / Backdrop Card
              _buildHeroBackdrop(backdropUrl),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),

                    // Main Meta Row: Poster + Info
                    _buildMetaRow(movie, posterUrl, extended, specs),

                    const SizedBox(height: 20),

                    // Active Transcoding Indicator (if active)
                    if (transcode != null) ...[
                      _buildTranscodeBanner(transcode),
                      const SizedBox(height: 16),
                    ],

                    // Direct Playback Handshake Actions
                    _buildPlaybackActions(movie),

                    const SizedBox(height: 20),

                    // Overview / Synopsis
                    if (movie.overview.isNotEmpty ||
                        extended?.tagline != null) ...[
                      _buildOverviewSection(movie, extended),
                      const SizedBox(height: 24),
                    ],

                    // Top Cast Rail
                    if (extended != null && extended.cast.isNotEmpty) ...[
                      _buildCastRail(extended.cast),
                      const SizedBox(height: 24),
                    ],

                    // Technical Specs Section
                    if (specs != null) ...[
                      _buildTechnicalSpecs(specs),
                      const SizedBox(height: 20),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        // Floating Back & Refresh Bar
        _buildFloatingHeader(movie),
      ],
    );
  }

  Widget _buildFloatingHeader(MovieItem movie) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Circular obsidian back button
              Container(
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: IconButton(
                  key: const ValueKey('movie_details_back_btn'),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  onPressed: () => context.pop(),
                  tooltip: 'Back to Library',
                ),
              ),

              // Refresh action button
              Container(
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: IconButton(
                  key: const ValueKey('movie_details_refresh_btn'),
                  icon: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.brandRed,
                          ),
                        )
                      : const Icon(
                          Icons.refresh_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                  onPressed: _isLoading ? null : _fetchDetails,
                  tooltip: 'Refresh Metadata',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroBackdrop(String? backdropUrl) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final heroHeight = (screenWidth * 9 / 16).clamp(180.0, 320.0);

    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropUrl != null)
            Image.network(
              backdropUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: AppColors.surfaceElevated,
                child: const Center(
                  child: Icon(
                    Icons.movie_rounded,
                    size: 48,
                    color: Colors.white24,
                  ),
                ),
              ),
            )
          else
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1B2232), AppColors.background],
                ),
              ),
              child: const Center(
                child: Icon(
                  Icons.movie_rounded,
                  size: 64,
                  color: Colors.white12,
                ),
              ),
            ),

          // Gradient Scrim Overlay
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.4),
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.8),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.35, 0.75, 1.0],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(
    MovieItem movie,
    String? posterUrl,
    MovieExtendedDetails? extended,
    MovieSpecs? specs,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Poster Card with border
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 108,
            height: 160,
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: posterUrl != null
                ? Image.network(
                    posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _buildFallbackPoster(movie),
                  )
                : _buildFallbackPoster(movie),
          ),
        ),
        const SizedBox(width: 16),

        // Title & Badges
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                movie.title,
                style: AppTypography.displayMedium.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
              ),
              if (extended?.tagline != null &&
                  extended!.tagline.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '“${extended.tagline}”',
                  style: AppTypography.bodyMedium.copyWith(
                    fontStyle: FontStyle.italic,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 10),

              // Badges Wrap
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (movie.year != null) _buildPillBadge('${movie.year}'),
                  if (movie.formattedRuntime.isNotEmpty)
                    _buildPillBadge(movie.formattedRuntime),
                  if (movie.rating != null && movie.rating! > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF231C0D),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0x66FFB800)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Color(0xFFFFB800),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            movie.rating!.toStringAsFixed(1),
                            style: AppTypography.labelSmall.copyWith(
                              color: const Color(0xFFFFB800),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (extended?.certification != null &&
                      extended!.certification!.isNotEmpty)
                    _buildPillBadge(extended.certification!),
                  if (specs != null && specs.resolutionBadge.isNotEmpty)
                    _buildPillBadge(specs.resolutionBadge, isAccent: true),
                ],
              ),

              if (movie.genres.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  movie.genres,
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackActions(MovieItem movie) {
    final hasProgress = movie.position > 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Progress Bar (if watched > 10s)
        if (hasProgress) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: movie.progressFraction,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.brandRed,
              ),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Watched ${_formatDuration(Duration(seconds: movie.position.toInt()))} of ${_formatDuration(Duration(seconds: movie.duration.toInt()))}',
                style: AppTypography.bodyMedium.copyWith(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
              Text(
                '${(movie.progressFraction * 100).toInt()}%',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.brandRedLight,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // Playback Buttons
        if (hasProgress) ...[
          Row(
            children: [
              // Resume Button
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    key: const ValueKey('resume_play_button'),
                    onPressed: () => _launchPlayer(
                      startPosition: Duration(seconds: movie.position.toInt()),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandRed,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    label: Text(
                      'Resume (${_formatDuration(Duration(seconds: movie.position.toInt()))})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Play from Beginning Button
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: const ValueKey('start_beginning_button'),
                    onPressed: () =>
                        _launchPlayer(startPosition: Duration.zero),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.surfaceElevated,
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.borderMedium),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.replay_rounded, size: 20),
                    label: const Text(
                      'From Start',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          // Single Play Movie Button
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const ValueKey('primary_play_button'),
              onPressed: () => _launchPlayer(startPosition: Duration.zero),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 26),
              label: const Text(
                'Play Movie',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTranscodeBanner(Map<String, dynamic> transcode) {
    final speed = transcode['speed']?.toString() ?? '1.0x';
    final fps = transcode['fps']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1710),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x66FF9800)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt_rounded, color: Color(0xFFFF9800), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Active Multi-GPU Transcoding',
                  style: TextStyle(
                    color: Color(0xFFFF9800),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Encoding stream at $speed ${fps.isNotEmpty ? '($fps fps)' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewSection(
    MovieItem movie,
    MovieExtendedDetails? extended,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Overview', style: AppTypography.titleLarge),
        const SizedBox(height: 8),
        if (movie.overview.isNotEmpty)
          Text(
            movie.overview,
            style: AppTypography.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
        if (extended != null &&
            (extended.directors.isNotEmpty || extended.writers.isNotEmpty)) ...[
          const SizedBox(height: 12),
          if (extended.directors.isNotEmpty)
            _buildCrewLine('Directed by', extended.directors.join(', ')),
          if (extended.writers.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildCrewLine('Written by', extended.writers.join(', ')),
          ],
        ],
      ],
    );
  }

  Widget _buildCrewLine(String role, String names) {
    return RichText(
      text: TextSpan(
        style: AppTypography.bodyMedium.copyWith(
          fontSize: 12,
          color: AppColors.textMuted,
        ),
        children: [
          TextSpan(
            text: '$role: ',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white70,
            ),
          ),
          TextSpan(
            text: names,
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildCastRail(List<CastMember> cast) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Top Cast', style: AppTypography.titleLarge),
        const SizedBox(height: 12),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: cast.length,
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final actor = cast[index];
              return Container(
                width: 180,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Row(
                  children: [
                    // Actor Avatar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: actor.profileUrl != null
                            ? Image.network(
                                actor.profileUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    _buildFallbackAvatar(actor.name),
                              )
                            : _buildFallbackAvatar(actor.name),
                      ),
                    ),
                    const SizedBox(width: 10),

                    // Name & Role
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            actor.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.labelLarge.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          if (actor.character != null &&
                              actor.character!.isNotEmpty)
                            Text(
                              actor.character!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.labelSmall.copyWith(
                                color: AppColors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFallbackAvatar(String name) {
    final initials = name
        .split(' ')
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();

    return Container(
      color: const Color(0xFF2A344A),
      child: Center(
        child: Text(
          initials.isNotEmpty ? initials : '🎭',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildTechnicalSpecs(MovieSpecs specs) {
    final items = <MapEntry<String, String>>[];
    if (specs.resolution.isNotEmpty) {
      final res = specs.resolutionBadge.isNotEmpty
          ? '${specs.resolution} (${specs.resolutionBadge})'
          : specs.resolution;
      items.add(MapEntry('Resolution', res));
    }
    if (specs.videoCodec.isNotEmpty) {
      final v = specs.videoProfile.isNotEmpty
          ? '${specs.videoCodec} ${specs.videoProfile}'
          : specs.videoCodec;
      items.add(MapEntry('Video Codec', v));
    }
    if (specs.audioCodec.isNotEmpty) {
      final a = specs.audioChannels.isNotEmpty
          ? '${specs.audioCodec} • ${specs.audioChannels} ch'
          : specs.audioCodec;
      items.add(MapEntry('Audio', a));
    }
    if (specs.container.isNotEmpty) {
      final c = specs.fileSize.isNotEmpty
          ? '${specs.container.toUpperCase()} • ${specs.fileSize}'
          : specs.container.toUpperCase();
      items.add(MapEntry('Container / Size', c));
    }
    if (specs.bitrate.isNotEmpty) {
      items.add(MapEntry('Bitrate', specs.bitrate));
    }
    if (specs.subtitles.isNotEmpty) {
      items.add(MapEntry('Subtitles', specs.subtitles.join(', ')));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Technical Specs', style: AppTypography.titleLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items.map((e) => _buildSpecPill(e.key, e.value)).toList(),
        ),
      ],
    );
  }

  Widget _buildSpecPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: AppTypography.labelSmall.copyWith(
              color: AppColors.textMuted,
            ),
          ),
          Text(
            value,
            style: AppTypography.labelSmall.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPillBadge(String text, {bool isAccent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isAccent ? const Color(0x33E50914) : AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isAccent ? AppColors.brandRed : AppColors.borderMedium,
        ),
      ),
      child: Text(
        text,
        style: AppTypography.labelSmall.copyWith(
          color: isAccent ? AppColors.brandRedLight : AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFallbackPoster(MovieItem movie) {
    return Container(
      color: AppColors.surfaceElevated,
      child: Center(
        child: Text(
          movie.title.isNotEmpty ? movie.title[0].toUpperCase() : '🎬',
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: AppColors.brandRed,
          ),
        ),
      ),
    );
  }
}
