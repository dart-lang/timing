[![Dart CI](https://github.com/dart-lang/timing/actions/workflows/test-package.yml/badge.svg)](https://github.com/dart-lang/timing/actions/workflows/test-package.yml)
[![pub package](https://img.shields.io/pub/v/timing.svg)](https://pub.dev/packages/timing)
[![package publisher](https://img.shields.io/pub/publisher/timing.svg)](https://pub.dev/packages/timing/publisher)

Timing is a simple package for tracking performance of both async and sync actions

## Feature:
- **Performance Tracking**: Measure execution time for synchronous and asynchronous code.
- **Nested Tracking**: Supports nested tracking for inner code blocks.
- **Exception Handling**: Accurately times code execution with exception support.

## Usage

###  AsyncTimeTracker
### To track async operations:
```dart
var tracker = AsyncTimeTracker();
await tracker.track(() async {
  // some async code here
});

// Use results
print('${tracker.duration} ${tracker.innerDuration} ${tracker.slices}');
```
## SyncTimeTracker
### To track synchronous operations:

```dart
var tracker = SyncTimeTracker();
tracker.track(() {
  // some sync code here
});

// Use results
print('${tracker.duration}');

```

## SimpleAsyncTimeTracker
### To track async operations:

```dart
var tracker = SimpleAsyncTimeTracker();
await tracker.track(() async {
  // some async code here
});

// Use results
print('${tracker.duration}');

```
## TimeSlice
### Represents the timings of an operation, including its start time, stop time, and duration:

```dart
var timeSlice = TimeSlice(DateTime.now(), DateTime.now().add(Duration(seconds: 5)));
print(timeSlice.duration);

```

## TimeSliceGroup
### Represents the timings of an async operation, consisting of several sync slices and including total start time, stop time, and duration:
```dart
var timeSliceGroup = TimeSliceGroup([
  TimeSlice(DateTime.now(), DateTime.now().add(Duration(seconds: 2))),
  TimeSlice(DateTime.now().add(Duration(seconds: 3)), DateTime.now().add(Duration(seconds: 5))),
]);
print(timeSliceGroup.innerDuration);

```

## Building

Use the following command to re-generate `lib/src/timing.g.dart` file:

```bash
dart pub run build_runner build
```

## Publishing automation

For information about our publishing automation and release process, see
https://github.com/dart-lang/ecosystem/wiki/Publishing-automation.
