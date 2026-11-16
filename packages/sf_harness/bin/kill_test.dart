import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sf_harness/sf_harness.dart';
import 'package:sf_server/sf_server.dart';

Future<void> main(List<String> args) async {
  final options = parseOptions(args);
  final kills = int.parse(options['kills'] ?? '200');
  final minKillMs = int.parse(options['min-kill-ms'] ?? '20');
  final maxKillMs = int.parse(options['max-kill-ms'] ?? '150');
  final seed = int.parse(options['seed'] ?? '1');
  final random = Random(seed);

  final dir = Directory.systemTemp.createTempSync('sf_kill_test');
  final phoneDb = '${dir.path}/phone.db';
  final serverDb = '${dir.path}/server.db';
  final log = '${dir.path}/saved.log';

  // 1. Compile the phone once, so each start takes milliseconds instead of seconds.
  stdout.writeln('Compiling the phone worker...');
  final worker = '${dir.path}/phone_worker';
  final compile = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    Platform.script.resolve('phone_worker.dart').toFilePath(),
    '-o',
    worker,
  ]);
  if (compile.exitCode != 0) {
    stderr.write(compile.stderr);
    exit(1);
  }

  // 2. The real server, behind a proxy that misbehaves.
  final store = ServerStore.open(serverDb);
  final real = await SyncHttpServer.start(store, port: 0);
  final failRate = double.parse(options['fail-rate'] ?? '0.2');
  final dropRate = double.parse(options['drop-rate'] ?? '0.2');
  final proxy = await FaultyProxy.start(
    upstream: Uri.parse('http://127.0.0.1:${real.port}'),
    seed: seed,
    failRate: failRate,
    dropRate: dropRate,
  );

  // 3. Start the phone, kill it at a random moment. Again and again.
  stdout.writeln('Killing the phone $kills times...');
  final watch = Stopwatch()..start();
  var crashes = 0;
  for (var round = 1; round <= kills; round++) {
    final phone = await Process.start(worker, [
      '--db=$phoneDb',
      '--server=${proxy.url}',
      '--log=$log',
      '--seed=${seed * 100000 + round}',
    ]);
    final errors = phone.stderr.transform(utf8.decoder).join();
    phone.stdout.drain<void>();

    final wait = minKillMs + random.nextInt(maxKillMs - minKillMs + 1);
    final code = await phone.exitCode.timeout(
      Duration(milliseconds: wait),
      onTimeout: () => -999,
    );
    if (code == -999) {
      phone.kill(
        ProcessSignal.sigkill,
      ); // no warning, no cleanup: like a dead battery
      await phone.exitCode;
    } else {
      crashes++; // it stopped BY ITSELF: an uncaught error, a real bug
      stderr.writeln(
        'round $round: the phone crashed (exit $code)\n${await errors}',
      );
    }
    if (round % 50 == 0) {
      stdout.writeln('  $round kills');
    }
  }

  // 4. Faults off. Let the phone finish syncing everything.
  proxy.faultsOn = false;
  final drain = await Process.run(worker, [
    '--db=$phoneDb',
    '--server=${proxy.url}',
    '--drain',
  ]);
  if (drain.exitCode != 0) {
    crashes++;
    stderr.write(drain.stderr);
  }

  // 5. The verdict.
  final verdict = verify(phoneDb: phoneDb, serverDb: serverDb, savedLog: log);
  stdout.writeln('''

Kill test (seed $seed)
  kills          : $kills
  crashes        : $crashes
  proxy faults   : ${proxy.failed} failed, ${proxy.dropped} replies dropped
  seconds        : ${watch.elapsed.inSeconds}
$verdict''');

  await proxy.close();
  await real.close();
  store.close();

  final passed = verdict.passed && crashes == 0;
  if (passed) {
    dir.deleteSync(recursive: true);
  } else {
    stdout.writeln('Databases kept for inspection in ${dir.path}');
  }
  exitCode = passed ? 0 : 1;
}
