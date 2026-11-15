import 'package:flutter/material.dart';

import 'common.dart';

/// 30-minute (HIIT) and 1-hour coach sessions.
///
/// A coach session is normally 1 hour. When a member whose package is for
/// 30-minute sessions books a free hour, the database splits it into two
/// halves (hh:00 and hh:30) and books one; the other half stays open. When
/// both halves are free again they are joined back into one hour (db/26).

const halfHour = Duration(minutes: 30);

bool isHalfHour(DateTime start, DateTime end) =>
    end.difference(start).inMinutes == 30;

/// "30 min" for a half-hour session, otherwise empty.
String lengthTag(DateTime start, DateTime end) =>
    isHalfHour(start, end) ? '30 min' : '';

/// Session length (30 or 60) of the member's active credit package; 60 if none.
Future<int> memberSessionMinutes(String memberId) async {
  final r = await db
      .from('member_packages')
      .select('session_minutes')
      .eq('member_id', memberId)
      .eq('status', 'ACTIVE')
      .eq('kind', 'CREDITS')
      .maybeSingle();
  return (r?['session_minutes'] as int?) ?? 60;
}

/// One coach session as a member sees it. [pStart] is set when booking it
/// splits a free hour: it is the start of the half to book (sent to the
/// database as p_start / p_new_start).
class SessionSlot {
  SessionSlot(this.id, this.start, this.end, this.taken, {this.pStart});
  final String id;
  final DateTime start;
  final DateTime end;
  final bool taken;
  final DateTime? pStart;

  bool get isHalf => isHalfHour(start, end);
}

/// Turns the coach's sessions into what a booking of [minutes] can use.
/// - 30: a free hour becomes two bookable halves.
/// - 60: halves (a split hour) cannot be booked; two halves of one hour are
///   shown as one taken hour.
/// Sessions in [keep] (the member's own bookings) are shown unchanged.
List<SessionSlot> sessionChoices(List<SessionSlot> slots, int minutes,
    {Set<String> keep = const {}}) {
  final out = <SessionSlot>[];
  if (minutes == 30) {
    for (final s in slots) {
      if (keep.contains(s.id) || s.isHalf) {
        out.add(s);
      } else {
        final mid = s.start.add(halfHour);
        out.add(SessionSlot(s.id, s.start, mid, s.taken, pStart: s.start));
        out.add(SessionSlot(s.id, mid, s.end, s.taken, pStart: mid));
      }
    }
  } else {
    final halves = <DateTime, List<SessionSlot>>{};
    for (final s in slots) {
      if (keep.contains(s.id) || !s.isHalf) {
        out.add(s);
      } else {
        final h = DateTime(s.start.year, s.start.month, s.start.day, s.start.hour);
        halves.putIfAbsent(h, () => []).add(s);
      }
    }
    for (final e in halves.entries) {
      final hasKeptHalf = slots.any((s) =>
          keep.contains(s.id) &&
          s.isHalf &&
          DateTime(s.start.year, s.start.month, s.start.day, s.start.hour) ==
              e.key);
      if (e.value.length == 2 && !hasKeptHalf) {
        out.add(SessionSlot(e.value.first.id, e.key,
            e.key.add(const Duration(hours: 1)), true));
      } else {
        for (final s in e.value) {
          out.add(SessionSlot(s.id, s.start, s.end, true));
        }
      }
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Coach/admin booking a 30-minute member into a 1-hour session: asks which
/// half. Returns the chosen start, or null if cancelled.
Future<DateTime?> pickHalf(BuildContext context, DateTime start) {
  final mid = start.add(halfHour);
  final end = mid.add(halfHour);
  return showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('30-minute session'),
            subtitle: Text(
                'This member\'s package is for 30-minute sessions. Which half?'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text('${showTime(start)} - ${showTime(mid)}'),
            onTap: () => Navigator.pop(ctx, start),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text('${showTime(mid)} - ${showTime(end)}'),
            onTap: () => Navigator.pop(ctx, mid),
          ),
        ],
      ),
    ),
  );
}
