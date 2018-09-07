// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'clock.dart';

/// The timings of an operation, including its [startTime], [stopTime], and
/// [duration].
class TimeSlice {
  /// The total duration of this operation, equivalent to taking the difference
  /// between [stopTime] and [startTime].
  Duration get duration => stopTime.difference(startTime);

  final DateTime startTime;

  final DateTime stopTime;

  TimeSlice(this.startTime, this.stopTime);

  @override
  String toString() => '($startTime + $duration)';
}

/// The timings of an async operation, consist of several sync [slices] and
/// includes total [startTime], [stopTime], and [duration].
class TimeSliceGroup implements TimeSlice {
  final List<TimeSlice> slices;

  @override
  DateTime get startTime => slices.first.startTime;

  @override
  DateTime get stopTime => slices.last.stopTime;

  /// The total duration of this operation, equivalent to taking the difference
  /// between [stopTime] and [startTime].
  @override
  Duration get duration => stopTime.difference(startTime);

  /// Sum of [duration]s of all [slices].
  ///
  /// If some of slices implements [TimeSliceGroup] [innerDuration] will be used
  /// to compute sum.
  Duration get innerDuration => slices.fold(
      Duration.zero,
      (duration, slice) =>
          duration +
          (slice is TimeSliceGroup ? slice.innerDuration : slice.duration));

  TimeSliceGroup(List<TimeSlice> this.slices);

  @override
  String toString() => slices.toString();
}

abstract class TimeTracker implements TimeSlice {
  /// Whether tracking is active.
  ///
  /// Tracking is only active after `isStarted` and before `isFinished`.
  bool get isTracking;

  /// Whether tracking is finished.
  ///
  /// Tracker can't be used as [TimeSlice] before it is finished
  bool get isFinished;

  /// Whether tracking was started.
  ///
  /// Equivalent of `isTracking || isFinished`
  bool get isStarted;

  T track<T>(T Function() action);
}

/// Tracks only sync actions
class SyncTimeTracker implements TimeTracker {
  /// When this operation started, call [start] to set this.
  @override
  DateTime get startTime => _startTime;
  DateTime _startTime;

  /// When this operation stopped, call [stop] to set this.
  @override
  DateTime get stopTime => _stopTime;
  DateTime _stopTime;

  /// Start tracking this operation, must only be called once, before [stop].
  void start() {
    if (isStarted) {
      throw StateError('Can not be started twice');
    }
    _startTime = now();
  }

  /// Stop tracking this operation, must only be called once, after [start].
  void stop() {
    if (!isTracking) {
      throw StateError('Can be only called while tracking');
    }
    _stopTime = now();
  }

  /// Splits tracker into two slices
  ///
  /// Returns new [TimeSlice] started on [startTime] and ended now.
  /// Modifies [startTime] of tracker to current time point
  ///
  /// Don't change state of tracker. Can be called only while [isTracking], and
  /// tracker will sill be tracking after call.
  TimeSlice split() {
    if (!isTracking) {
      throw StateError('Can be only called while tracking');
    }
    var _now = now();
    var prevSlice = TimeSlice(_startTime, _now);
    _startTime = _now;
    return prevSlice;
  }

  @override
  T track<T>(T Function() action) {
    if (isStarted) {
      throw StateError('Can not be tracked twice');
    }
    start();
    try {
      return action();
    } finally {
      stop();
    }
  }

  @override
  bool get isStarted => startTime != null;

  @override
  bool get isTracking => startTime != null && stopTime == null;

  @override
  bool get isFinished => startTime != null && stopTime != null;

  @override
  Duration get duration => stopTime?.difference(startTime);
}

/// Async actions returning [Future] will be tracked as single sync time span
/// from the beginning of execution till completion of future
class SimpleAsyncTimeTracker extends SyncTimeTracker {
  @override
  T track<T>(T Function() action) {
    if (isStarted) {
      throw StateError('Can not be tracked twice');
    }
    T result;
    start();
    try {
      result = action();
    } catch (_) {
      stop();
      rethrow;
    }
    if (result is Future) {
      return result.whenComplete(stop) as T;
    } else {
      stop();
      return result;
    }
  }
}

/// No-op implementation of [SyncTimeTracker] that does nothing.
class NoOpTimeTracker implements TimeTracker {
  static final sharedInstance = NoOpTimeTracker();

  @override
  Duration get duration =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  DateTime get startTime =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  DateTime get stopTime =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  bool get isStarted =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  bool get isTracking =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  bool get isFinished =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  T track<T>(T Function() action) => action();
}

/// Track all async execution as disjoint time [slices] in ascending order.
///
/// Can [track] both async and sync actions.
/// Can exclude time of tested trackers.
///
/// If tracked action spawns some dangled async executions behavior is't
/// defined. Tracked might or might not track time of such executions
class AsyncTimeTracker extends TimeSliceGroup implements TimeTracker {
  final bool trackNested;

  static const _ZoneKey = #timing_AsyncTimeTracker;

  AsyncTimeTracker({this.trackNested = true}) : super([]);

  T _trackSyncSlice<T>(ZoneDelegate parent, Zone zone, T Function() action) {
    // Ignore dangling runs after tracker completes
    if (isFinished) {
      return action();
    }

    var isNestedRun = slices.isNotEmpty &&
        slices.last is SyncTimeTracker &&
        (slices.last as SyncTimeTracker).isTracking;
    var isExcludedNestedTrack = !trackNested && zone[_ZoneKey] != this;

    // Exclude nested sync tracks
    if (isNestedRun && isExcludedNestedTrack) {
      var timer = slices.last as SyncTimeTracker;
      // Split already tracked time into new slice.
      // Replace tracker in slices.last with splitted slice, to indicate for
      // recursive calls that we not tracking.
      slices.last = parent.run(zone, timer.split);
      try {
        return action();
      } finally {
        // Split tracker again and discard slice that was spend in nested tracker
        parent.run(zone, timer.split);
        // Add tracker back to list of slices and continue tracking
        slices.add(timer);
      }
    }

    // Exclude nested async tracks
    if (isExcludedNestedTrack) {
      return action();
    }

    // Split time slices in nested sync runs
    if (isNestedRun) {
      return action();
    }

    var timer = SyncTimeTracker();
    slices.add(timer);

    // Pass to parent zone, in case of overwritten clock
    return parent.runUnary(zone, timer.track, action);
  }

  static final asyncTimeTrackerZoneSpecification = ZoneSpecification(
    run: <R>(Zone self, ZoneDelegate parent, Zone zone, R Function() f) {
      var tracker = self[_ZoneKey] as AsyncTimeTracker;
      return tracker._trackSyncSlice(parent, zone, () => parent.run(zone, f));
    },
    runUnary: <R, T>(Zone self, ZoneDelegate parent, Zone zone, R Function(T) f,
        T arg) {
      var tracker = self[_ZoneKey] as AsyncTimeTracker;
      return tracker._trackSyncSlice(
          parent, zone, () => parent.runUnary(zone, f, arg));
    },
    runBinary: <R, T1, T2>(Zone self, ZoneDelegate parent, Zone zone,
        R Function(T1, T2) f, T1 arg1, T2 arg2) {
      var tracker = self[_ZoneKey] as AsyncTimeTracker;
      return tracker._trackSyncSlice(
          parent, zone, () => parent.runBinary(zone, f, arg1, arg2));
    },
  );

  @override
  T track<T>(T Function() action) {
    if (isStarted) {
      throw StateError('Can not be tracked twice');
    }
    _tracking = true;
    var result = runZoned(action,
        zoneSpecification: asyncTimeTrackerZoneSpecification,
        zoneValues: {_ZoneKey: this});
    if (result is Future) {
      return result
          // Break possible sync processing of future completion, so slice trackers can be finished
          .whenComplete(() => Future.value())
          .whenComplete(() => _tracking = false) as T;
    } else {
      _tracking = false;
      return result;
    }
  }

  bool _tracking;

  @override
  bool get isStarted => _tracking != null;

  @override
  bool get isFinished => _tracking == false;

  @override
  bool get isTracking => _tracking == true;
}
