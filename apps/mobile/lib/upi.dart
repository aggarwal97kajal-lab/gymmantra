import 'dart:math' as math;
import 'package:flutter/services.dart';

// Paying with the UPI apps that are really on this phone (their own name and icon, from Android).

const _ch = MethodChannel('gymmantra/upi');

class UpiApp {
  const UpiApp({required this.package, required this.name, required this.icon});
  final String package;
  final String name;
  final Uint8List? icon;
}

/// UPI apps installed on the phone (Google Pay, PhonePe, Paytm, BHIM, bank apps…).
Future<List<UpiApp>> installedUpiApps() async {
  try {
    final list = await _ch.invokeListMethod<Map>('apps') ?? const [];
    return [
      for (final m in list) UpiApp(package: m['package'] as String, name: m['name'] as String, icon: m['icon'] is Uint8List ? m['icon'] as Uint8List : null),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  } catch (_) {
    return const [];
  }
}

class UpiAnswer {
  UpiAnswer(this.raw);
  final String? raw; // null = the person came back without paying
  Map<String, String> get _kv {
    final r = raw ?? '';
    final out = <String, String>{};
    for (final part in r.split('&')) {
      final i = part.indexOf('=');
      if (i > 0) out[part.substring(0, i).toLowerCase()] = Uri.decodeComponent(part.substring(i + 1));
    }
    return out;
  }

  /// SUCCESS, FAILURE, SUBMITTED, or '' when the app said nothing.
  String get status => (_kv['status'] ?? '').toUpperCase();
  String? get ref => _kv['approvalrefno'] ?? _kv['txnref'] ?? _kv['txnid'];
  bool get cameBack => raw != null;
}

/// Opens the UPI app (or the phone's "Pay with" list when [package] is null) and waits for it.
Future<UpiAnswer> payWithUpi({required String upiId, required String name, required num amount, required String note, required String ref, String? package}) async {
  final q = {'pa': upiId, 'pn': name, 'am': amount.toStringAsFixed(2), 'cu': 'INR', 'tn': note, 'tr': ref};
  final uri = 'upi://pay?${q.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
  final r = await _ch.invokeMethod<String>('pay', {'uri': uri, 'package': package});
  return UpiAnswer(r);
}

/// One key per "Pay" tap: sending it again never makes a second payment.
String newPaymentKey() {
  final r = math.Random.secure();
  return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
}
