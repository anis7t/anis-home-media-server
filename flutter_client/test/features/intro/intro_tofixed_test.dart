import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_frame.dart';

/// JavaScript's `toFixed` is the canonical renderer's rounding, and the
/// Flutter port has to round the same way - the rounding is part of the
/// rendering.
///
/// This is the captured reference: JavaScript's own output for a set of
/// awkward values (ties-adjacent decimals, the tiniest magnitudes, and a
/// spread of random values) at four precisions. It was captured from Node and
/// is the check that `jsToFixed` is faithful.
///
/// The capture lives in `web/_tofixed_capture.mjs`.
const String kReferencePath = '../web/_tofixed_capture.json';

void main() {
  final file = File(kReferencePath);
  if (!file.existsSync()) {
    fail('The toFixed reference is missing: $kReferencePath');
  }
  final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('jsToFixed matches JavaScript toFixed exactly', () {
    var checked = 0;
    for (final entry in raw.entries) {
      final places = int.parse(entry.key);
      for (final row in (entry.value as List).cast<List>()) {
        final v = (row[0] as num).toDouble();
        final expected = row[1] as String;
        final actual = jsToFixed(v, places);
        expect(
          actual.toStringAsFixed(places),
          expected,
          reason: 'v=$v at $places places',
        );
        checked++;
      }
    }
    expect(checked, greaterThan(500));
  });

  test('the rounding is read from the exact value, not a scaled one', () {
    // This is the case that caught the first implementation: multiplying by
    // the scale factor rounds, and a value just below a midpoint can land
    // exactly on it. The canonical's own value is 87.47 here.
    expect(jsToFixed(87.474999999999994316, 2), 87.47);
    expect(jsToFixed(87.475, 2), 87.47);
    expect(jsToFixed(87.47500000000001, 2), 87.48);
  });
}
