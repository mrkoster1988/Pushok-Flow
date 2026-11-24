import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/ui/flow_network_latency.dart';

void main() {
  testWidgets('Network response shows — offline and samples only when active', (tester) async {
    var calls = 0;
    final reply = Completer<int?>();
    Future<int?> measure() {
      calls++;
      return reply.future;
    }
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FlowNetworkLatency(active: false, measure: measure),
    )));
    expect(find.byKey(const Key('home_latency_value')), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(calls, 0);

    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FlowNetworkLatency(active: true, measure: measure),
    )));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('Проверяем…'), findsOneWidget);
    reply.complete(48);
    await tester.pump();
    expect(find.text('48 мс'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FlowNetworkLatency(active: false, measure: measure),
    )));
    expect(find.text('—'), findsOneWidget);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Invalid measurement never pretends to be a ping', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FlowNetworkLatency(active: true, measure: () async => -10),
    )));
    await tester.pump();
    await tester.pump();
    expect(find.text('Нет ответа'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
