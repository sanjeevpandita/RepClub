import 'package:flutter/material.dart';

import '../shared/common.dart';
import '../shared/evaluation.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const _bookingLabels = {
  'BOOKED': 'Booked',
  'ATTENDED': 'Attended',
  'NO_SHOW': 'No-show',
  'CANCELLED': 'Cancelled',
};

const _txnLabels = {
  'PACKAGE_START': 'Package credits added',
  'CHECK_IN': 'Session attended',
  'NO_SHOW': 'No-show',
  'ADMIN_ADJUSTMENT': 'Adjustment by gym',
  'REVERSAL': 'Credit returned',
};

const _packageLabels = {
  'ACTIVE': 'Active',
  'QUEUED': 'Waiting to start',
  'COMPLETED': 'Completed',
  'EXPIRED': 'Expired',
  'CANCELLED': 'Cancelled',
};

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Sessions'),
            Tab(text: 'Credits'),
            Tab(text: 'Packages'),
            Tab(text: 'Evaluations'),
          ]),
        ),
        body: const TabBarView(children: [
          _SessionsTab(),
          _CreditsTab(),
          _PackagesTab(),
          _EvaluationsTab(),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------- evaluations

class _EvaluationsTab extends StatelessWidget {
  const _EvaluationsTab();

  @override
  Widget build(BuildContext context) {
    return Loader<({List<Map<String, dynamic>> rows, Map<String, String> names})>(
      load: () async {
        final rows = await loadEvaluations(db.auth.currentUser!.id);
        final names = await nameMap([
          for (final r in rows)
            if (r['coach_id'] != null) r['coach_id'] as String
        ]);
        return (rows: rows, names: names);
      },
      builder: (context, d, reload) =>
          EvaluationList(rows: d.rows, names: d.names),
    );
  }
}

// ---------------------------------------------------------------- sessions

class _SessionsTab extends StatelessWidget {
  const _SessionsTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final uid = db.auth.currentUser!.id;
        final rows = await db
            .from('bookings')
            .select('id, status, slots!inner(starts_at, ends_at)')
            .eq('member_id', uid)
            .limit(300) as List;
        final now = DateTime.now();
        final list = rows.cast<Map<String, dynamic>>().where((b) {
          final end = DateTime.parse(b['slots']['ends_at'] as String);
          return b['status'] != 'BOOKED' || end.isBefore(now);
        }).toList()
          ..sort((a, b) => (b['slots']['starts_at'] as String)
              .compareTo(a['slots']['starts_at'] as String));
        return list;
      },
      builder: (context, list, reload) {
        if (list.isEmpty) {
          return ListView(children: const [
            SizedBox(height: 80),
            Center(child: Text('No past sessions yet')),
          ]);
        }
        final theme = Theme.of(context);
        return ListView(
          children: [
            for (final b in list)
              Builder(builder: (context) {
                final s = DateTime.parse(b['slots']['starts_at'] as String)
                    .toLocal();
                final e =
                    DateTime.parse(b['slots']['ends_at'] as String).toLocal();
                final status = b['status'] as String;
                final good = status == 'ATTENDED';
                final bad = status == 'NO_SHOW';
                return ListTile(
                  leading: Icon(
                    good
                        ? Icons.check_circle
                        : bad
                            ? Icons.cancel
                            : Icons.remove_circle_outline,
                    color: good
                        ? theme.colorScheme.primary
                        : bad
                            ? theme.colorScheme.error
                            : null,
                  ),
                  title: Text(
                      '${_weekdays[s.weekday - 1]} ${showDate(s)}, ${showTime(s)}-${showTime(e)}'),
                  subtitle: Text(_bookingLabels[status] ??
                      (status == 'BOOKED' ? 'Booked' : status)),
                );
              }),
          ],
        );
      },
    );
  }
}

// ----------------------------------------------------------------- credits

class _CreditsTab extends StatelessWidget {
  const _CreditsTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final uid = db.auth.currentUser!.id;
        final rows = (await db
                .from('credit_transactions')
                .select(
                    'id, member_package_id, type, delta, reason_code, note, is_void, created_at')
                .eq('member_id', uid)
                .order('created_at')
                .order('id') as List)
            .cast<Map<String, dynamic>>();
        // Running balance per package, oldest first.
        final run = <String, int>{};
        final out = <Map<String, dynamic>>[];
        for (final r in rows) {
          final p = r['member_package_id'] as String;
          run[p] = (run[p] ?? 0) + (r['delta'] as int);
          out.add({...r, 'balance': run[p]});
        }
        return out.reversed.toList();
      },
      builder: (context, list, reload) {
        if (list.isEmpty) {
          return ListView(children: const [
            SizedBox(height: 80),
            Center(child: Text('No credit changes yet')),
          ]);
        }
        final theme = Theme.of(context);
        return ListView(
          children: [
            for (final t in list)
              ListTile(
                title: Text(
                  _txnLabels[t['type']] ?? '${t['type']}',
                  style: t['is_void'] == true
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                ),
                subtitle: Text([
                  showStamp(t['created_at'] as String),
                  if (t['reason_code'] != null)
                    reasonLabels[t['reason_code']] ?? t['reason_code'],
                  if ((t['note'] as String?)?.isNotEmpty == true) t['note'],
                ].join(' - ')),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      (t['delta'] as int) > 0 ? '+${t['delta']}' : '${t['delta']}',
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: (t['delta'] as int) > 0
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error),
                    ),
                    Text('Balance ${t['balance']}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- packages

class _PackagesTab extends StatelessWidget {
  const _PackagesTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final uid = db.auth.currentUser!.id;
        final pk = (await db
                .from('member_packages')
                .select(
                    'id, package_name, status, start_date, expiry_date, starting_credits')
                .eq('member_id', uid)
                .order('start_date', ascending: false) as List)
            .cast<Map<String, dynamic>>();
        final bal = await db
            .from('member_package_balances')
            .select('member_package_id, credits_remaining')
            .eq('member_id', uid) as List;
        final left = {
          for (final b in bal)
            b['member_package_id'] as String: b['credits_remaining'] as int
        };
        return [
          for (final p in pk) {...p, 'left': left[p['id']] ?? 0}
        ];
      },
      builder: (context, list, reload) {
        if (list.isEmpty) {
          return ListView(children: const [
            SizedBox(height: 80),
            Center(child: Text('No packages yet')),
          ]);
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final p in list)
              Card(
                child: ListTile(
                  title: Text(p['package_name'] as String),
                  subtitle: Text(
                      '${_packageLabels[p['status']] ?? p['status']}\n'
                      '${showIso(p['start_date'])} to ${showIso(p['expiry_date'])}'),
                  isThreeLine: true,
                  trailing: Text('${p['left']} / ${p['starting_credits']}\ncredits',
                      textAlign: TextAlign.right),
                ),
              ),
          ],
        );
      },
    );
  }
}
