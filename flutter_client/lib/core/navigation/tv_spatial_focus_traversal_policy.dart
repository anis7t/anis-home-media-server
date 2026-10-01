import 'dart:math';
import 'package:flutter/material.dart';

/// 2D Spatial Focus Traversal Policy for TV and D-pad interfaces.
///
/// Replaces Flutter's default 1D "band" culling and history stack with true
/// 2D geometric spatial navigation. Prevents directional navigation from
/// skipping adjacent rows/columns, hopping over offset chips or grid cards,
/// or getting trapped in historical hysteresis loops.
class TvSpatialFocusTraversalPolicy extends FocusTraversalPolicy {
  const TvSpatialFocusTraversalPolicy({super.requestFocusCallback});

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final list = descendants.where((node) => node.context != null).toList();
    list.sort((a, b) {
      final rectA = a.rect;
      final rectB = b.rect;
      final verticalDiff = rectA.top - rectB.top;
      if (verticalDiff.abs() > 8.0) {
        return verticalDiff.compareTo(0);
      }
      return rectA.left.compareTo(rectB.left);
    });
    return list;
  }

  @override
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) {
    final scope = currentNode.nearestScope;
    if (scope == null) return null;
    final candidates = scope.traversalDescendants
        .where((node) => node.canRequestFocus && node.context != null)
        .toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final rA = a.rect;
      final rB = b.rect;
      switch (direction) {
        case TraversalDirection.down:
          final topComp = rA.top.compareTo(rB.top);
          return topComp != 0 ? topComp : rA.left.compareTo(rB.left);
        case TraversalDirection.up:
          final btmComp = rB.bottom.compareTo(rA.bottom);
          return btmComp != 0 ? btmComp : rA.left.compareTo(rB.left);
        case TraversalDirection.right:
          final leftComp = rA.left.compareTo(rB.left);
          return leftComp != 0 ? leftComp : rA.top.compareTo(rB.top);
        case TraversalDirection.left:
          final rightComp = rB.right.compareTo(rA.right);
          return rightComp != 0 ? rightComp : rA.top.compareTo(rB.top);
      }
    });

    return candidates.firstOrNull;
  }

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final nearestScope = currentNode.nearestScope;
    if (nearestScope == null) return false;

    final focusedChild = nearestScope.focusedChild ?? currentNode;
    final sourceRect = focusedChild.rect;

    final candidates = nearestScope.traversalDescendants
        .where((node) =>
            node != focusedChild &&
            node.canRequestFocus &&
            node.context != null)
        .toList();

    if (candidates.isEmpty) {
      return false;
    }

    FocusNode? bestCandidate;
    double bestScore = double.infinity;

    for (final candidate in candidates) {
      final targetRect = candidate.rect;
      if (targetRect.width <= 0 || targetRect.height <= 0) {
        continue;
      }

      if (!_isEligibleInDirection(sourceRect, targetRect, direction)) {
        continue;
      }

      final score = _computeSpatialScore(sourceRect, targetRect, direction);
      if (score < bestScore) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }

    if (bestCandidate != null) {
      final policy = switch (direction) {
        TraversalDirection.up || TraversalDirection.left =>
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        TraversalDirection.down || TraversalDirection.right =>
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      };

      requestFocusCallback(
        bestCandidate,
        alignmentPolicy: policy,
      );
      return true;
    }

    return false;
  }

  /// Determines whether [target] is a valid navigation candidate in [direction] from [source].
  bool _isEligibleInDirection(
    Rect source,
    Rect target,
    TraversalDirection direction,
  ) {
    switch (direction) {
      case TraversalDirection.down:
        if (target.center.dy <= source.center.dy + 1.0) {
          return false;
        }
        final overlapY = max(0.0, min(source.bottom, target.bottom) - max(source.top, target.top));
        final minH = min(source.height, target.height);
        if (minH > 0 && (overlapY / minH) > 0.6) {
          return false; // Same visual row
        }
        return true;

      case TraversalDirection.up:
        if (target.center.dy >= source.center.dy - 1.0) {
          return false;
        }
        final overlapY = max(0.0, min(source.bottom, target.bottom) - max(source.top, target.top));
        final minH = min(source.height, target.height);
        if (minH > 0 && (overlapY / minH) > 0.6) {
          return false; // Same visual row
        }
        return true;

      case TraversalDirection.right:
        if (target.center.dx <= source.center.dx + 1.0) {
          return false;
        }
        final overlapX = max(0.0, min(source.right, target.right) - max(source.left, target.left));
        final minW = min(source.width, target.width);
        if (minW > 0 && (overlapX / minW) > 0.6) {
          return false; // Same visual column
        }
        return true;

      case TraversalDirection.left:
        if (target.center.dx >= source.center.dx - 1.0) {
          return false;
        }
        final overlapX = max(0.0, min(source.right, target.right) - max(source.left, target.left));
        final minW = min(source.width, target.width);
        if (minW > 0 && (overlapX / minW) > 0.6) {
          return false; // Same visual column
        }
        return true;
    }
  }

  /// Computes a composite spatial navigation score. Lower score is better.
  double _computeSpatialScore(
    Rect source,
    Rect target,
    TraversalDirection direction,
  ) {
    switch (direction) {
      case TraversalDirection.down:
        final primaryDist = target.top >= source.bottom
            ? target.top - source.bottom
            : max(0.0, target.center.dy - source.center.dy);
        final overlapX = max(0.0, min(source.right, target.right) - max(source.left, target.left));
        final orthoDist = overlapX > 0.0
            ? 0.0
            : max(source.left - target.right, target.left - source.right);
        final alignDist = (target.center.dx - source.center.dx).abs();
        return primaryDist * 4.0 + orthoDist * 1.0 + alignDist * 0.25;

      case TraversalDirection.up:
        final primaryDist = source.top >= target.bottom
            ? source.top - target.bottom
            : max(0.0, source.center.dy - target.center.dy);
        final overlapX = max(0.0, min(source.right, target.right) - max(source.left, target.left));
        final orthoDist = overlapX > 0.0
            ? 0.0
            : max(source.left - target.right, target.left - source.right);
        final alignDist = (target.center.dx - source.center.dx).abs();
        return primaryDist * 4.0 + orthoDist * 1.0 + alignDist * 0.25;

      case TraversalDirection.right:
        final primaryDist = target.left >= source.right
            ? target.left - source.right
            : max(0.0, target.center.dx - source.center.dx);
        final overlapY = max(0.0, min(source.bottom, target.bottom) - max(source.top, target.top));
        final orthoDist = overlapY > 0.0
            ? 0.0
            : max(source.top - target.bottom, target.top - source.bottom);
        final alignDist = (target.center.dy - source.center.dy).abs();
        return primaryDist * 4.0 + orthoDist * 1.0 + alignDist * 0.25;

      case TraversalDirection.left:
        final primaryDist = source.left >= target.right
            ? source.left - target.right
            : max(0.0, source.center.dx - target.center.dx);
        final overlapY = max(0.0, min(source.bottom, target.bottom) - max(source.top, target.top));
        final orthoDist = overlapY > 0.0
            ? 0.0
            : max(source.top - target.bottom, target.top - source.bottom);
        final alignDist = (target.center.dy - source.center.dy).abs();
        return primaryDist * 4.0 + orthoDist * 1.0 + alignDist * 0.25;
    }
  }
}
