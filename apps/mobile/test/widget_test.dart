import 'package:flutter_test/flutter_test.dart';
import 'package:gymmantra/ui.dart';

void main() {
  test('rupees uses Indian grouping', () {
    expect(rupees(399), '₹399');
    expect(rupees(13990), '₹13,990');
    expect(rupees(1234567), '₹12,34,567');
  });
  test('dates', () {
    expect(fmtDate('2026-11-07'), '7 Nov 2026');
    expect(plural(1, 'day'), '1 day');
  });
}
