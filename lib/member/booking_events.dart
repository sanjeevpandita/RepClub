import 'package:flutter/foundation.dart';

/// Bumped after a member books, moves or cancels, so the other Book tabs
/// (My calendar, Coach sessions, Coach week, Gym time) reload their data.
final bookingsChanged = ValueNotifier<int>(0);

void notifyBookingsChanged() => bookingsChanged.value++;
