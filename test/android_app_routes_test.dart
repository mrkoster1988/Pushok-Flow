import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/platform/android_app_routes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shop.pushok.flow/app_routes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Object? response;
  setUp(() {
    calls = [];
    response = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('App metadata has stable case-insensitive ordering and cannot be mutated', () async {
    response = [
      {'packageName': 'example.zulu', 'label': 'Zulu'},
      {'packageName': 'example.second', 'label': 'alpha'},
      {'packageName': 'example.first', 'label': 'Alpha'},
    ];
    final apps = await AndroidAppRoutes.installedApps();
    expect(apps.map((app) => app.packageName),
      ['example.first', 'example.second', 'example.zulu']);
    expect(() => apps.clear(), throwsUnsupportedError);
    expect(calls.single.method, 'installedApps');
  });

  test('Malformed app responses fail instead of becoming an empty or partial list', () async {
    for (final invalid in <Object?>[
      null, {}, ['bad'],
      [{'packageName': 'example.browser'}],
      [{'packageName': 'example.browser', 'label': 'Browser', 'unknown': true}],
      [{'packageName': 'example.browser', 'label': 1}],
      [{'packageName': 'bad package', 'label': 'Browser'}],
      [{'packageName': 'example.browser', 'label': ''}],
      [{'packageName': 'example.browser', 'label': ' Browser '}],
      [{'packageName': 'example.browser', 'label': 'Hidden\ntext'}],
      [{'packageName': 'example.browser', 'label': 'Hidden\u2028text'}],
      [{'packageName': 'example.browser', 'label': 'x' * 1025}],
      [
        {'packageName': 'example.browser', 'label': 'One'},
        {'packageName': 'example.browser', 'label': 'Two'},
      ],
    ]) {
      response = invalid;
      await expectLater(AndroidAppRoutes.installedApps(), throwsFormatException);
    }
    response = List.generate(4097, (i) =>
      {'packageName': 'example.app$i', 'label': 'App $i'});
    await expectLater(AndroidAppRoutes.installedApps(), throwsFormatException);
  });

  test('Parser errors do not attach native payload data', () async {
    response = [{'packageName': 'example.browser', 'label': 'PRIVATE_LABEL\nDATA'}];
    try {
      await AndroidAppRoutes.installedApps();
      fail('Invalid metadata must be rejected.');
    } on FormatException catch (error) {
      expect(error.source, isNull);
      expect(error.toString(), isNot(contains('PRIVATE_LABEL')));
    }
  });

  test('Selections preserve packages missing from app metadata and are immutable', () async {
    response = ['missing.saved_app', 'example.browser'];
    final selected = await AndroidAppRoutes.getBypass();
    expect(selected, {'example.browser', 'missing.saved_app'});
    expect(() => selected.clear(), throwsUnsupportedError);
    expect(calls.single.method, 'getBypass');
  });

  test('Malformed selections are not silently deduplicated, filtered or emptied', () async {
    for (final invalid in <Object?>[
      null, {}, [1], ['example.browser', 'example.browser'],
      ['not-a-package'], ['example.browser\n'],
      ['example.${'a' * 248}'],
      List.generate(4097, (i) => 'example.app$i'),
    ]) {
      response = invalid;
      await expectLater(AndroidAppRoutes.getBypass(), throwsFormatException);
    }
  });

  test('Availability snapshot preserves non-launcher selections and cannot be mutated', () async {
    response = {
      'packages': ['example.hidden', 'example.deleted', 'example.browser'],
      'unavailablePackages': ['example.deleted'],
    };
    final status = await AndroidAppRoutes.getBypassStatus();
    expect(calls.single.method, 'getBypassStatus');
    expect(status.packages.toList(), ['example.browser', 'example.deleted', 'example.hidden']);
    expect(status.unavailablePackages, {'example.deleted'});
    expect(status.unavailablePackages.contains('example.hidden'), isFalse);
    expect(() => status.packages.clear(), throwsUnsupportedError);
    expect(() => status.unavailablePackages.clear(), throwsUnsupportedError);
    (response as Map)['packages'] = [];
    expect(status.packages, hasLength(3));
  });

  test('Availability rejects partial, duplicate, oversized and non-subset payloads', () async {
    final valid = <String, Object?>{
      'packages': ['example.browser'], 'unavailablePackages': <String>[],
    };
    for (final invalid in <Object?>[
      null, [], {}, {'packages': ['example.browser']},
      {...valid, 'privateDetails': 'PRIVATE_PLATFORM_DETAILS'},
      {...valid, 'packages': ['example.browser', 'example.browser']},
      {...valid, 'packages': ['invalid package']},
      {...valid, 'packages': List.generate(4097, (i) => 'example.app$i')},
      {...valid, 'unavailablePackages': null},
      {...valid, 'unavailablePackages': [42]},
      {...valid, 'unavailablePackages': ['example.browser', 'example.browser']},
      {...valid, 'unavailablePackages': ['example.unselected']},
      {...valid, 'unavailablePackages': ['PRIVATE_PLATFORM_DETAILS\n']},
      {...valid, 'unavailablePackages': List.generate(4097, (i) => 'example.app$i')},
    ]) {
      response = invalid;
      await expectLater(AndroidAppRoutes.getBypassStatus(), throwsFormatException);
    }
    try {
      BypassStatus.fromPlatform({'packages': ['PRIVATE_PLATFORM_DETAILS\n'],
        'unavailablePackages': <String>[]});
      fail('Invalid snapshot must be rejected.');
    } on FormatException catch (error) {
      expect(error.source, isNull);
      expect(error.toString(), isNot(contains('PRIVATE_PLATFORM_DETAILS')));
    }
  });

  test('Empty availability is valid and a lookup failure never becomes an empty snapshot', () async {
    response = {'packages': <String>[], 'unavailablePackages': <String>[]};
    final status = await AndroidAppRoutes.getBypassStatus();
    expect(status.packages, isEmpty);
    expect(status.unavailablePackages, isEmpty);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'ROUTES_APPS_CHECK_FAILED');
    });
    await expectLater(AndroidAppRoutes.getBypassStatus(),
      throwsA(isA<PlatformException>().having((error) => error.code,
        'code', 'ROUTES_APPS_CHECK_FAILED')));
  });

  test('Conditional writes include sorted expected and requested packages', () async {
    await AndroidAppRoutes.setBypass({'example.zulu', 'example.alpha'},
      expectedPackages: {'missing.saved_app', 'example.alpha'});
    expect(calls.single.method, 'setBypass');
    expect(calls.single.arguments, {
      'packages': ['example.alpha', 'example.zulu'],
      'expectedPackages': ['example.alpha', 'missing.saved_app'],
    });
    calls.clear();
    await AndroidAppRoutes.setBypass({});
    expect(calls.single.arguments, {'packages': <String>[]});
  });

  test('Invalid writes or expectations never reach the native channel', () async {
    await expectLater(AndroidAppRoutes.setBypass({'bad package'}), throwsFormatException);
    await expectLater(AndroidAppRoutes.setBypass({'example.good'},
      expectedPackages: {'bad package'}), throwsFormatException);
    await expectLater(AndroidAppRoutes.setBypass(
      {for (var i = 0; i < 4097; i++) 'example.app$i'}), throwsFormatException);
    expect(calls, isEmpty);
  });

  test('Empty valid responses remain different from failed responses', () async {
    response = <Object?>[];
    expect(await AndroidAppRoutes.installedApps(), isEmpty);
    expect(await AndroidAppRoutes.getBypass(), isEmpty);
  });
}
