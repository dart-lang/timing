import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:timing/timing.dart';

final _argParser = ArgParser()
  ..addMultiOption('builder-key',
      help: 'The builder key you want to search for.')
  ..addMultiOption('action-label', help: 'Action label to filter for.');

void main(List<String> args) async {
  final parsed = _argParser.parse(args);
  final trailing = parsed.rest;
  if (trailing.length != 1) {
    throw ArgumentError(
        'Expected exactly one trailing argument, a path to a log file to read'
        ', but got $trailing');
  }
  final content = await File(trailing.first).readAsString();
  final json = jsonDecode(content) as Map<String, dynamic>;
  final actions = List<Map<String, dynamic>>.from(json['actions'] as List);
  final builderKeys = parsed['builder-key'] as List<String>;
  if (builderKeys.isEmpty) {
    throw ArgumentError('At least one --builder-key is required');
  }

  final actionLabels = parsed['action-label'] as List<String>;
  if (actionLabels.isEmpty) {
    throw ArgumentError('At least one --action-label is required');
  }

  final timingsByKeyAndLabel = <String, Map<String, List<TimeSlice>>>{};
  for (final action in actions) {
    final builderKey = action['builderKey'] as String;
    if (!builderKeys.contains(builderKey)) continue;
    final timingsByLabel = timingsByKeyAndLabel.putIfAbsent(
        builderKey, () => <String, List<TimeSlice>>{});
    final stages = List<Map<String, dynamic>>.from(action['stages'] as List);
    for (final stage in stages) {
      final label = stage['label'] as String;
      if (!actionLabels.contains(label)) continue;
      timingsByLabel.putIfAbsent(label, () => <TimeSlice>[]).addAll(
          (stage['slices'] as List)
              .cast<Map<String, dynamic>>()
              .map((json) => TimeSlice.fromJson(json)));
    }
  }
  for (final builderEntry in timingsByKeyAndLabel.entries) {
    final builderKey = builderEntry.key;
    final timingsByBuilder = builderEntry.value;
    for (final labelEntry in timingsByBuilder.entries) {
      final label = labelEntry.key;
      final timings = labelEntry.value;
      final sum = timings.fold<Duration>(
          const Duration(), (sum, next) => sum + next.duration);
      final mean =
          Duration(microseconds: (sum.inMicroseconds / timings.length).floor());
      print(const JsonEncoder.withIndent('  ').convert({
        'builder key': builderKey,
        'action label': label,
        'mean duration': mean.toString(),
        'total duration': sum.toString(),
      }));
    }
  }
}
