import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'ui.dart';

/// Android back button on the bottom-tab screens: another tab goes back to the
/// dashboard; on the dashboard the first press shows "Press back again to exit"
/// and only a second press within 2 seconds closes the app.
class ShellBack extends StatefulWidget {
  const ShellBack({super.key, required this.location, required this.home, required this.child});
  final String location;
  final String home;
  final Widget child;
  @override
  State<ShellBack> createState() => _ShellBackState();
}

class _ShellBackState extends State<ShellBack> {
  DateTime? last;
  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (!widget.location.startsWith(widget.home)) {
            context.go(widget.home);
            return;
          }
          final now = DateTime.now();
          if (last != null && now.difference(last!) < const Duration(seconds: 2)) {
            SystemNavigator.pop();
            return;
          }
          last = now;
          toast(context, 'Press back again to exit');
        },
        child: widget.child,
      );
}
