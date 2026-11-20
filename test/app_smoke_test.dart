import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushok_flow/main.dart';

void main() {
  testWidgets('Pushok Flow shows the home screen', (tester) async {
    await tester.pumpWidget(const PushokFlowApp());
    await tester.pump();
    expect(find.textContaining('Pushok Flow'), findsWidgets);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}