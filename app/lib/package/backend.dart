// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_dartlang_org.backend;

import 'dart:async';
import 'dart:io';

import 'package:client_data/account_api.dart';
import 'package:client_data/package_api.dart' as api;
import 'package:gcloud/db.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:gcloud/storage.dart';
import 'package:logging/logging.dart';
import 'package:pub_package_reader/pub_package_reader.dart';
import 'package:pub_server/repository.dart' hide UnauthorizedAccessException;
import 'package:pub_server/shelf_pubserver.dart'
    show PackageCache, ShelfPubServer;
import 'package:uuid/uuid.dart';

import '../account/backend.dart';
import '../account/consent_backend.dart';
import '../account/models.dart' show User;
import '../analyzer/analyzer_client.dart';
import '../dartdoc/dartdoc_client.dart';
import '../frontend/email_sender.dart';
import '../history/backend.dart';
import '../history/models.dart';
import '../publisher/backend.dart';
import '../publisher/models.dart';
import '../shared/configuration.dart';
import '../shared/datastore_helper.dart';
import '../shared/email.dart';
import '../shared/exceptions.dart';
import '../shared/redis_cache.dart' show cache;
import '../shared/utils.dart';
import 'model_properties.dart';
import 'models.dart' as models;
import 'name_tracker.dart';
import 'upload_signer_service.dart';

final Logger _logger = Logger('pub.cloud_repository');

/// Sets the active tarball storage
void registerTarballStorage(TarballStorage ts) =>
    ss.register(#_tarball_storage, ts);

/// The active tarball storage.
TarballStorage get tarballStorage =>
    ss.lookup(#_tarball_storage) as TarballStorage;

/// Sets the package backend service.
void registerPackageBackend(PackageBackend backend) =>
    ss.register(#_packageBackend, backend);

/// The active package backend service.
PackageBackend get packageBackend =>
    ss.lookup(#_packageBackend) as PackageBackend;

/// Represents the backend for the pub site.
class PackageBackend {
  final DatastoreDB db;
  final GCloudPackageRepository repository;

  PackageBackend(DatastoreDB db, TarballStorage storage)
      : db = db,
        repository = GCloudPackageRepository(db, storage);

  /// Get [ShelfPubServer] for handling the HTTP interface.
  ShelfPubServer get pubServer => ShelfPubServer(
        repository,
        cache: _PackageCache(),
      );

  /// Retrieves packages ordered by their created date.
  Future<List<models.Package>> newestPackages({int offset, int limit}) {
    final query = db.query<models.Package>()
      ..order('-created')
      ..offset(offset)
      ..limit(limit);
    return query.run().toList();
  }

  /// Retrieves packages ordered by their latest version date.
  Future<List<models.Package>> latestPackages({int offset, int limit}) {
    final query = db.query<models.Package>()
      ..order('-updated')
      ..offset(offset)
      ..limit(limit);
    return query.run().toList();
  }

  /// Retrieves the names of all packages, ordered by name.
  Stream<String> allPackageNames(
      {DateTime updatedSince, bool excludeDiscontinued = false}) {
    final query = db.query<models.Package>();

    if (updatedSince != null) {
      query.filter('updated >', updatedSince);
    }

    bool isExcluded(models.Package p) =>
        // isDiscontinued may be null
        excludeDiscontinued && p.isDiscontinued;

    return query.run().where((p) => !isExcluded(p)).map((p) => p.name);
  }

  /// Retrieves package versions ordered by their latest version date.
  Future<List<models.PackageVersion>> latestPackageVersions(
      {int offset, int limit}) async {
    final packages = await latestPackages(offset: offset, limit: limit);
    return lookupLatestVersions(packages);
  }

  /// Looks up a package by name.
  ///
  /// Returns `null` if the package doesn't exist.½
  Future<models.Package> lookupPackage(String packageName) async {
    final packageKey = db.emptyKey.append(models.Package, id: packageName);
    return await db.lookupValue<models.Package>(packageKey, orElse: () => null);
  }

  /// Looks up a package by name.
  Future<List<models.Package>> lookupPackages(
      Iterable<String> packageNames) async {
    return (await db.lookup(packageNames
            .map((p) => db.emptyKey.append(models.Package, id: p))
            .toList()))
        .cast();
  }

  /// Looks up a specific package version.
  ///
  /// Returns null if the version is not a semantic version or if the version
  /// entity does not exists in the datastore.
  Future<models.PackageVersion> lookupPackageVersion(
      String package, String version) async {
    version = canonicalizeVersion(version);
    if (version == null) return null;
    final packageVersionKey = db.emptyKey
        .append(models.Package, id: package)
        .append(models.PackageVersion, id: version);
    return (await db.lookup([packageVersionKey])).first
        as models.PackageVersion;
  }

  /// Looks up the latest versions of a list of packages.
  Future<List<models.PackageVersion>> lookupLatestVersions(
      List<models.Package> packages) async {
    final keys =
        packages.map((models.Package p) => p.latestVersionKey).toList();
    return (await db.lookup(keys)).cast();
  }

  /// Looks up all versions of a package.
  Future<List<models.PackageVersion>> versionsOfPackage(
      String packageName) async {
    final packageKey = db.emptyKey.append(models.Package, id: packageName);
    final query = db.query<models.PackageVersion>(ancestorKey: packageKey);
    return await query.run().toList();
  }

  /// Get a [Uri] which can be used to download a tarball of the pub package.
  Future<Uri> downloadUrl(String package, String version) async {
    version = canonicalizeVersion(version);
    assert(repository.supportsDownloadUrl);
    return repository.downloadUrl(package, version);
  }

  /// Updates [options] on [package].
  Future<void> updateOptions(String package, api.PkgOptions options) async {
    final user = await requireAuthenticatedUser();

    final pkgKey = db.emptyKey.append(models.Package, id: package);
    String latestVersion;
    await withTransaction(db, (tx) async {
      final p = await tx.lookupOrNull<models.Package>(pkgKey);
      if (p == null) {
        throw NotFoundException.resource(package);
      }
      latestVersion = p.latestVersion;

      // Check that the user is admin for this package.
      await checkPackageAdmin(p, user.userId);

      bool hasOptionsChanged = false;
      if (options.isDiscontinued != null &&
          options.isDiscontinued != p.isDiscontinued) {
        p.isDiscontinued = options.isDiscontinued;
        hasOptionsChanged = true;
      }

      if (!hasOptionsChanged) {
        return;
      }

      p.updated = DateTime.now().toUtc();
      _logger.info('Updating $package options: '
          'isDiscontinued: ${p.isDiscontinued} '
          'doNotAdvertise: ${p.doNotAdvertise}');
      tx.insert(p);
      tx.insert(History.entry(
        PackageOptionsChanged(
          packageName: p.name,
          userId: user.userId,
          userEmail: user.email,
          isDiscontinued: options.isDiscontinued,
        ),
      ));
    });
    await purgePackageCache(package);
    await analyzerClient.triggerAnalysis(package, latestVersion, <String>{});
  }

  /// Whether [userId] is a package admin (through direct uploaders list or
  /// publisher admin).
  ///
  /// Returns false if the user is not an admin.
  Future<bool> isPackageAdmin(models.Package p, String userId) async {
    if (userId == null) {
      return false;
    }
    if (p.publisherId == null) {
      return p.containsUploader(userId);
    } else {
      final memberKey = db.emptyKey
          .append(Publisher, id: p.publisherId)
          .append(PublisherMember, id: userId);
      final list = await db.lookup<PublisherMember>([memberKey]);
      final member = list.single;
      return member?.role == PublisherMemberRole.admin;
    }
  }

  /// Whether the [userId] is a package admin (through direct uploaders list or
  /// publisher admin).
  ///
  /// Throws AuthenticationException if the user is provided.
  /// Throws AuthorizationException if the user is not an admin for the package.
  Future<void> checkPackageAdmin(models.Package package, String userId) async {
    if (userId == null) {
      throw AuthenticationException.authenticationRequired();
    }
    if (!await isPackageAdmin(package, userId)) {
      throw AuthorizationException.userIsNotAdminForPackage(package.name);
    }
  }

  /// Returns the publisher info of a given package.
  Future<api.PackagePublisherInfo> getPublisherInfo(String packageName) async {
    final key = db.emptyKey.append(models.Package, id: packageName);
    final package = (await db.lookup<models.Package>([key])).single;
    if (package == null) {
      throw NotFoundException.resource('package "$packageName"');
    }
    return _asPackagePublisherInfo(package);
  }

  /// Returns the number of likes of a given package.
  Future<PackageLikesCount> getPackageLikesCount(String packageName) async {
    final key = db.emptyKey.append(models.Package, id: packageName);
    final package =
        await db.lookupValue<models.Package>(key, orElse: () => null);
    if (package == null) {
      throw NotFoundException.resource('package "$packageName"');
    }
    return PackageLikesCount(package: packageName, likes: package.likes);
  }

  /// Sets/updates the publisher of a package.
  Future<api.PackagePublisherInfo> setPublisher(
      String packageName, api.PackagePublisherInfo request) async {
    InvalidInputException.checkNotNull(request.publisherId, 'publisherId');
    final user = await requireAuthenticatedUser();

    final key = db.emptyKey.append(models.Package, id: packageName);
    await requirePackageAdmin(packageName, user.userId);
    await requirePublisherAdmin(request.publisherId, user.userId);
    final rs = await db.withTransaction<api.PackagePublisherInfo>((tx) async {
      final package = (await db.lookup<models.Package>([key])).single;
      final fromPublisherId = package.publisherId;
      package.publisherId = request.publisherId;
      package.uploaders.clear();
      package.updated = DateTime.now().toUtc();

      final history = History.entry(
        PackageTransferred(
          packageName: package.name,
          fromPublisherId: fromPublisherId,
          toPublisherId: package.publisherId,
          userId: user.userId,
          userEmail: user.email,
        ),
      );

      tx.queueMutations(inserts: [package, history]);
      await tx.commit();
      return _asPackagePublisherInfo(package);
    });
    await purgePublisherCache(publisherId: request.publisherId);
    await purgePackageCache(packageName);
    return rs;
  }

  /// Moves the package out of its current publisher.
  Future<api.PackagePublisherInfo> removePublisher(String packageName) async {
    final user = await requireAuthenticatedUser();
    final package = await requirePackageAdmin(packageName, user.userId);
    if (package.publisherId == null) {
      return _asPackagePublisherInfo(package);
    }
    await requirePublisherAdmin(package.publisherId, user.userId);
//  Code commented out while we decide if this feature is something we want to
//  support going forward.
//
//    final key = db.emptyKey.append(models.Package, id: packageName);
//    final rs = await db.withTransaction((tx) async {
//      final package = (await db.lookup<models.Package>([key])).single;
//      package.publisherId = null;
//      package.uploaders = [user.userId];
//      package.updated = DateTime.now().toUtc();
//      // TODO: store PackageTransferred History entry.
//      tx.queueMutations(inserts: [package]);
//      await tx.commit();
//      return _asPackagePublisherInfo(package);
//    });
//    await purgePublisherCache(package.publisherId);
//    await invalidatePackageCache(packageName);
//    return rs as api.PackagePublisherInfo;
    throw NotImplementedException();
  }
}

/// Loads [package], returns its [models.Package] instance, and also checks if
/// [userId] is an admin of the package.
///
/// Throws AuthenticationException if the user is provided.
/// Throws AuthorizationException if the user is not an admin for the package.
Future<models.Package> requirePackageAdmin(
    String package, String userId) async {
  if (userId == null) {
    throw AuthenticationException.authenticationRequired();
  }
  final p = await packageBackend.lookupPackage(package);
  if (p == null) {
    throw NotFoundException.resource('package "$package"');
  }
  await packageBackend.checkPackageAdmin(p, userId);
  return p;
}

api.PackagePublisherInfo _asPackagePublisherInfo(models.Package p) =>
    api.PackagePublisherInfo(publisherId: p.publisherId);

/// Purge [cache] entries for given [package] and also global page caches.
Future<void> purgePackageCache(String package) async {
  await Future.wait([
    cache.packageData(package).purge(),
    cache.packageView(package).purge(),
    cache.uiPackagePage(package, null).purge(),
    cache.uiIndexPage().purge(),
  ]);
}

/// Implementation of [PackageCache] using given cache and backend.
class _PackageCache implements PackageCache {
  @override
  Future<List<int>> getPackageData(String package) =>
      cache.packageData(package).get();

  @override
  Future<void> setPackageData(String package, List<int> data) =>
      cache.packageData(package).set(data);

  @override
  Future<void> invalidatePackageData(String package) =>
      purgePackageCache(package);
}

/// The status of an invite after being created or updated.
class InviteStatus {
  final String urlNonce;
  final DateTime nextNotification;

  InviteStatus({this.urlNonce, this.nextNotification});

  bool get isActive => urlNonce != null;

  bool get isDelayed => nextNotification != null;
}

/// A read-only implementation of [PackageRepository] using the Cloud Datastore
/// for metadata and Cloud Storage for tarball storage.
class GCloudPackageRepository extends PackageRepository {
  final Uuid uuid = Uuid();
  final DatastoreDB db;
  final TarballStorage storage;

  GCloudPackageRepository(this.db, this.storage);

  // Metadata support.

  @override
  Stream<PackageVersion> versions(String package) {
    final packageKey = db.emptyKey.append(models.Package, id: package);
    final query = db.query<models.PackageVersion>(ancestorKey: packageKey);
    return query.run().map((model) =>
        PackageVersion(package, model.version, model.pubspec.jsonString));
  }

  /// Returns null if the version is not a semantic version or if the version
  /// entity does not exists in the datastore.
  @override
  Future<PackageVersion> lookupVersion(String package, String version) async {
    version = canonicalizeVersion(version);
    if (version == null) return null;

    final packageVersionKey = db.emptyKey
        .append(models.Package, id: package)
        .append(models.PackageVersion, id: version);

    final pv =
        (await db.lookup([packageVersionKey])).first as models.PackageVersion;
    if (pv == null) return null;
    return PackageVersion(package, version, pv.pubspec.jsonString);
  }

  // Download support.

  @override
  Future<Stream<List<int>>> download(String package, String version) async {
    // TODO: Should we first test for existence?
    // Maybe with a cache?
    version = canonicalizeVersion(version);
    return storage.download(package, version);
  }

  @override
  bool get supportsDownloadUrl => true;

  @override
  Future<Uri> downloadUrl(String package, String version) async {
    version = canonicalizeVersion(version);
    return storage.downloadUrl(package, version);
  }

  // Upload support.

  @override
  bool get supportsUpload => true;

  @override
  Future<PackageVersion> upload(Stream<List<int>> data) async {
    await requireAuthenticatedUser();
    final guid = uuid.v4().toString();
    _logger.info('Starting semi-async upload (uuid: $guid)');
    final object = storage.tempObjectName(guid);
    await data.pipe(storage.bucket.write(object));
    final finishUri = Uri(
      path: '/api/packages/versions/newUploadFinish',
      queryParameters: {'upload_id': guid},
    );
    return await finishAsyncUpload(finishUri);
  }

  @override
  bool get supportsAsyncUpload => true;

  @override
  Future<AsyncUploadInfo> startAsyncUpload(Uri redirectUrl) async {
    _logger.info('Starting async upload.');
    // NOTE: We use a authenticated user scope here to ensure the uploading
    // user is authenticated. But we're not validating anything at this point
    // because we don't even know which package or version is going to be
    // uploaded.
    final user = await requireAuthenticatedUser();
    _logger.info('User: ${user.email}.');

    final guid = uuid.v4().toString();
    final String object = storage.tempObjectName(guid);
    final String bucket = storage.bucket.bucketName;
    final Duration lifetime = const Duration(minutes: 10);

    final url = redirectUrl.resolve('?upload_id=$guid');

    _logger
        .info('Redirecting pub client to google cloud storage (uuid: $guid)');
    return uploadSigner.buildUpload(bucket, object, lifetime, '$url');
  }

  /// Finishes the upload of a package.
  @override
  Future<PackageVersion> finishAsyncUpload(Uri uri) async {
    final user = await requireAuthenticatedUser();
    final guid = uri.queryParameters['upload_id'];
    _logger.info('Finishing async upload (uuid: $guid)');
    _logger.info('Reading tarball from cloud storage.');

    return withTempDirectory((Directory dir) async {
      final filename = '${dir.absolute.path}/tarball.tar.gz';
      await _saveTarballToFS(storage.readTempObject(guid), filename);
      return _performTarballUpload(user, filename, (package, version) {
        return storage.uploadViaTempObject(guid, package, version);
      }).whenComplete(() async {
        _logger.info('Removing temporary object $guid.');
        await storage.removeTempObject(guid);
      });
    });
  }

  Future<PackageVersion> _performTarballUpload(User user, String filename,
      Future<void> tarballUpload(String name, String version)) async {
    _logger.info('Examining tarball content.');

    // Parse metadata from the tarball.
    final validatedUpload = await _parseAndValidateUpload(db, filename, user);
    final newVersion = validatedUpload.packageVersion;

    models.Package package;

    // Add the new package to the repository by storing the tarball and
    // inserting metadata to datastore (which happens atomically).
    final pv = await db.withTransaction<PackageVersion>((Transaction T) async {
      _logger.info('Starting datastore transaction.') as PackageVersion;

      final tuple = (await T.lookup([newVersion.key, newVersion.packageKey]));
      final version = tuple[0] as models.PackageVersion;
      package = tuple[1] as models.Package;

      // If the version already exists, we fail.
      if (version != null) {
        await T.rollback();
        _logger.info('Version ${version.version} of package '
            '${version.package} already exists, rolling transaction back.');
        throw GenericProcessingException(
            'Version ${version.version} of package '
            '${version.package} already exists.');
      }

      // reserved package names for the Dart team
      if (package == null &&
          matchesReservedPackageName(newVersion.package) &&
          !user.email.endsWith('@google.com')) {
        await T.rollback();
        throw GenericProcessingException(
            'Package name ${newVersion.package} is reserved.');
      }

      // If the package does not exist, then we create a new package.
      if (package == null) {
        _logger.info('New package uploaded. [new-package-uploaded]');
        package = _newPackageFromVersion(db, newVersion, user.userId);
      } else if (!await packageBackend.isPackageAdmin(package, user.userId)) {
        _logger.info('User ${user.userId} (${user.email}) is not an uploader '
            'for package ${package.name}, rolling transaction back.');
        await T.rollback();
        throw AuthorizationException.userCannotUploadNewVersion(package.name);
      }

      // Store the publisher of the package at the time of the upload.
      newVersion.publisherId = package.publisherId;

      // Keep the latest version in the package object up-to-date.
      package.updateVersion(newVersion);
      package.updated = DateTime.now().toUtc();

      try {
        _logger.info('Trying to upload tarball to cloud storage.');
        // Apply update: Push to cloud storage
        await tarballUpload(package.name, newVersion.version);

        final inserts = <Model>[
          package,
          newVersion,
          validatedUpload.packageVersionPubspec,
          validatedUpload.packageVersionInfo,
        ];
        if (historyBackend.isEnabled) {
          final history = History.entry(PackageUploaded(
            packageName: newVersion.package,
            packageVersion: newVersion.version,
            uploaderId: user.userId,
            uploaderEmail: user.email,
            timestamp: newVersion.created,
          ));
          inserts.add(history);
        }

        // Apply update: Update datastore.
        _logger.info('Trying to commit datastore changes.');
        T.queueMutations(inserts: inserts);
        await T.commit();

        _logger.info('Upload successful. [package-uploaded]');

        // Try to load all package versions, sort them by `sort_order` and
        // store them again.
        await _updatePackageSortIndex(package.key);

        return PackageVersion(newVersion.package, newVersion.version,
            newVersion.pubspec.jsonString);
      } catch (error, stack) {
        _logger.warning('Error while committing: $error, $stack');

        // This call might fail if the transaction has already been
        // committed/rolled back or the transaction failed.
        //
        // In which case we simply ignore the rollback error and rethrow the
        // original error.
        try {
          await T.rollback();
        } catch (_) {}
        rethrow;
      }
    });

    try {
      final uploaderEmails = package.publisherId == null
          ? await accountBackend.getEmailsOfUserIds(package.uploaders)
          : await publisherBackend.getAdminMemberEmails(package.publisherId);

      // Notify uploaders via email that a new version has been published.
      final email = emailSender.sendMessage(
        createPackageUploadedEmail(
          packageName: newVersion.package,
          packageVersion: newVersion.version,
          uploaderEmail: user.email,
          authorizedUploaders:
              uploaderEmails.map((email) => EmailAddress(null, email)).toList(),
        ),
      );

      // Trigger analysis and dartdoc generation. Dependent packages can be left
      // out here, because the dependency graph's background polling will pick up
      // the new upload, and will trigger analysis for the dependent packages.
      final triggerAnalysis = analyzerClient
          .triggerAnalysis(newVersion.package, newVersion.version, <String>{});
      final triggerDartdoc = dartdocClient
          .triggerDartdoc(newVersion.package, newVersion.version, <String>{});

      // Let's not block the upload response on these. In case of a timeout, the
      // underlying operations still go ahead, but the `Future.wait` call below
      // is not blocked on it.
      await Future.wait([email, triggerAnalysis, triggerDartdoc])
          .timeout(Duration(seconds: 10));
    } catch (e, st) {
      final v = newVersion.qualifiedVersionKey;
      _logger.severe('Error post-processing package upload $v', e, st);
    }
    return pv;
  }

  Future<void> _updatePackageSortIndex(Key packageKey) async {
    try {
      _logger.info('Trying to update the `sort_order` field.');
      await db.withTransaction((Transaction T) async {
        final versions =
            await T.query<models.PackageVersion>(packageKey).run().toList();
        versions.sort((versionA, versionB) {
          return versionA.semanticVersion.compareTo(versionB.semanticVersion);
        });

        final List<models.PackageVersion> modifiedVersions = [];

        for (int i = 0; i < versions.length; i++) {
          final version = versions[i];
          if (version.sortOrder != i) {
            version.sortOrder = i;
            modifiedVersions.add(version);
          }
        }

        T.queueMutations(inserts: modifiedVersions);
        await T.commit();
        _logger.info('Successfully updated `sort_order` field of '
            '${modifiedVersions.length} versions'
            '(out of ${versions.length} versions).');
      });
    } catch (error, stack) {
      // We ignore errors, since the sorting is not that critical and
      // the upload itself was successfull.
      _logger.warning(
          'Sorting by `sort_order` failed, but upload was successful.',
          error,
          stack);
    }
  }

  // Uploaders support.

  @override
  bool get supportsUploaders => true;

  @override
  Future<void> addUploader(String packageName, String uploaderEmail) async {
    uploaderEmail = uploaderEmail.toLowerCase();
    final user = await requireAuthenticatedUser();
    final packageKey = db.emptyKey.append(models.Package, id: packageName);
    final package = (await db.lookup([packageKey])).first as models.Package;

    await _validatePackageUploader(packageName, package, user.userId);
    // Don't send invites for publisher-owned packages.
    if (package.publisherId != null) {
      throw GenericProcessingException(
          'Package is owned by publisher "${package.publisherId}".');
    }

    if (!isValidEmail(uploaderEmail)) {
      throw GenericProcessingException('Not a valid email: `$uploaderEmail`.');
    }

    final uploader = await accountBackend.lookupUserByEmail(uploaderEmail);
    if (uploader != null && package.containsUploader(uploader.userId)) {
      // The requested uploaderEmail is already part of the uploaders.
      return;
    }

    await historyBackend.storeEvent(UploaderInvited(
      packageName: packageName,
      currentUserId: user.userId,
      currentUserEmail: user.email,
      uploaderUserEmail: uploaderEmail,
    ));

    final status = await consentBackend.invite(
      userId: uploader?.userId,
      email: uploaderEmail,
      kind: ConsentKind.packageUploader,
      args: [packageName],
    );

    if (!status.emailSent) {
      throw GenericProcessingException(
          'Previous invite is still active, next notification can be sent '
          'on ${status.nextNotification.toIso8601String()}.');
    }

    throw GenericProcessingException(
        'We have sent an invitation to $uploaderEmail, '
        'they will be added as uploader after they confirm it.');
  }

  Future<void> confirmUploader(String fromUserId, String fromUserEmail,
      String packageName, User uploader) async {
    if (fromUserId == null) {
      final user =
          await accountBackend.lookupOrCreateUserByEmail(fromUserEmail);
      fromUserId = user.userId;
    }
    assert(fromUserId != null);
    return db.withTransaction((Transaction tx) async {
      final packageKey = db.emptyKey.append(models.Package, id: packageName);
      final package = (await tx.lookup([packageKey])).first as models.Package;

      try {
        await _validatePackageUploader(packageName, package, fromUserId);
      } catch (_) {
        await tx.rollback();
        rethrow;
      }

      if (package.containsUploader(uploader.userId)) {
        // The requested uploaderEmail is already part of the uploaders.
        await tx.rollback();
        return;
      }

      // Add [uploaderEmail] to uploaders and commit.
      package.addUploader(uploader.userId);
      package.updated = DateTime.now().toUtc();

      final inserts = <Model>[package];
      if (historyBackend.isEnabled) {
        final history = History.entry(UploaderChanged(
          packageName: packageName,
          currentUserId: fromUserId,
          currentUserEmail: fromUserEmail,
          addedUploaderIds: [uploader.userId],
          addedUploaderEmails: [uploader.email],
        ));
        inserts.add(history);
      }

      tx.queueMutations(inserts: inserts);
      await tx.commit();
      await purgePackageCache(package.name);
    });
  }

  Future<void> _validatePackageUploader(
      String packageName, models.Package package, String userId) async {
    // Fail if package doesn't exist.
    if (package == null) {
      throw NotFoundException.resource(packageName);
    }

    // Fail if calling user doesn't have permission to change uploaders.
    if (!await packageBackend.isPackageAdmin(package, userId)) {
      throw AuthorizationException.userCannotChangeUploaders(package.name);
    }
  }

  @override
  Future<void> removeUploader(String packageName, String uploaderEmail) async {
    uploaderEmail = uploaderEmail.toLowerCase();
    final user = await requireAuthenticatedUser();
    return db.withTransaction((Transaction T) async {
      final packageKey = db.emptyKey.append(models.Package, id: packageName);
      final package = (await T.lookup([packageKey])).first as models.Package;

      await _validatePackageUploader(packageName, package, user.userId);

      // Fail if the uploader we want to remove does not exist.
      final uploader = await accountBackend.lookupUserByEmail(uploaderEmail);
      if (uploader == null || !package.containsUploader(uploader.userId)) {
        await T.rollback();
        throw GenericProcessingException(
            'The uploader to remove does not exist.');
      }

      // We cannot have 0 uploaders, if we would remove the last one, we
      // fail with an error.
      if (package.uploaderCount <= 1) {
        await T.rollback();
        throw LastUploaderRemoveException();
      }

      // At the moment we don't validate whether the other email addresses
      // are able to authenticate. To prevent accidentally losing the control
      // of a package, we don't allow self-removal.
      if (user.email == uploader.email || user.userId == uploader.userId) {
        await T.rollback();
        throw GenericProcessingException('Self-removal is not allowed. '
            'Use another account to remove this email address.');
      }

      // Remove the uploader from the list.
      package.removeUploader(uploader.userId);
      package.updated = DateTime.now().toUtc();

      final inserts = <Model>[package];
      if (historyBackend.isEnabled) {
        final history = History.entry(UploaderChanged(
          packageName: packageName,
          currentUserId: user.userId,
          currentUserEmail: user.email,
          removedUploaderIds: [uploader.userId],
          removedUploaderEmails: [uploader.email],
        ));
        inserts.add(history);
      }

      T.queueMutations(inserts: inserts);
      await T.commit();
      await purgePackageCache(package.name);
    });
  }
}

/// Reads a tarball from a byte stream.
///
/// Completes with an error if the incoming stream has an error or if the size
/// exceeds [UploadSignerService.maxUploadSize].
Future _saveTarballToFS(Stream<List<int>> data, String filename) async {
  try {
    int receivedBytes = 0;
    final stream = data.transform<List<int>>(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          receivedBytes += chunk.length;
          if (receivedBytes <= UploadSignerService.maxUploadSize) {
            sink.add(chunk);
          } else {
            sink.addError(PackageRejectedException.archiveTooLarge(
                UploadSignerService.maxUploadSize));
          }
        },
      ),
    );
    await stream.pipe(File(filename).openWrite());
  } catch (e, st) {
    _logger.warning('An error occured while streaming tarball to FS.', e, st);
    rethrow;
  }
  _logger.info('Finished streaming tarball to FS.');
}

/// Creates a new `Package` and populates all of it's fields.
models.Package _newPackageFromVersion(
    DatastoreDB db, models.PackageVersion version, String userId) {
  final now = DateTime.now().toUtc();
  return models.Package()
    ..parentKey = db.emptyKey
    ..id = version.pubspec.name
    ..name = version.pubspec.name
    ..created = now
    ..updated = now
    ..downloads = 0
    ..latestVersionKey = version.key
    ..latestDevVersionKey = version.key
    ..uploaders = [userId]
    ..likes = 0
    ..doNotAdvertise = false
    ..isDiscontinued = false
    ..assignedTags = [];
}

class _ValidatedUpload {
  final models.PackageVersion packageVersion;
  final models.PackageVersionPubspec packageVersionPubspec;
  final models.PackageVersionInfo packageVersionInfo;

  _ValidatedUpload(
    this.packageVersion,
    this.packageVersionPubspec,
    this.packageVersionInfo,
  );
}

/// Parses metadata from a tarball and & validates it.
///
/// This function ensures that `tarball`
///   * is a valid `tar.gz` file
///   * contains a valid `pubspec.yaml` file
///   * reads readme, changelog and pubspec files
///   * creates a [models.PackageVersion] and populates it with all metadata
Future<_ValidatedUpload> _parseAndValidateUpload(
    DatastoreDB db, String filename, User user) async {
  assert(user != null);

  final archive = await summarizePackageArchive(filename);
  if (archive.hasIssues) {
    throw GenericProcessingException(archive.issues.first.message);
  }

  final pubspec = Pubspec.fromYaml(archive.pubspecContent);
  if (!await nameTracker.accept(pubspec.name)) {
    throw GenericProcessingException(
        'Package name is too similar to another package.');
  }

  if (pubspec.hasBothAuthorAndAuthors) {
    throw GenericProcessingException(
        'Do not specify both `author` and `authors` in `pubspec.yaml`.');
  }

  final packageKey = db.emptyKey.append(models.Package, id: pubspec.name);

  final versionString = canonicalizeVersion(pubspec.version);
  if (versionString == null) {
    throw GenericProcessingException(
        'Unable to canonicalize the version: ${pubspec.version}');
  }

  final key =
      models.QualifiedVersionKey(package: pubspec.name, version: versionString);

  final version = models.PackageVersion()
    ..id = versionString
    ..parentKey = packageKey
    ..version = versionString
    ..packageKey = packageKey
    ..created = DateTime.now().toUtc()
    ..pubspec = pubspec
    ..readmeFilename = archive.readmePath
    ..readmeContent = archive.readmeContent
    ..changelogFilename = archive.changelogPath
    ..changelogContent = archive.changelogContent
    ..exampleFilename = archive.examplePath
    ..exampleContent = archive.exampleContent
    ..libraries = archive.libraries
    ..downloads = 0
    ..sortOrder = 1
    ..uploader = user.userId;

  final versionPubspec = models.PackageVersionPubspec()
    ..initFromKey(key)
    ..updated = version.created
    ..pubspec = pubspec;

  final versionInfo = models.PackageVersionInfo()
    ..initFromKey(key)
    ..updated = version.created
    ..libraries = archive.libraries
    ..libraryCount = archive.libraries.length;

  return _ValidatedUpload(version, versionPubspec, versionInfo);
}

/// Helper utility class for interfacing with Cloud Storage for storing
/// tarballs.
class TarballStorage {
  final TarballStorageNamer namer;
  final Storage storage;
  final Bucket bucket;

  TarballStorage(this.storage, Bucket bucket, String namespace)
      : bucket = bucket,
        namer = TarballStorageNamer(
            activeConfiguration.storageBaseUrl, bucket.bucketName, namespace);

  /// Generates a path to a temporary object on cloud storage.
  String tempObjectName(String guid) => namer.tmpObjectName(guid);

  /// Reads the temporary object identified by [guid]
  Stream<List<int>> readTempObject(String guid) =>
      bucket.read(namer.tmpObjectName(guid));

  /// Makes a temporary object a new tarball.
  Future<void> uploadViaTempObject(
      String guid, String package, String version) async {
    final object = namer.tarballObjectName(package, version);

    // Copy the temporary object to it's destination place.
    await storage.copyObject(
        bucket.absoluteObjectName(namer.tmpObjectName(guid)),
        bucket.absoluteObjectName(object));

    // Change the ACL to include a `public-read` entry.
    final ObjectInfo info = await bucket.info(object);
    final publicRead = AclEntry(AllUsersScope(), AclPermission.READ);
    final acl = Acl(List.from(info.metadata.acl.entries)..add(publicRead));
    await bucket.updateMetadata(object, info.metadata.replace(acl: acl));
  }

  /// Remove a previously generated temporary object.
  Future<void> removeTempObject(String guid) async {
    if (guid == null) throw ArgumentError('No guid given.');
    return bucket.delete(namer.tmpObjectName(guid));
  }

  /// Download the tarball of a [package] in the given [version].
  Stream<List<int>> download(String package, String version) {
    final object = namer.tarballObjectName(package, version);
    return bucket.read(object);
  }

  /// Deletes the tarball of a [package] in the given [version] permanently.
  Future<void> remove(String package, String version) {
    final object = namer.tarballObjectName(package, version);
    return bucket.delete(object);
  }

  /// Get the URL to the tarball of a [package] in the given [version].
  Future<Uri> downloadUrl(String package, String version) {
    // NOTE: We should maybe check for existence first?
    // return storage.bucket(bucket).info(object)
    //     .then((info) => info.downloadLink);
    return Future.value(Uri.parse(namer.tarballObjectUrl(package, version)));
  }

  /// Upload [tarball] of a [package] in the given [version].
  Future<void> upload(
      String package, String version, Stream<List<int>> tarball) {
    final object = namer.tarballObjectName(package, version);
    return tarball
        .pipe(bucket.write(object, predefinedAcl: PredefinedAcl.publicRead));
  }
}

/// Class used for getting GCS object/bucket names and object URLs.
///
///
/// The GCS bucket contains package tarballs in a temporary place and stored
/// package tarballs which are used by clients. The latter can be stored either
/// via an empty or non-empty namespace.
///
/// The layout of the GCS bucket is as follows:
///   gs://<bucket-name>/tmp/<uuid>
///   gs://<bucket-name>/packages/<package-name>-<version>.tar.gz
///   gs://<bucket-name>/ns/<namespace>/packages/<package-name>-<version>.tar.gz
class TarballStorageNamer {
  /// The tarball object storage prefix
  final String storageBaseUrl;

  /// The GCS bucket used.
  final String bucket;

  /// The namespace used.
  final String namespace;

  /// The prefix of where packages are stored (i.e. '' or 'ns/<namespace>').
  final String prefix;

  TarballStorageNamer(String storageBaseUrl, this.bucket, String namespace)
      : storageBaseUrl = storageBaseUrl.endsWith('/')
            ? storageBaseUrl.substring(0, storageBaseUrl.length - 1)
            : storageBaseUrl,
        namespace = namespace == null ? '' : namespace,
        prefix =
            (namespace == null || namespace.isEmpty) ? '' : 'ns/$namespace/';

  /// The GCS object name of a tarball object - excluding leading '/'.
  String tarballObjectName(String package, String version) =>
      '${prefix}packages/$package-$version.tar.gz';

  /// The GCS object name of an temporary object [guid] - excluding leading '/'.
  String tmpObjectName(String guid) => 'tmp/$guid';

  /// The http URL of a publicly accessable GCS object.
  String tarballObjectUrl(String package, String version) {
    final object = tarballObjectName(package, Uri.encodeComponent(version));
    return '$storageBaseUrl/$bucket/$object';
  }
}
