import 'package:flutter_test/flutter_test.dart';
import 'package:gymmantra/i18n.dart';
import 'package:gymmantra/strings_hi.dart';
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
  test('hindi text and placeholders', () {
    expect(translate('hi', 'Home'), 'होम');
    expect(translate('hi', '{n} days left', {'n': 5}), '5 दिन बाकी');
    expect(translate('en', '{n} days left', {'n': 5}), '5 days left');
    expect(translate('hi', 'Some text with no translation'), 'Some text with no translation');
    for (final e in hindi.entries) {
      final holes = RegExp(r'\{\w+\}').allMatches(e.key).map((m) => m.group(0)).toSet();
      for (final h in holes) {
        expect(e.value.contains(h!), true, reason: 'Hindi for "${e.key}" is missing $h');
      }
    }
  });
  test('initials', () {
    expect(initialsOf('Rahul Sharma'), 'RS');
    expect(initialsOf('  kajal '), 'K');
  });
}
