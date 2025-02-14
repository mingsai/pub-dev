// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:client_data/page_data.dart';
import 'package:meta/meta.dart';

import '../../account/backend.dart';
import '../../account/models.dart' show SearchPreference;
import '../../search/search_service.dart';
import '../../shared/configuration.dart';
import '../../shared/tags.dart';
import '../../shared/urls.dart' as urls;

import '../request_context.dart';
import '../static_files.dart';

import '_cache.dart';
import '_consts.dart';
import '_utils.dart';

enum PageType {
  error,
  account,
  landing,
  listing,
  package,
  publisher,
  standalone,
}

/// Renders the `views/layout.mustache` template.
String renderLayoutPage(
  PageType type,
  String contentHtml, {
  @required String title,
  String pageDescription,
  String faviconUrl,
  String canonicalUrl,
  String sdk,
  String publisherId,
  SearchQuery searchQuery,
  bool includeSurvey = true,
  bool noIndex = false,
  PageData pageData,
  String searchPlaceHolder,
}) {
  final isRoot = type == PageType.landing && sdk == null;
  final pageDataEncoded = pageData == null
      ? null
      : htmlAttrEscape.convert(pageDataJsonCodec.encode(pageData.toJson()));
  final bodyClasses = [
    if (type == PageType.standalone) 'page-standalone',
    if (requestContext.isExperimental) 'experimental',
  ];
  final userSession = userSessionData == null
      ? null
      : {
          'email': userSessionData.email,
          'image_url': userSessionData.imageUrl == null
              ? staticUrls.defaultProfilePng
              // Set image size to 30x30 pixels for faster loading, see:
              // https://developers.google.com/people/image-sizing
              : '${userSessionData.imageUrl}=s30',
        };
  final searchBannerHtml = _renderSearchBanner(
    type: type,
    publisherId: publisherId,
    searchQuery: searchQuery,
    searchPlaceholder: searchPlaceHolder,
  );
  final values = {
    'is_experimental': requestContext.isExperimental,
    'is_logged_in': userSession != null,
    'dart_site_root': urls.dartSiteRoot,
    'oauth_client_id': activeConfiguration.pubSiteAudience,
    'user_session': userSession,
    'body_class': bodyClasses.join(' '),
    'no_index': noIndex,
    'favicon': faviconUrl ?? staticUrls.smallDartFavicon,
    'canonicalUrl': canonicalUrl,
    'pageDescription': pageDescription == null
        ? _defaultPageDescriptionEscaped
        : htmlEscape.convert(pageDescription),
    'title': htmlEscape.convert(title),
    'site_logo_url': staticUrls.pubDevLogo2xPng,
    // This is not escaped as it is already escaped by the caller.
    'content_html': contentHtml,
    'include_survey': includeSurvey,
    'include_highlight': type == PageType.package,
    'search_banner_html': searchBannerHtml,
    'schema_org_searchaction_json':
        isRoot ? encodeScriptSafeJson(_schemaOrgSearchAction) : null,
    'page_data_encoded': pageDataEncoded,
    'my_liked_packages_url': urls.myLikedPackagesUrl(),
  };

  // TODO(zarah): update the 'layout' template to use urls from `shared/urls.dart`.
  return templateCache.renderTemplate('layout', values);
}

String _renderSearchBanner({
  @required PageType type,
  @required String publisherId,
  @required SearchQuery searchQuery,
  String searchPlaceholder,
}) {
  final sp = searchQuery != null
      ? SearchPreference.fromSearchQuery(searchQuery)
      : (searchPreference ?? SearchPreference());
  final queryText = searchQuery?.query;
  final escapedSearchQuery =
      queryText == null ? null : htmlAttrEscape.convert(queryText);
  bool includePreferencesAsHiddenFields = false;
  if (publisherId != null) {
    searchPlaceholder ??= 'Search $publisherId packages';
  } else if (type == PageType.account) {
    searchPlaceholder ??= 'Search your packages';
  } else {
    searchPlaceholder ??= getSdkDict(sp.sdk).searchPackagesLabel;
    includePreferencesAsHiddenFields = true;
  }
  String searchFormUrl;
  if (publisherId != null) {
    searchFormUrl = SearchQuery.parse(publisherId: publisherId).toSearchLink();
  } else if (type == PageType.account) {
    searchFormUrl = urls.myPackagesUrl();
  } else if (searchQuery != null) {
    searchFormUrl = searchQuery.toSearchFormPath();
  } else {
    searchFormUrl = sp.toSearchQuery().toSearchFormPath();
  }
  final searchSort = searchQuery?.order == null
      ? null
      : serializeSearchOrder(searchQuery.order);
  final hiddenInputs = includePreferencesAsHiddenFields
      ? sp
          .toSearchQuery()
          .tagsPredicate
          .asSearchLinkParams()
          .entries
          .map((e) => {'name': e.key, 'value': e.value})
          .toList()
      : null;
  String searchTabsHtml;
  if (type == PageType.landing) {
    searchTabsHtml = renderSearchTabs();
  } else if (type == PageType.listing) {
    searchTabsHtml = renderSearchTabs(searchQuery: searchQuery);
  }
  String secondaryTabsHtml;
  if (searchQuery?.sdk == SdkTagValue.dart) {
    secondaryTabsHtml = _renderFilterTabs(
      searchQuery: searchQuery,
      options: [
        _FilterOption(
          label: 'native',
          tag: DartSdkTag.runtimeNativeJit,
          title:
              'Packages compatible with Dart running on a native platform (JIT/AOT)',
        ),
        _FilterOption(
          label: 'js',
          tag: DartSdkTag.runtimeWeb,
          title: 'Packages compatible with Dart compiled for the web',
        ),
      ],
    );
  } else if (searchQuery?.sdk == SdkTagValue.flutter) {
    secondaryTabsHtml = _renderFilterTabs(
      searchQuery: searchQuery,
      options: [
        _FilterOption(
          label: 'android',
          tag: FlutterSdkTag.platformAndroid,
          title: 'Packages compatible with Flutter on the Android platform',
        ),
        _FilterOption(
          label: 'ios',
          tag: FlutterSdkTag.platformIos,
          title: 'Packages compatible with Flutter on the iOS platform',
        ),
        _FilterOption(
          label: 'web',
          tag: FlutterSdkTag.platformWeb,
          title: 'Packages compatible with Flutter on the Web platform',
        ),
      ],
    );
  }
  String bannerClass;
  if (type == PageType.landing) {
    bannerClass = 'home-banner';
  } else if (type == PageType.listing) {
    bannerClass = 'medium-banner';
  } else {
    bannerClass = 'small-banner';
  }
  final isFlutter = sp.sdk == SdkTagValue.flutter;
  return templateCache.renderTemplate('shared/search_banner', {
    'banner_class': bannerClass,
    'show_details': type == PageType.listing,
    'show_landing': type == PageType.landing,
    'search_form_url': searchFormUrl,
    'search_query_placeholder': searchPlaceholder,
    'search_query_html': escapedSearchQuery,
    'search_sort_param': searchSort,
    'legacy_search_enabled': searchQuery?.includeLegacy ?? false,
    'hidden_inputs': hiddenInputs,
    'search_tabs_html': searchTabsHtml,
    'show_legacy_checkbox': sp.sdk == null,
    'secondary_tabs_html': secondaryTabsHtml,
    'landing_banner_image': _landingBannerImage(isFlutter),
    'landing_banner_alt': isFlutter ? 'Flutter packages' : 'Dart packages',
    'landing_blurb_html':
        isFlutter ? flutterLandingBlurbHtml : defaultLandingBlurbHtml,
  });
}

String _landingBannerImage(bool isFlutter) {
  return isFlutter
      ? staticUrls.assets['img__flutter-packages-white_png']
      : staticUrls.assets['img__dart-packages-white_png'];
}

String renderSearchTabs({
  SearchQuery searchQuery,
}) {
  final sp = searchQuery != null
      ? SearchPreference.fromSearchQuery(searchQuery)
      : (searchPreference ?? SearchPreference());
  final currentSdk = sp.sdk ?? SdkTagValue.any;
  Map sdkTabData(String label, String tabSdk, String title) {
    String url;
    if (searchQuery != null) {
      url = searchQuery.change(sdk: tabSdk).toSearchLink();
    } else {
      url = urls.searchUrl(sdk: tabSdk);
    }
    return {
      'text': label,
      'href': htmlAttrEscape.convert(url),
      'active': tabSdk == currentSdk,
      'title': title,
    };
  }

  final values = {
    'tabs': [
      sdkTabData(
        'Dart',
        SdkTagValue.dart,
        'Packages compatible with the Dart SDK',
      ),
      sdkTabData(
        'Flutter',
        SdkTagValue.flutter,
        'Packages compatible with the Flutter SDK',
      ),
      sdkTabData(
        'Any',
        SdkTagValue.any,
        'Packages compatible with the any SDK',
      ),
    ],
  };
  return templateCache.renderTemplate('shared/search_tabs', values);
}

class _FilterOption {
  final String label;
  final String tag;
  final String title;

  _FilterOption({
    @required this.label,
    @required this.tag,
    @required this.title,
  });
}

String _renderFilterTabs({
  @required SearchQuery searchQuery,
  @required List<_FilterOption> options,
}) {
  final tp = searchQuery.tagsPredicate;
  String searchWithTagsLink(TagsPredicate tagsPredicate) {
    return searchQuery.change(tagsPredicate: tagsPredicate).toSearchLink();
  }

  return templateCache.renderTemplate('shared/search_tabs', {
    'tabs': options
        .map((option) => {
              'title': option.title,
              'text': option.label,
              'href': htmlAttrEscape.convert(searchWithTagsLink(
                tp.isRequiredTag(option.tag)
                    ? tp.withoutTag(option.tag)
                    : tp.appendPredicate(TagsPredicate(
                        requiredTags: [option.tag],
                      )),
              )),
              'active': tp.isRequiredTag(option.tag),
            })
        .toList(),
  });
}

final String _defaultPageDescriptionEscaped = htmlEscape.convert(
    'Pub is the package manager for the Dart programming language, containing reusable '
    'libraries & packages for Flutter, AngularDart, and general Dart programs.');

const _schemaOrgSearchAction = {
  '@context': 'http://schema.org',
  '@type': 'WebSite',
  'url': '${urls.siteRoot}/',
  'potentialAction': {
    '@type': 'SearchAction',
    'target': '${urls.siteRoot}/packages?q={search_term_string}',
    'query-input': 'required name=search_term_string',
  },
};
