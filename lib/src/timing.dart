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
  Duration get duration => stopTime?.difference(startTime);

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
  Duration get duration => stopTime?.difference(startTime);

  /// Sum of [duration]s of all [slices].
  ///
  /// If some of slices implements [TimeSliceGroup] [innerDuration] will be used
  /// to compute sum.
  Duration get innerDuration => slices.fold(
      Duration.zero,
      (duration, slice) =>
          duration +
          (slice is TimeSliceGroup ? slice.innerDuration : slice.duration));

  TimeSliceGroup([List<TimeSlice> slices]) : slices = slices ?? [];

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

  R track<T, R extends FutureOr<T>>(R Function() action);
}

abstract class SyncTimeTracker implements TimeTracker {
  factory SyncTimeTracker() => SyncTimeTrackerImpl();

  factory SyncTimeTracker.noOp() => NoOpSyncTimeTracker.sharedInstance;
}

/// Implementation of a real [SyncTimeTracker].
///
/// Use [SyncTimeTracker] factory to get an instance.
class SyncTimeTrackerImpl implements TimeSlice, SyncTimeTracker {
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
    assert(_startTime == null && _stopTime == null);
    _startTime = now();
  }

  /// Stop tracking this operation, must only be called once, after [start].
  void stop() {
    assert(_startTime != null && _stopTime == null);
    _stopTime = now();
  }

  TimeSlice splitNow() {
    if (!isTracking) {
      throw StateError('Can be only called while tracking');
    }
    var _now = now();
    var prevSlice = TimeSlice(_startTime, _now);
    _startTime = _now;
    return prevSlice;
  }

  @override
  R track<T, R extends FutureOr<T>>(R Function() action) {
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

/// Implementation of [SyncTimeTracker] that can handle async actions
///
/// Async actions returning [Future] will be tracked as single sync time span
/// from the beginning of execution till completion of future
///
/// Use [AsyncTimeTracker.simple] factory to get an instance.
class SimpleAsyncTimeTrackerImpl extends TimeSliceGroup
    implements AsyncTimeTracker {
  @override
  R track<T, R extends FutureOr<T>>(R Function() action) {
    if (isStarted) {
      throw StateError('Can not be tracked twice');
    }
    R result;
    var tracker = SyncTimeTrackerImpl();
    slices.add(tracker);
    tracker.start();
    try {
      result = action();
    } catch (_) {
      tracker.stop();
      rethrow;
    }
    if (result is Future<T>) {
      return result.whenComplete(tracker.stop) as R;
    } else {
      tracker.stop();
      return result;
    }
  }

  @override
  bool get isStarted => slices.isNotEmpty;

  @override
  bool get isTracking =>
      slices.isNotEmpty && (slices.first as SyncTimeTracker).isTracking;

  @override
  bool get isFinished =>
      slices.isNotEmpty && (slices.first as SyncTimeTracker).isFinished;
}

/// No-op implementation of [SyncTimeTracker] that does nothing.
///
/// Use [SyncTimeTracker.noOp] factory to get an instance.
class NoOpSyncTimeTracker implements SyncTimeTracker {
  static final sharedInstance = NoOpSyncTimeTracker();

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
  R track<T, R extends FutureOr<T>>(R Function() action) => action();
}

abstract class AsyncTimeTracker implements TimeSliceGroup, TimeTracker {
  factory AsyncTimeTracker({bool trackNested = true}) =>
      AsyncTimeTrackerImpl(trackNested);

  factory AsyncTimeTracker.simple() => SimpleAsyncTimeTrackerImpl();

  factory AsyncTimeTracker.noOp() => NoOpAsyncTimeTracker.sharedInstance;
}

/// Implementation of a real [AsyncTimeTracker].
///
/// Use [AsyncTimeTracker] factory to get an instance.
class AsyncTimeTrackerImpl extends TimeSliceGroup implements AsyncTimeTracker {
  final bool trackNested;

  AsyncTimeTrackerImpl(this.trackNested);

  T _trackSyncSlice<T>(ZoneDelegate parent, Zone zone, T Function() action) {
    // Ignore dangling runs after tracker completes
    if (isFinished) {
      return action();
    }

    var isNestedRun = slices.isNotEmpty &&
        slices.last is SyncTimeTracker &&
        (slices.last as SyncTimeTracker).isTracking;
    var isExcludedNestedTrack =
        !trackNested && zone[AsyncTimeTrackerImpl] != this;

    // Exclude nested sync tracks
    if (isNestedRun && isExcludedNestedTrack) {
      var timer = slices.last as SyncTimeTrackerImpl;
      slices.last = parent.run(zone, timer.splitNow);
      try {
        return action();
      } finally {
        parent.run(zone, timer.splitNow); // discard
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
      var tracker = self[AsyncTimeTrackerImpl] as AsyncTimeTrackerImpl;
      return tracker._trackSyncSlice(parent, zone, () => parent.run(zone, f));
    },
    runUnary: <R, T>(Zone self, ZoneDelegate parent, Zone zone, R Function(T) f,
        T arg) {
      var tracker = self[AsyncTimeTrackerImpl] as AsyncTimeTrackerImpl;
      return tracker._trackSyncSlice(
          parent, zone, () => parent.runUnary(zone, f, arg));
    },
    runBinary: <R, T1, T2>(Zone self, ZoneDelegate parent, Zone zone,
        R Function(T1, T2) f, T1 arg1, T2 arg2) {
      var tracker = self[AsyncTimeTrackerImpl] as AsyncTimeTrackerImpl;
      return tracker._trackSyncSlice(
          parent, zone, () => parent.runBinary(zone, f, arg1, arg2));
    },
  );

  @override
  R track<T, R extends FutureOr<T>>(R Function() action) {
    if (isStarted) {
      throw StateError('Can not be tracked twice');
    }
    _tracking = true;
    var result = runZoned(action,
        zoneSpecification: asyncTimeTrackerZoneSpecification,
        zoneValues: {AsyncTimeTrackerImpl: this});
    if (result is Future<T>) {
      return result
          // Break possible sync processing of future completion, so slice trackers can be finished
          .whenComplete(() => Future.value())
          .whenComplete(() => _tracking = false) as R;
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

/// No-op implementation of [AsyncTimeTracker] that does nothing.
///
/// Use [AsyncTimeTracker.noOp] factory to get an instance.
class NoOpAsyncTimeTracker implements AsyncTimeTracker {
  static final sharedInstance = NoOpAsyncTimeTracker();

  @override
  Duration get duration =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  Duration get innerDuration =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  DateTime get startTime =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  DateTime get stopTime =>
      throw UnsupportedError('Unsupported in no-op implementation');

  @override
  List<TimeSlice> get slices =>
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
  R track<T, R extends FutureOr<T>>(R Function() action) => action();
}
