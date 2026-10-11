"""Phase 3.3 regression tests: PostgreSQL TIMESTAMPTZ vs SQLite timestamp strings.

Background
----------
SQLite's ``DATETIME`` + ``CURRENT_TIMESTAMP`` yields ``'YYYY-MM-DD HH:MM:SS'``
(a naive string that is really UTC). psycopg returns ``datetime.datetime`` for
PostgreSQL ``TIMESTAMPTZ``. Application code sorted, sliced, formatted and
JSON-serialized those values as strings, so on PostgreSQL it would:

* raise ``TypeError`` sorting a mix of ``''`` and ``datetime`` (home page / API),
* silently mark every device inactive (string parsing of ``last_seen`` failed),
* emit RFC-822 timestamps (``Sat, 10 Oct 2026 01:58:09 GMT``) in JSON instead of
  the established format, and
* break ``dev.last_seen[:19]`` in ``templates/devices.html``.

These tests pin the normalization boundary so both backends behave identically.
Times are fixed - no assertions depend on the developer's wall clock.
"""
import datetime as dt
import json
import unittest
from unittest.mock import patch

from app.services.device_service import format_time_ago
from app.utils.formatting import (
    DB_TIMESTAMP_FORMAT,
    format_db_timestamp,
    parse_db_timestamp,
)

UTC = dt.timezone.utc

# A fixed "now" so relative-time assertions are exact.
FIXED_NOW = dt.datetime(2026, 10, 10, 12, 0, 0, tzinfo=UTC)

SQLITE_TS = "2026-10-10 01:58:09"
PG_AWARE = dt.datetime(2026, 10, 10, 1, 58, 9, tzinfo=UTC)
PG_NAIVE = dt.datetime(2026, 10, 10, 1, 58, 9)
PG_OFFSET = dt.datetime(2026, 10, 10, 7, 28, 9, tzinfo=dt.timezone(dt.timedelta(hours=5, minutes=30)))

ALL_EQUIVALENT = [
    ("sqlite string", SQLITE_TS),
    ("pg aware", PG_AWARE),
    ("pg naive", PG_NAIVE),
    ("pg +05:30 offset", PG_OFFSET),
    ("iso T", "2026-10-10T01:58:09"),
    ("iso T + Z", "2026-10-10T01:58:09Z"),
    ("fractional seconds", "2026-10-10 01:58:09.123456"),
]


class _FixedNowDatetime(dt.datetime):
    """datetime whose now() is frozen at FIXED_NOW."""

    @classmethod
    def now(cls, tz=None):
        return FIXED_NOW if tz else FIXED_NOW.replace(tzinfo=None)


class TestParseDbTimestamp(unittest.TestCase):
    """Parsing: every representation of the same instant must agree."""

    def test_all_representations_parse_to_the_same_utc_instant(self):
        for label, value in ALL_EQUIVALENT:
            with self.subTest(label):
                parsed = parse_db_timestamp(value)
                self.assertIsNotNone(parsed, label)
                self.assertEqual(parsed.tzinfo, UTC)
                # Sub-second precision is irrelevant to the stored contract.
                self.assertEqual(
                    parsed.replace(microsecond=0), PG_AWARE, f"{label}: {parsed}"
                )

    def test_fractional_seconds_are_preserved_when_parsing(self):
        parsed = parse_db_timestamp("2026-10-10 01:58:09.123456")
        self.assertEqual(parsed.microsecond, 123456)

    def test_aware_non_utc_offset_is_converted_not_dropped(self):
        """+05:30 07:28:09 is 01:58:09 UTC - the offset must be applied."""
        self.assertEqual(parse_db_timestamp(PG_OFFSET).hour, 1)
        self.assertEqual(parse_db_timestamp(PG_OFFSET).minute, 58)

    def test_naive_datetime_is_interpreted_as_utc(self):
        """Naive values mean UTC (SQLite CURRENT_TIMESTAMP), never local time."""
        self.assertEqual(parse_db_timestamp(PG_NAIVE), PG_AWARE)
        self.assertEqual(parse_db_timestamp(PG_NAIVE).tzinfo, UTC)

    def test_none_and_unusable_values_return_none(self):
        for value in (None, "", "   ", "not-a-timestamp", True, 12345, object()):
            with self.subTest(repr(value)):
                self.assertIsNone(parse_db_timestamp(value))

    def test_date_object_is_midnight_utc(self):
        parsed = parse_db_timestamp(dt.date(2026, 10, 10))
        self.assertEqual(parsed, dt.datetime(2026, 10, 10, tzinfo=UTC))

    def test_parse_is_idempotent_on_its_own_output(self):
        once = parse_db_timestamp(PG_AWARE)
        self.assertEqual(parse_db_timestamp(once), once)


class TestFormatDbTimestamp(unittest.TestCase):
    """Formatting: output must equal what SQLite has always produced."""

    def test_every_input_renders_the_sqlite_contract_string(self):
        for label, value in ALL_EQUIVALENT:
            with self.subTest(label):
                self.assertEqual(format_db_timestamp(value), SQLITE_TS)

    def test_output_matches_the_declared_format(self):
        self.assertEqual(
            dt.datetime.strptime(format_db_timestamp(PG_AWARE), DB_TIMESTAMP_FORMAT),
            PG_NAIVE,
        )

    def test_none_and_garbage_use_the_default(self):
        self.assertEqual(format_db_timestamp(None), "")
        self.assertEqual(format_db_timestamp("garbage"), "")
        self.assertEqual(format_db_timestamp(None, default="-"), "-")

    def test_output_is_a_string_so_templates_can_slice_it(self):
        """templates/devices.html does dev.last_seen[:19]."""
        rendered = format_db_timestamp(PG_AWARE)
        self.assertIsInstance(rendered, str)
        self.assertEqual(rendered[:19], SQLITE_TS)

    def test_output_is_json_serializable_as_a_plain_string(self):
        """Flask would otherwise emit RFC-822 for a raw datetime."""
        payload = json.loads(json.dumps({"last_seen": format_db_timestamp(PG_AWARE)}))
        self.assertEqual(payload["last_seen"], SQLITE_TS)
        # Contrast: the un-normalized value Flask serializes differently.
        from flask import Flask
        app = Flask(__name__)
        with app.app_context():
            raw = json.loads(app.json.dumps({"last_seen": PG_AWARE}))
        self.assertNotEqual(raw["last_seen"], SQLITE_TS)


class TestFormatTimeAgo(unittest.TestCase):
    """Relative-time formatting accepts both backends' shapes."""

    def _ago(self, value):
        with patch("app.services.device_service.datetime", _FixedNowDatetime):
            return format_time_ago(value)

    def test_returns_relative_string_for_every_shape(self):
        for label, value in ALL_EQUIVALENT:
            with self.subTest(label):
                result = self._ago(value)
                self.assertIsInstance(result, str, label)

    def test_exact_relative_buckets(self):
        cases = [
            (dt.datetime(2026, 10, 10, 11, 59, 30, tzinfo=UTC), "Just now"),
            (dt.datetime(2026, 10, 10, 11, 30, 0, tzinfo=UTC), "30m ago"),
            (dt.datetime(2026, 10, 10, 9, 0, 0, tzinfo=UTC), "3h ago"),
            (dt.datetime(2026, 10, 7, 12, 0, 0, tzinfo=UTC), "3d ago"),
        ]
        for value, expected in cases:
            with self.subTest(expected):
                self.assertEqual(self._ago(value), expected)

    def test_sqlite_and_postgres_shapes_agree(self):
        self.assertEqual(self._ago(SQLITE_TS), self._ago(PG_AWARE))
        self.assertEqual(self._ago(SQLITE_TS), self._ago(PG_NAIVE))
        self.assertEqual(self._ago(SQLITE_TS), self._ago(PG_OFFSET))

    def test_none_is_unknown(self):
        self.assertEqual(self._ago(None), "Unknown")

    def test_unparseable_value_is_returned_unchanged(self):
        """Preserves the historical 'return the raw value' fallback."""
        self.assertEqual(self._ago("not-a-timestamp"), "not-a-timestamp")

    def test_future_timestamps_do_not_produce_negative_ages(self):
        future = dt.datetime(2026, 10, 10, 13, 0, 0, tzinfo=UTC)
        self.assertEqual(self._ago(future), "Just now")


class TestSortingAndOrdering(unittest.TestCase):
    """Ordering paths in pages.py / api.py must survive both backends."""

    def test_mixed_string_and_datetime_sort_without_typeerror(self):
        """The exact pages.py/api.py failure mode."""
        raw = ["", PG_AWARE, SQLITE_TS]
        rows = [{"updated_at": format_db_timestamp(v, default="")} for v in raw]
        # Sanity: the un-normalized mix is what raised TypeError before the fix.
        with self.assertRaises(TypeError):
            sorted(raw, key=lambda v: v or "")
        rows.sort(key=lambda m: m["updated_at"])
        self.assertEqual(
            [r["updated_at"] for r in rows],
            ["", "2026-10-10 01:58:09", "2026-10-10 01:58:09"],
        )

    def test_newest_first_ordering_is_preserved(self):
        stamps = [
            dt.datetime(2026, 10, 9, tzinfo=UTC),
            dt.datetime(2026, 10, 11, tzinfo=UTC),
            dt.datetime(2026, 10, 10, tzinfo=UTC),
        ]
        ordered = sorted(stamps, key=format_db_timestamp, reverse=True)
        self.assertEqual(
            [format_db_timestamp(s) for s in ordered],
            ["2026-10-11 00:00:00", "2026-10-10 00:00:00", "2026-10-09 00:00:00"],
        )

    def test_watch_history_ordering_is_identical_across_shapes(self):
        """device_watch_history.last_watched feeds 'recent watch' ordering."""
        from_sqlite = sorted(
            ["2026-10-10 01:58:09", "2026-10-11 01:58:09"], reverse=True
        )
        from_postgres = sorted(
            [
                format_db_timestamp(dt.datetime(2026, 10, 10, 1, 58, 9, tzinfo=UTC)),
                format_db_timestamp(dt.datetime(2026, 10, 11, 1, 58, 9, tzinfo=UTC)),
            ],
            reverse=True,
        )
        self.assertEqual(from_sqlite, from_postgres)

    def test_progress_ordering_equivalent(self):
        """progress.updated_at feeds 'continue watching' ordering."""
        self.assertEqual(
            format_db_timestamp(PG_AWARE), format_db_timestamp(SQLITE_TS)
        )


class TestActiveDeviceWindow(unittest.TestCase):
    """get_all_devices()'s 180s activity window must work for both shapes."""

    def _is_active(self, value):
        with patch("app.services.device_service.datetime", _FixedNowDatetime):
            parsed = parse_db_timestamp(value)
            if parsed is None:
                return False
            return max(0.0, (FIXED_NOW - parsed).total_seconds()) <= 180

    def test_recent_device_is_active_for_both_shapes(self):
        recent = FIXED_NOW - dt.timedelta(seconds=30)
        self.assertTrue(self._is_active(format_db_timestamp(recent)))
        self.assertTrue(
            self._is_active(dt.datetime(2026, 10, 10, 11, 59, 30, tzinfo=UTC))
        )

    def test_stale_device_is_inactive_for_both_shapes(self):
        stale = FIXED_NOW - dt.timedelta(minutes=10)
        self.assertFalse(self._is_active(stale.replace(tzinfo=None)))
        self.assertFalse(
            self._is_active(dt.datetime(2026, 10, 10, 11, 50, 0, tzinfo=UTC))
        )

    def test_unparseable_is_inactive_not_active(self):
        """Previously any parse error silently meant 'inactive' for every PG row."""
        self.assertFalse(self._is_active(None))


if __name__ == "__main__":
    unittest.main()