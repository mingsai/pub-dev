// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;
import 'package:gcloud/db.dart' as db;
import 'package:gcloud/service_scope.dart';
import 'package:gcloud/storage.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../account/backend.dart';
import '../../account/consent_backend.dart';
import '../../analyzer/analyzer_client.dart';
import '../../dartdoc/dartdoc_client.dart';
import '../../frontend/handlers.dart';
import '../../frontend/static_files.dart';
import '../../package/backend.dart';
import '../../package/deps_graph.dart';
import '../../package/name_tracker.dart';
import '../../package/upload_signer_service.dart';
import '../../shared/configuration.dart';
import '../../shared/handler_helpers.dart';
import '../../shared/popularity_storage.dart';
import '../../shared/storage.dart';
import '../services.dart';

import '_cronjobs.dart' show CronJobs;
import '_isolate.dart';

final Logger _logger = Logger('pub');
final _random = Random.secure();

class DefaultCommand extends Command {
  @override
  String get name => 'default';

  @override
  String get description => 'The default frontend service entrypoint.';

  @override
  Future<void> run() async {
    // Ensure that we're running in the right environment, or is running locally
    if (envConfig.gaeService != null && envConfig.gaeService != name) {
      throw StateError(
        'Cannot start "$name" in "${envConfig.gaeService}" environment',
      );
    }

    await startIsolates(
      logger: _logger,
      frontendEntryPoint: _main,
      workerEntryPoint: envConfig.isRunningLocally ? null : _worker,
    );
  }
}

Future _main(FrontendEntryMessage message) async {
  setupServiceIsolate();
  message.protocolSendPort
      .send(FrontendProtocolMessage(statsConsumerPort: null));

  await updateLocalBuiltFiles();
  await withServices(() async {
    final shelf.Handler apiHandler = await setupServices(activeConfiguration);

    final cron = CronJobs(await getOrCreateBucket(
      storageService,
      activeConfiguration.backupSnapshotBucketName,
    ));
    final appHandler = createAppHandler(apiHandler);
    await runHandler(_logger, appHandler,
        sanitize: true, cronHandler: cron.handler);
  });
}

Future<shelf.Handler> setupServices(Configuration configuration) async {
  await popularityStorage.init();
  nameTracker.startTracking();

  UploadSignerService uploadSigner;
  if (envConfig.isRunningLocally) {
    uploadSigner = ServiceAccountBasedUploadSigner();
  } else {
    final authClient = await auth.clientViaMetadataServer();
    registerScopeExitCallback(() async => authClient.close());
    final email = await obtainServiceAccountEmail();
    uploadSigner =
        IamBasedUploadSigner(configuration.projectId, email, authClient);
  }
  registerUploadSigner(uploadSigner);

  return packageBackend.pubServer.requestHandler;
}

Future _worker(WorkerEntryMessage message) async {
  setupServiceIsolate();
  message.protocolSendPort.send(WorkerProtocolMessage());

  await withServices(() async {
    // TODO: use package:neat_periodic_task
    // Randomization reduces race conditions.
    Timer.periodic(Duration(hours: 8, minutes: _random.nextInt(240)),
        (_) async {
      await consentBackend.deleteObsoleteConsents();
      await accountBackend.deleteObsoleteSessions();
    });

    // Updates job entries for analyzer and dartdoc.
    Future<void> triggerDependentAnalysis(
        String package, String version, Set<String> affected) async {
      await analyzerClient.triggerAnalysis(package, version, affected);
      await dartdocClient.triggerDartdoc(package, version, affected);
    }

    final pdb = await PackageDependencyBuilder.loadInitialGraphFromDb(
        db.dbService, triggerDependentAnalysis);
    await pdb.monitorInBackground(); // never returns
  });
}

Future<String> obtainServiceAccountEmail() async {
  final http.Response response = await http.get(
      'http://metadata/computeMetadata/'
      'v1/instance/service-accounts/default/email',
      headers: const {'Metadata-Flavor': 'Google'});
  return response.body.trim();
}
