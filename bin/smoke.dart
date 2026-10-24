import 'dart:io';
import 'package:wayfinder/llm.dart';

Future<void> main() async {
  stdout.writeln('Running Phase 1 smoke test...');

  final stopwatch = Stopwatch()..start();
  final reply = await chat([
    {'role': 'user', 'content': 'Say hi in 5 words'}
  ], temp: 0.2, maxTokens: 25);
  stopwatch.stop();

  final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;

  final embedding = await embed('hello');

  stdout.writeln('--- SMOKE TEST RESULTS ---');
  stdout.writeln('Chat Reply: "$reply"');
  stdout.writeln('Chat Timing: ${elapsedSeconds.toStringAsFixed(2)}s');
  stdout.writeln('Embedding Length: ${embedding.length}');

  if (elapsedSeconds > 6.0) {
    stdout.writeln(
      'WARNING: Chat call took ${elapsedSeconds.toStringAsFixed(2)}s (> 6.0s). The model may be too big for this GPU.',
    );
  } else {
    stdout.writeln('Performance: OK (<= 6.0s)');
  }
}
