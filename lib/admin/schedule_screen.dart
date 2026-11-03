import 'package:flutter/material.dart';

import '../shared/common.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Grid of weekdays x hours. Tapping a cell switches that hour on or off for
/// the coach and saves straight away.
class WeeklyScheduleScreen extends StatefulWidget {
  const WeeklyScheduleScreen(
      {super.key, required this.coachId, required this.coachName});
  final String coachId;
  final String coachName;

  @override
  State<WeeklyScheduleScreen> createState() => _WeeklyScheduleScreenState();
}

class _WeeklyScheduleScreenState extends State<WeeklyScheduleScreen> {
  final Set<(int, int)> _on = {}; // (weekday 1-7, hour)
  int _openHour = 6;
  int _closeHour = 20;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await db
          .from('app_settings')
          .select('open_time, close_time')
          .single();
      final rows = await db
          .from('coach_weekly_schedule')
          .select('weekday, hour')
          .eq('coach_id', widget.coachId);
      if (!mounted) return;
      setState(() {
        _openHour = int.parse((s['open_time'] as String).split(':').first);
        _closeHour = int.parse((s['close_time'] as String).split(':').first);
        _on
          ..clear()
          ..addAll([for (final r in rows) (r['weekday'] as int, r['hour'] as int)]);
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load the schedule.');
    }
  }

  Future<void> _toggle(int weekday, int hour) async {
    final key = (weekday, hour);
    final turnOn = !_on.contains(key);
    setState(() => turnOn ? _on.add(key) : _on.remove(key));
    final ok = await attempt(context, () async {
      if (turnOn) {
        await db.from('coach_weekly_schedule').insert(
            {'coach_id': widget.coachId, 'weekday': weekday, 'hour': hour});
      } else {
        await db
            .from('coach_weekly_schedule')
            .delete()
            .eq('coach_id', widget.coachId)
            .eq('weekday', weekday)
            .eq('hour', hour);
      }
    });
    if (!ok && mounted) {
      setState(() => turnOn ? _on.remove(key) : _on.add(key));
    }
  }

  void _setDay(int weekday, bool on) async {
    for (var h = _openHour; h < _closeHour; h++) {
      if (_on.contains((weekday, h)) != on) await _toggle(weekday, h);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.coachName} - weekly hours')),
      body: !_loaded
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  'Tap an hour to switch it on or off. Changes save straight '
                  'away. Then use Calendar > Generate sessions to create the '
                  'sessions.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 48),
                  for (var d = 1; d <= 7; d++)
                    Expanded(
                      child: Center(
                        child: Text(_days[d - 1],
                            style: theme.textTheme.labelMedium),
                      ),
                    ),
                ]),
                const SizedBox(height: 4),
                for (var h = _openHour; h < _closeHour; h++)
                  Row(children: [
                    SizedBox(
                      width: 48,
                      child: Text('${two(h)}:00',
                          style: theme.textTheme.labelMedium),
                    ),
                    for (var d = 1; d <= 7; d++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _toggle(d, h),
                            child: Container(
                              height: 34,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: _on.contains((d, h))
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.surfaceContainerHigh,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ]),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      ActionChip(
                        label: Text('${_days[d - 1]} all'),
                        onPressed: () => _setDay(d, true),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      ActionChip(
                        label: Text('${_days[d - 1]} clear'),
                        onPressed: () => _setDay(d, false),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
