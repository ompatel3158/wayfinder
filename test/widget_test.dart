import 'package:flutter_test/flutter_test.dart';
import 'package:wayfinder/main.dart';

void main() {
  testWidgets('Wayfinder smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const WayfinderApp());
    expect(find.text('Wayfinder'), findsOneWidget);
  });
}
