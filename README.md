# [![Build Status](https://travis-ci.org/dart-lang/timing.svg?branch=master)](https://travis-ci.org/dart-lang/timing)

Timing is a simple package for tracking performance of both async and sync actions

```dart
var tracker = AsyncTimeTracker();
await tracker.track(() async {
  // some async code here
});

// Use results
print('${tracker.duration} ${tracker.innerDuration} ${tracker.slices}');
```